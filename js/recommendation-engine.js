//js/recommendation-engine.js
import { db } from './db.js';
import { lastFmRead } from './lastfm-read.js';
import { listeningTracker } from './listening-tracker.js';
import { smartRecommendations } from './smart-recommendations.js';
import { autoplaySettings } from './storage.js';
import {
    DIVERSITY_PRESETS,
    addScaled,
    buildTagVector,
    combineScore,
    cosineSparse,
    durBand,
    durBandIndex,
    durProximity,
    energyFromTags,
    energyProximity,
    eraProximity,
    affinitySigmoid,
    bpmProximity,
    harmonicFit,
    l2Normalize,
    normalizeForResolution,
    popBand,
    popProximity,
    resolveKey,
    selectDiverse,
    tasteScore01,
    toCamelot,
    topEntries,
} from './recommendation-vectors.js';

const FEATURE_SCHEMA_VERSION = 1;

const FEATURE_MEMORY_LIMIT = 500;
const RESOLUTION_MEMORY_LIMIT = 1000;

const GOOD_FEATURE_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const POOR_FEATURE_TTL_MS = 24 * 60 * 60 * 1000;
const RESOLUTION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const NOT_FOUND_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const SESSION_STATE_KEY = 'monochrome-autoplay-session';
const SESSION_STATE_TTL_MS = 6 * 60 * 60 * 1000;

const POSITIVE_HISTORY_LIMIT = 20;
const NEGATIVE_HISTORY_LIMIT = 12;
const RECENCY_DECAY = 0.93;

const BATCH_DEADLINE_MS = 8000;
const MAX_LASTFM_TAG_CALLS = 20;
const MAX_RESOLUTIONS = 15;
const MAX_ENRICHMENTS = 25;
const TARGET_POOL_SIZE = 60;

const SOURCE_PRIORS = {
    tidalRadio: 1.0,
    lastfmSimilar: 0.9,
    similarArtist: 0.7,
    taste: 0.6,
    lastfmTag: 0.5,
};

/**
 * Multi-source autoplay recommender.
 *
 * Recall pulls candidates from TIDAL track radio, similar artists, Last.fm
 * similar tracks and tags, and the listener's own taste pool. Ranking blends
 * content similarity (tags, tempo, musical key, era, popularity) with personal
 * listening signals, then a diversity pass caps per-artist repetition and
 * reserves slots for unfamiliar artists.
 *
 * Every network layer is optional: with Last.fm unreachable or TIDAL BPM
 * missing, the affected scoring terms are dropped and the remaining weights are
 * renormalized rather than collapsing to zero.
 */
class RecommendationEngine {
    constructor() {
        this._featureMemory = new Map();
        this._artistTagMemory = new Map();
        this._resolutionMemory = new Map();

        this._positive = [];
        this._negative = [];
        this._sessionSkippedArtists = new Map();
        this._sessionSkippedTags = new Map();

        this._centroid = null;
        this._prunedThisSession = false;

        this._restoreSession();
    }

    /* -------------------------------------------------------------- */
    /* Public API                                                      */
    /* -------------------------------------------------------------- */

    /**
     * Produces the next batch of tracks to append to the queue.
     *
     * @param {Object} context
     * @param {Object} context.api - the MusicAPI facade (player.api)
     * @param {Array} context.seeds - seed tracks to expand from
     * @param {Array} [context.queueTail] - already-scheduled tracks, in play order
     * @param {Set} [context.knownTrackIds] - ids to avoid re-suggesting
     * @param {Array} [context.recentlyPlayedIds]
     * @param {number} [context.count]
     * @returns {Promise<Array>} prepared track objects, diversity-ranked
     */
    async recommend({ api, seeds = [], queueTail = [], knownTrackIds, recentlyPlayedIds = [], count = 8 }) {
        if (!api || seeds.length === 0) return [];

        this._schedulePrune();

        const deadline = Date.now() + BATCH_DEADLINE_MS;
        const exclude = new Set([...(knownTrackIds || []), ...recentlyPlayedIds].map(String));

        // The centroid drives tag radio during recall, so it has to exist first.
        const centroid = await this._buildCentroid(seeds);

        const candidates = await this._recall({ api, seeds, exclude, centroid, deadline });
        if (candidates.length === 0) return [];

        const seedContext = await this._buildSeedContext({ api, seeds, deadline });

        // Cheap pass first: tags plus free metadata, no per-track network cost.
        await this._attachFeatures(candidates, { allowNetwork: true, deadline });
        let scored = candidates.map((c) => this._score(c, centroid, seedContext));
        scored.sort((a, b) => b.score - a.score);

        // Only the shortlist is worth a /info round-trip for BPM and key.
        const shortlist = scored.slice(0, MAX_ENRICHMENTS);
        await this._enrichAudioFeatures(shortlist, { api, deadline });
        scored = shortlist.map((c) => this._score(c, centroid, seedContext)).sort((a, b) => b.score - a.score);

        const knownArtistIds = await this._knownArtistIds();
        for (const candidate of scored) {
            candidate.isExplore = candidate.artistIds.every((id) => !knownArtistIds.has(id));
        }

        const preset = DIVERSITY_PRESETS[this._diversityLevel()] || DIVERSITY_PRESETS.balanced;
        const exploreRatio = this._isColdStart(centroid) ? 0.35 : preset.exploreRatio;

        const selected = selectDiverse(scored, count, this._featurize(queueTail), {
            lambda: preset.lambda,
            exploreRatio,
        });

        return selected.map((c) => c.track);
    }

    /** Records that the listener rejected a track, so the batch after this one avoids it. */
    onTrackSkipped(track, completionRatio) {
        if (!track?.id) return;
        const ratio = Number.isFinite(completionRatio) ? completionRatio : 0;
        if (ratio > 0.5) return; // they heard most of it - not a rejection

        const feature = this._featureMemory.get(String(track.id));
        if (feature) {
            this._negative.unshift({ ...feature, weight: 1 - ratio });
            this._negative = this._negative.slice(0, NEGATIVE_HISTORY_LIMIT);

            for (const [tag] of topEntries(feature.tags, 3)) {
                this._sessionSkippedTags.set(tag, (this._sessionSkippedTags.get(tag) || 0) + 1);
            }
        }

        // Autoplay's own picks getting skipped is a much stronger signal than a
        // skip on something the listener chose themselves.
        if (track._source) {
            for (const artistId of this._artistIdsOf(track)) {
                this._sessionSkippedArtists.set(artistId, (this._sessionSkippedArtists.get(artistId) || 0) + 1);
            }
        }

        this._centroid = null;
        this._persistSession();
    }

    /** Records a track the listener stayed with, reinforcing its neighbourhood. */
    onTrackFinished(track, completionRatio) {
        if (!track?.id) return;
        const ratio = Number.isFinite(completionRatio) ? completionRatio : 1;
        if (ratio <= 0.8) return;

        const feature = this._featureMemory.get(String(track.id));
        if (feature) {
            this._positive.unshift({ ...feature, weight: 1 });
            this._positive = this._positive.slice(0, POSITIVE_HISTORY_LIMIT);
        }

        for (const artistId of this._artistIdsOf(track)) {
            this._sessionSkippedArtists.delete(artistId);
        }

        this._centroid = null;
        this._persistSession();
    }

    /* -------------------------------------------------------------- */
    /* Recall                                                          */
    /* -------------------------------------------------------------- */

    async _recall({ api, seeds, exclude, centroid, deadline }) {
        const pool = new Map();
        const seedIds = new Set(seeds.map((s) => String(s.id)));
        const dislikedArtists = new Set(smartRecommendations.getKnownBadArtistIds());
        const badTracks = new Set(smartRecommendations.getKnownBadTrackIds());

        const add = (tracks, source) => {
            for (const track of tracks || []) {
                if (!track?.id) continue;
                const id = String(track.id);
                if (seedIds.has(id) || exclude.has(id) || badTracks.has(id)) continue;
                if (this._artistIdsOf(track).some((artistId) => dislikedArtists.has(artistId))) continue;

                const existing = pool.get(id);
                if (existing) {
                    existing.sources.add(source);
                    continue;
                }
                pool.set(id, { id, track, sources: new Set([source]) });
            }
        };

        const results = await Promise.allSettled([
            this._recallTidalRadio(api, seeds.slice(0, 3)),
            this._recallSimilarArtists(api, seeds.slice(0, 2)),
            this._recallLastFmSimilar(api, seeds.slice(0, 2), deadline),
            this._recallTastePool(),
        ]);

        const sourceNames = ['tidalRadio', 'similarArtist', 'lastfmSimilar', 'taste'];
        results.forEach((result, index) => {
            if (result.status === 'fulfilled') add(result.value, sourceNames[index]);
        });

        // Tag radio is expensive, so it only runs when the cheaper sources came up short.
        if (pool.size < TARGET_POOL_SIZE && Date.now() < deadline) {
            try {
                add(await this._recallLastFmTags(api, centroid, deadline), 'lastfmTag');
            } catch {
                // tag radio is a bonus source; its absence is not an error
            }
        }

        return this._dedupeVariants([...pool.values()]);
    }

    async _recallTidalRadio(api, seeds) {
        const batches = await Promise.allSettled(seeds.map((seed) => api.getTrackRecommendations(seed.id)));
        return batches.flatMap((b) => (b.status === 'fulfilled' ? b.value || [] : []));
    }

    async _recallSimilarArtists(api, seeds) {
        const artistIds = new Set();
        for (const seed of seeds) {
            for (const artistId of this._artistIdsOf(seed)) artistIds.add(artistId);
        }
        if (artistIds.size === 0) return [];

        const similarBatches = await Promise.allSettled([...artistIds].slice(0, 2).map((id) => api.getSimilarArtists(id)));

        const similarIds = new Set();
        for (const batch of similarBatches) {
            if (batch.status !== 'fulfilled') continue;
            for (const artist of (batch.value || []).slice(0, 4)) {
                if (artist?.id) similarIds.add(String(artist.id));
            }
        }
        if (similarIds.size === 0) return [];

        const trackBatches = await Promise.allSettled(
            [...similarIds].slice(0, 6).map((id) => api.getArtistTopTracks(id, { limit: 10 }))
        );

        return trackBatches.flatMap((b) => (b.status === 'fulfilled' ? b.value?.tracks || [] : []));
    }

    async _recallLastFmSimilar(api, seeds, deadline) {
        if (!this._lastFmEnabled()) return [];

        const wanted = [];
        for (const seed of seeds) {
            const artist = this._primaryArtistName(seed);
            if (!artist || !seed.title) continue;
            const similar = await lastFmRead.trackGetSimilar(artist, seed.title, 30);
            if (similar) wanted.push(...similar);
        }
        if (wanted.length === 0) return [];

        wanted.sort((a, b) => (b.match ?? 0) - (a.match ?? 0));
        return this._resolveMany(api, wanted, deadline);
    }

    async _recallLastFmTags(api, centroid, deadline) {
        if (!this._lastFmEnabled()) return [];

        const tags = topEntries(centroid?.tags, 2).map(([tag]) => tag);
        if (tags.length === 0) return [];

        const wanted = [];
        for (const tag of tags) {
            const tracks = await lastFmRead.tagGetTopTracks(tag, 30);
            if (tracks) wanted.push(...tracks);
        }
        return this._resolveMany(api, wanted, deadline);
    }

    async _recallTastePool() {
        try {
            return await smartRecommendations.getSmartSeeds(20);
        } catch {
            return [];
        }
    }

    /**
     * Collapses album/single/remaster variants of the same recording, keeping
     * the most popular instance and merging its recall sources.
     */
    _dedupeVariants(entries) {
        const byRecording = new Map();
        for (const entry of entries) {
            const key = resolveKey(this._primaryArtistName(entry.track), entry.track.title);
            const existing = byRecording.get(key);
            if (!existing) {
                byRecording.set(key, entry);
                continue;
            }
            for (const source of entry.sources) existing.sources.add(source);
            if ((entry.track.popularity || 0) > (existing.track.popularity || 0)) {
                existing.track = entry.track;
                existing.id = entry.id;
            }
        }
        return [...byRecording.values()];
    }

    /* -------------------------------------------------------------- */
    /* Last.fm -> TIDAL resolution                                     */
    /* -------------------------------------------------------------- */

    async _resolveMany(api, wanted, deadline) {
        const resolved = [];
        let budget = MAX_RESOLUTIONS;
        const queue = [...wanted];

        const worker = async () => {
            while (queue.length > 0 && budget > 0 && Date.now() < deadline) {
                const item = queue.shift();
                if (!item) return;
                const track = await this._resolveOne(api, item, () => budget--);
                if (track) resolved.push(track);
            }
        };

        await Promise.all([worker(), worker(), worker(), worker()]);
        return resolved;
    }

    async _resolveOne(api, item, spendBudget) {
        const key = resolveKey(item.artist, item.title);

        if (this._resolutionMemory.has(key)) {
            const cached = this._resolutionMemory.get(key);
            return cached?.track || null;
        }

        try {
            const stored = await db.getResolution(key);
            if (stored) {
                const ttl = stored.notFound ? NOT_FOUND_TTL_MS : RESOLUTION_TTL_MS;
                if (Date.now() - (stored.ts || 0) < ttl) {
                    // A cached miss is the valuable half: it skips the search
                    // entirely for the long tail Last.fm knows but TIDAL does not.
                    if (stored.notFound) {
                        this._rememberResolution(key, null);
                        return null;
                    }
                }
            }
        } catch {
            // resolution cache is best-effort
        }

        spendBudget();

        try {
            const result = await api.searchTracks(`${item.artist} ${item.title}`, {
                signal: AbortSignal.timeout(4000),
            });
            const match = this._pickMatch(result?.items || [], item);

            if (!match) {
                this._rememberResolution(key, null);
                void db.putResolution({ key, notFound: true }).catch(() => {});
                return null;
            }

            this._rememberResolution(key, match);
            void db.putResolution({ key, trackId: String(match.id), notFound: false }).catch(() => {});
            return match;
        } catch {
            return null;
        }
    }

    /**
     * Accepts an exact normalized artist+title match only. Looser matching pulls
     * in covers, karaoke versions and tribute recordings.
     */
    _pickMatch(items, item) {
        const wantArtist = normalizeForResolution(item.artist);
        const wantTitle = normalizeForResolution(item.title);

        for (const candidate of items.slice(0, 5)) {
            const candidateTitle = normalizeForResolution(candidate.title);
            if (candidateTitle !== wantTitle) continue;

            const names = [candidate.artist?.name, ...(candidate.artists || []).map((a) => a.name)];
            if (names.some((name) => normalizeForResolution(name) === wantArtist)) return candidate;
        }
        return null;
    }

    _rememberResolution(key, track) {
        if (this._resolutionMemory.size >= RESOLUTION_MEMORY_LIMIT) {
            this._resolutionMemory.delete(this._resolutionMemory.keys().next().value);
        }
        this._resolutionMemory.set(key, track ? { track } : null);
    }

    /* -------------------------------------------------------------- */
    /* Features                                                        */
    /* -------------------------------------------------------------- */

    /** Loads (and where permitted fetches) feature vectors for a set of candidates. */
    async _attachFeatures(candidates, { allowNetwork, deadline }) {
        const tracks = candidates.map((c) => c.track);
        const features = await this.getFeatures(tracks, { allowNetwork, deadline });

        for (const candidate of candidates) {
            const feature = features.get(String(candidate.id)) || this._baseFeature(candidate.track);
            Object.assign(candidate, {
                tags: feature.tags,
                bpm: feature.bpm,
                camelot: feature.camelot,
                energy: feature.energy,
                energyConfidence: feature.energyConfidence,
                eraYear: feature.eraYear,
                popBand: feature.popBand,
                durBand: feature.durBand,
                artistIds: feature.artistIds,
                albumId: feature.albumId,
                feature,
            });
        }
    }

    /**
     * @param {Array} tracks
     * @returns {Promise<Map<string, Object>>} feature vectors keyed by track id
     */
    async getFeatures(tracks, { allowNetwork = true, deadline = Infinity } = {}) {
        const out = new Map();
        const missing = [];

        for (const track of tracks) {
            if (!track?.id) continue;
            const id = String(track.id);
            if (out.has(id)) continue;

            const cached = this._featureMemory.get(id);
            if (cached && !this._isFeatureStale(cached)) {
                out.set(id, this._withTrackMetadata(cached, track));
                continue;
            }
            missing.push({ id, track });
        }

        if (missing.length > 0) {
            let stored = new Map();
            try {
                stored = await db.getTrackFeatures(missing.map((m) => m.id));
            } catch {
                // an unavailable cache just means more network work
            }

            const needNetwork = [];
            for (const entry of missing) {
                const row = stored.get(entry.id);
                if (row && row.v === FEATURE_SCHEMA_VERSION && !this._isFeatureStale(row)) {
                    this._rememberFeature(row);
                    out.set(entry.id, this._withTrackMetadata(row, entry.track));
                } else {
                    needNetwork.push(entry);
                }
            }

            if (allowNetwork && this._lastFmEnabled() && needNetwork.length > 0) {
                const fetched = await this._fetchTagFeatures(needNetwork, deadline);
                for (const [id, feature] of fetched) out.set(id, feature);
            }

            for (const entry of needNetwork) {
                if (!out.has(entry.id)) out.set(entry.id, this._baseFeature(entry.track));
            }
        }

        return out;
    }

    async _fetchTagFeatures(entries, deadline) {
        const out = new Map();
        const persist = [];
        const queue = entries.slice(0, MAX_LASTFM_TAG_CALLS);

        const worker = async () => {
            while (queue.length > 0 && Date.now() < deadline) {
                const entry = queue.shift();
                if (!entry) return;

                const artist = this._primaryArtistName(entry.track);
                let trackTags = null;
                let artistTags = null;

                if (artist && entry.track.title) {
                    trackTags = await lastFmRead.trackGetTopTags(artist, entry.track.title);
                    artistTags = await this._artistTags(artist);
                }

                const feature = this._baseFeature(entry.track);
                if (trackTags || artistTags) {
                    feature.tags = buildTagVector({
                        trackTags: trackTags || [],
                        artistTags: artistTags || [],
                    });
                    Object.assign(feature, energyFromTags(feature.tags));
                    feature.tagSource = Object.keys(feature.tags).length > 0 ? 'lastfm' : 'none';
                } else {
                    feature.tagSource = 'failed';
                }

                this._rememberFeature(feature);
                persist.push(feature);
                out.set(feature.id, feature);
            }
        };

        await Promise.all([worker(), worker(), worker()]);

        if (persist.length > 0) {
            void db.putTrackFeatures(persist).catch(() => {});
        }
        return out;
    }

    async _artistTags(artistName) {
        const key = normalizeForResolution(artistName);
        if (this._artistTagMemory.has(key)) return this._artistTagMemory.get(key);

        const tags = await lastFmRead.artistGetTopTags(artistName);
        this._artistTagMemory.set(key, tags);
        return tags;
    }

    /**
     * Fills in real BPM and musical key from TIDAL for the shortlist only.
     * Candidates that already carry `bpm` (album, playlist and mix payloads
     * embed the full track object) cost nothing.
     */
    async _enrichAudioFeatures(candidates, { api, deadline }) {
        const queue = candidates.filter((c) => c.feature?.audioSource == null && c.bpm == null).slice(0, MAX_ENRICHMENTS);
        if (queue.length === 0) return;

        const persist = [];

        const worker = async () => {
            while (queue.length > 0 && Date.now() < deadline) {
                const candidate = queue.shift();
                if (!candidate) return;

                let full = candidate.track;
                if (full.bpm == null) {
                    try {
                        full = (await api.getTrackMetadata(candidate.id)) || candidate.track;
                    } catch {
                        full = candidate.track;
                    }
                }

                const feature = candidate.feature || this._baseFeature(candidate.track);
                feature.bpm = Number(full.bpm) || null;
                feature.key = full.key || null;
                feature.keyScale = full.keyScale || null;
                feature.camelot = toCamelot(full.key, full.keyScale);
                feature.audioSource = feature.bpm || feature.camelot ? 'tidal' : 'none';
                if (full.popularity != null) feature.popBand = popBand(full.popularity);

                candidate.bpm = feature.bpm;
                candidate.camelot = feature.camelot;
                candidate.popBand = feature.popBand;
                candidate.feature = feature;

                this._rememberFeature(feature);
                persist.push(feature);
            }
        };

        await Promise.all([worker(), worker(), worker(), worker()]);

        if (persist.length > 0) {
            void db.putTrackFeatures(persist).catch(() => {});
        }
    }

    /** Feature vector derivable from a track object alone - no network. */
    _baseFeature(track) {
        const releaseDate = track.album?.releaseDate || track.streamStartDate;
        const year = releaseDate ? new Date(releaseDate).getFullYear() : null;

        return {
            id: String(track.id),
            v: FEATURE_SCHEMA_VERSION,
            tags: {},
            energy: 0.5,
            energyConfidence: 0,
            bpm: Number(track.bpm) || null,
            key: track.key || null,
            keyScale: track.keyScale || null,
            camelot: toCamelot(track.key, track.keyScale),
            artistIds: this._artistIdsOf(track),
            albumId: track.album?.id != null ? String(track.album.id) : null,
            eraYear: Number.isFinite(year) ? year : null,
            popBand: popBand(track.popularity),
            durBand: durBand(track.duration),
            explicit: !!track.explicit,
            audioSource: track.bpm != null || track.key != null ? 'tidal' : null,
            tagSource: null,
            fetchedAt: Date.now(),
        };
    }

    /** Re-applies fields that come from the live track rather than the cache. */
    _withTrackMetadata(feature, track) {
        if (feature.artistIds?.length && feature.durBand) return feature;
        return {
            ...feature,
            artistIds: feature.artistIds?.length ? feature.artistIds : this._artistIdsOf(track),
            albumId: feature.albumId ?? (track.album?.id != null ? String(track.album.id) : null),
            durBand: feature.durBand ?? durBand(track.duration),
        };
    }

    _isFeatureStale(feature) {
        const good = feature.tagSource === 'lastfm' && feature.audioSource === 'tidal';
        const ttl = good ? GOOD_FEATURE_TTL_MS : POOR_FEATURE_TTL_MS;
        return Date.now() - (feature.fetchedAt || 0) > ttl;
    }

    _rememberFeature(feature) {
        if (this._featureMemory.size >= FEATURE_MEMORY_LIMIT) {
            this._featureMemory.delete(this._featureMemory.keys().next().value);
        }
        this._featureMemory.set(String(feature.id), feature);
    }

    /* -------------------------------------------------------------- */
    /* Scoring                                                         */
    /* -------------------------------------------------------------- */

    _score(candidate, centroid, seedContext) {
        const hasTags = Object.keys(candidate.tags || {}).length > 0;
        const centroidHasTags = Object.keys(centroid.tags || {}).length > 0;

        const terms = {
            tagSimilarity: hasTags && centroidHasTags ? cosineSparse(candidate.tags, centroid.tags) : null,
            bpmProximity: bpmProximity(candidate.bpm, centroid.meanBpm),
            harmonicFit: harmonicFit(candidate.camelot, centroid.camelot),
            artistProximity: this._artistProximity(candidate, seedContext),
            taste: tasteScore01(smartRecommendations.scoreRecommendation(candidate.track)),
            eraProximity: eraProximity(candidate.eraYear, centroid.meanYear),
            popProximity: popProximity(candidate.popBand, centroid.meanPopBand),
            sourcePrior: this._sourcePrior(candidate.sources),
            energyProximity: energyProximity(candidate, centroid.meanEnergy),
            durProximity: durProximity(candidate.durBand, centroid.meanDurBandIndex),
        };

        const penalties = {
            dislikeSimilarity: hasTags ? cosineSparse(candidate.tags, centroid.negativeTags) : 0,
            artistPenalty: this._artistPenalty(candidate),
        };

        const { score } = combineScore(terms, penalties);

        // Tags of just-skipped tracks are damped harder than the smoothed
        // negative centroid manages on its own.
        let tagPenalty = 0;
        for (const tag of Object.keys(candidate.tags || {})) {
            if (this._sessionSkippedTags.has(tag)) tagPenalty += 0.08;
        }

        candidate.score = Math.max(-1, score - tagPenalty);
        return candidate;
    }

    _artistProximity(candidate, seedContext) {
        let best = 0;
        for (const artistId of candidate.artistIds) {
            if (seedContext.similarArtistIds.has(artistId)) best = Math.max(best, 0.55);
            if (seedContext.seedArtistIds.has(artistId)) best = Math.max(best, 0.35);
            best = Math.max(best, affinitySigmoid(listeningTracker.getArtistAffinity(artistId)));
        }
        return Math.min(1, best);
    }

    _artistPenalty(candidate) {
        let worst = 0;
        for (const artistId of candidate.artistIds) {
            const skips = this._sessionSkippedArtists.get(artistId) || 0;
            worst = Math.max(worst, Math.min(1, skips / 2));
        }
        return worst;
    }

    _sourcePrior(sources) {
        if (!sources || sources.size === 0) return 0.5;
        let max = 0;
        for (const source of sources) max = Math.max(max, SOURCE_PRIORS[source] ?? 0.5);
        // Agreement between independent sources is genuine signal.
        return Math.min(1, max + 0.15 * (sources.size - 1));
    }

    async _buildSeedContext({ api, seeds, deadline }) {
        const seedArtistIds = new Set();
        for (const seed of seeds) {
            for (const artistId of this._artistIdsOf(seed)) seedArtistIds.add(artistId);
        }

        const similarArtistIds = new Set();
        if (Date.now() < deadline) {
            const batches = await Promise.allSettled(
                [...seedArtistIds].slice(0, 2).map((id) => api.getSimilarArtists(id))
            );
            for (const batch of batches) {
                if (batch.status !== 'fulfilled') continue;
                for (const artist of batch.value || []) {
                    if (artist?.id) similarArtistIds.add(String(artist.id));
                }
            }
        }

        return { seedArtistIds, similarArtistIds };
    }

    /* -------------------------------------------------------------- */
    /* Session centroid                                                */
    /* -------------------------------------------------------------- */

    async _buildCentroid(seeds) {
        if (this._centroid) return this._centroid;

        let entries = this._positive;

        // Cold start: nothing played yet, so the queue itself defines the mood.
        if (entries.length === 0 && seeds.length > 0) {
            const features = await this.getFeatures(seeds, { allowNetwork: false });
            entries = [...features.values()].map((f) => ({ ...f, weight: 1 }));
        }

        const tags = {};
        const negativeTags = {};
        const scalars = { bpm: [0, 0], year: [0, 0], pop: [0, 0], energy: [0, 0], dur: [0, 0] };

        entries.forEach((entry, index) => {
            const weight = (entry.weight ?? 1) * Math.pow(RECENCY_DECAY, index);
            addScaled(tags, entry.tags, weight);

            const accumulate = (bucket, value) => {
                if (value == null || Number.isNaN(value)) return;
                bucket[0] += value * weight;
                bucket[1] += weight;
            };
            accumulate(scalars.bpm, entry.bpm);
            accumulate(scalars.year, entry.eraYear);
            accumulate(scalars.pop, entry.popBand);
            accumulate(scalars.energy, entry.energyConfidence ? entry.energy : null);
            accumulate(scalars.dur, durBandIndex(entry.durBand));
        });

        this._negative.forEach((entry, index) => {
            addScaled(negativeTags, entry.tags, (entry.weight ?? 1) * Math.pow(RECENCY_DECAY, index));
        });

        const mean = ([sum, weight]) => (weight > 0 ? sum / weight : null);

        this._centroid = {
            tags: l2Normalize(tags),
            negativeTags: l2Normalize(negativeTags),
            camelot: entries.find((e) => e.camelot)?.camelot || null,
            meanBpm: mean(scalars.bpm),
            meanYear: mean(scalars.year),
            meanPopBand: mean(scalars.pop),
            meanEnergy: mean(scalars.energy),
            meanDurBandIndex: mean(scalars.dur),
            entryCount: entries.length,
        };
        return this._centroid;
    }

    _isColdStart(centroid) {
        return centroid.entryCount < 3 || listeningTracker.getTopArtists(1).length === 0;
    }

    async _knownArtistIds() {
        const known = new Set(listeningTracker.getTopArtists(500).map((a) => String(a.id)));
        try {
            for (const track of await db.getHistory()) {
                for (const artistId of this._artistIdsOf(track)) known.add(artistId);
            }
        } catch {
            // history is only used to sharpen exploration detection
        }
        return known;
    }

    /* -------------------------------------------------------------- */
    /* Session persistence                                             */
    /* -------------------------------------------------------------- */

    _restoreSession() {
        try {
            const raw = localStorage.getItem(SESSION_STATE_KEY);
            if (!raw) return;
            const state = JSON.parse(raw);
            if (!state?.ts || Date.now() - state.ts > SESSION_STATE_TTL_MS) return;

            this._positive = state.positive || [];
            this._negative = state.negative || [];
            this._sessionSkippedArtists = new Map(state.skippedArtists || []);
            this._sessionSkippedTags = new Map(state.skippedTags || []);
        } catch {
            // a corrupt session just means starting from a clean slate
        }
    }

    _persistSession() {
        try {
            localStorage.setItem(
                SESSION_STATE_KEY,
                JSON.stringify({
                    ts: Date.now(),
                    positive: this._positive.slice(0, POSITIVE_HISTORY_LIMIT),
                    negative: this._negative.slice(0, NEGATIVE_HISTORY_LIMIT),
                    skippedArtists: [...this._sessionSkippedArtists],
                    skippedTags: [...this._sessionSkippedTags],
                })
            );
        } catch {
            // quota or private mode - the session is a nicety, not a requirement
        }
    }

    /* -------------------------------------------------------------- */
    /* Helpers                                                         */
    /* -------------------------------------------------------------- */

    _featurize(tracks) {
        return (tracks || []).map((track) => {
            const feature = this._featureMemory.get(String(track?.id));
            return {
                id: String(track?.id),
                tags: feature?.tags || {},
                bpm: feature?.bpm ?? null,
                artistIds: this._artistIdsOf(track),
                albumId: track?.album?.id != null ? String(track.album.id) : null,
            };
        });
    }

    _artistIdsOf(track) {
        const ids = new Set();
        if (track?.artist?.id != null) ids.add(String(track.artist.id));
        for (const artist of track?.artists || []) {
            if (artist?.id != null) ids.add(String(artist.id));
        }
        return [...ids];
    }

    _primaryArtistName(track) {
        return track?.artist?.name || track?.artists?.[0]?.name || '';
    }

    _lastFmEnabled() {
        try {
            if (!autoplaySettings.isLastFmEnrichmentEnabled?.()) return false;
        } catch {
            // treat a settings failure as "enabled", matching the default
        }
        return lastFmRead.isAvailable();
    }

    _diversityLevel() {
        try {
            return autoplaySettings.getDiversityLevel?.() || 'balanced';
        } catch {
            return 'balanced';
        }
    }

    _schedulePrune() {
        if (this._prunedThisSession) return;
        this._prunedThisSession = true;

        void db
            .pruneTrackFeatures({ isExpired: (row) => this._isFeatureStale(row) })
            .catch(() => {});
        void db
            .pruneResolutions({
                isExpired: (row) => Date.now() - (row.ts || 0) > (row.notFound ? NOT_FOUND_TTL_MS : RESOLUTION_TTL_MS),
            })
            .catch(() => {});
    }

    /** Test hook: drops all cached and session state. */
    reset() {
        this._featureMemory.clear();
        this._artistTagMemory.clear();
        this._resolutionMemory.clear();
        this._positive = [];
        this._negative = [];
        this._sessionSkippedArtists.clear();
        this._sessionSkippedTags.clear();
        this._centroid = null;
        this._prunedThisSession = false;
    }
}

export const recommendationEngine = new RecommendationEngine();
