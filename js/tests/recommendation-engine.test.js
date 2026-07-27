/* eslint-disable @typescript-eslint/unbound-method -- asserting on vi.fn() spies requires referencing them unbound */
import { expect, test, describe, beforeEach, vi } from 'vitest';

vi.mock('../db.js', () => ({
    db: {
        getTrackFeatures: vi.fn(async () => new Map()),
        putTrackFeatures: vi.fn(async () => {}),
        getTrackFeature: vi.fn(async () => undefined),
        putTrackFeature: vi.fn(async () => {}),
        getResolution: vi.fn(async () => undefined),
        putResolution: vi.fn(async () => {}),
        pruneTrackFeatures: vi.fn(async () => 0),
        pruneResolutions: vi.fn(async () => 0),
        getHistory: vi.fn(async () => []),
    },
}));

vi.mock('../lastfm-read.js', () => ({
    lastFmRead: {
        isAvailable: vi.fn(() => true),
        trackGetTopTags: vi.fn(async () => []),
        artistGetTopTags: vi.fn(async () => []),
        trackGetSimilar: vi.fn(async () => []),
        tagGetTopTracks: vi.fn(async () => []),
    },
}));

vi.mock('../listening-tracker.js', () => ({
    listeningTracker: {
        getArtistAffinity: vi.fn(() => 0),
        getTopArtists: vi.fn(() => []),
        getTrackSignal: vi.fn(() => null),
    },
}));

vi.mock('../smart-recommendations.js', () => ({
    smartRecommendations: {
        getSmartSeeds: vi.fn(async () => []),
        scoreRecommendation: vi.fn(() => 0),
        getKnownBadTrackIds: vi.fn(() => new Set()),
        getKnownBadArtistIds: vi.fn(() => new Set()),
    },
}));

vi.mock('../storage.js', () => ({
    autoplaySettings: {
        isLastFmEnrichmentEnabled: () => true,
        getDiversityLevel: () => 'balanced',
    },
}));

const { db } = await import('../db.js');
const { lastFmRead } = await import('../lastfm-read.js');
const { smartRecommendations } = await import('../smart-recommendations.js');
const { recommendationEngine } = await import('../recommendation-engine.js');

const track = (id, artistId, overrides = {}) => ({
    id: String(id),
    title: `Track ${id}`,
    duration: 200_000,
    popularity: 50,
    artist: { id: String(artistId), name: `Artist ${artistId}` },
    artists: [{ id: String(artistId), name: `Artist ${artistId}` }],
    album: { id: `alb-${id}`, title: `Album ${id}`, releaseDate: '2015-01-01' },
    ...overrides,
});

function makeApi(overrides = {}) {
    return {
        getTrackRecommendations: vi.fn(async () => []),
        getSimilarArtists: vi.fn(async () => []),
        getArtistTopTracks: vi.fn(async () => ({ tracks: [] })),
        searchTracks: vi.fn(async () => ({ items: [] })),
        getTrackMetadata: vi.fn(async (id) => track(id, 'x', { bpm: 120, key: 'A', keyScale: 'MINOR' })),
        ...overrides,
    };
}

describe('recommendationEngine', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        recommendationEngine.reset();
        localStorage.removeItem('monochrome-autoplay-session');

        db.getTrackFeatures.mockResolvedValue(new Map());
        db.getResolution.mockResolvedValue(undefined);
        db.getHistory.mockResolvedValue([]);
        lastFmRead.isAvailable.mockReturnValue(true);
        lastFmRead.trackGetTopTags.mockResolvedValue([]);
        lastFmRead.artistGetTopTags.mockResolvedValue([]);
        lastFmRead.trackGetSimilar.mockResolvedValue([]);
        lastFmRead.tagGetTopTracks.mockResolvedValue([]);
        smartRecommendations.getSmartSeeds.mockResolvedValue([]);
        smartRecommendations.getKnownBadTrackIds.mockReturnValue(new Set());
        smartRecommendations.getKnownBadArtistIds.mockReturnValue(new Set());
    });

    test('returns nothing without an api or seeds', async () => {
        expect(await recommendationEngine.recommend({ api: null, seeds: [track(1, 'a')] })).toEqual([]);
        expect(await recommendationEngine.recommend({ api: makeApi(), seeds: [] })).toEqual([]);
    });

    test('pulls candidates from TIDAL track radio', async () => {
        const api = makeApi({
            getTrackRecommendations: vi.fn(async () => [track(10, 'b'), track(11, 'c')]),
        });

        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(api.getTrackRecommendations).toHaveBeenCalledWith('1');
        expect(picks.map((t) => t.id).sort()).toEqual(['10', '11']);
    });

    test('expands similar artists into their top tracks', async () => {
        const api = makeApi({
            getSimilarArtists: vi.fn(async () => [{ id: 'sim1', name: 'Similar' }]),
            getArtistTopTracks: vi.fn(async () => ({ tracks: [track(20, 'sim1')] })),
        });

        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(api.getArtistTopTracks).toHaveBeenCalledWith('sim1', { limit: 10 });
        expect(picks.map((t) => t.id)).toContain('20');
    });

    test('excludes known, recently played and disliked tracks', async () => {
        smartRecommendations.getKnownBadTrackIds.mockReturnValue(new Set(['12']));
        smartRecommendations.getKnownBadArtistIds.mockReturnValue(new Set(['hated']));

        const api = makeApi({
            getTrackRecommendations: vi.fn(async () => [
                track(10, 'b'),
                track(11, 'c'),
                track(12, 'd'),
                track(13, 'hated'),
                track(14, 'e'),
            ]),
        });

        const picks = await recommendationEngine.recommend({
            api,
            seeds: [track(1, 'a')],
            knownTrackIds: new Set(['10']),
            recentlyPlayedIds: ['11'],
            count: 10,
        });

        expect(picks.map((t) => t.id)).toEqual(['14']);
    });

    test('collapses remaster variants of the same recording', async () => {
        const api = makeApi({
            getTrackRecommendations: vi.fn(async () => [
                { ...track(30, 'b'), title: 'Paranoid Android', popularity: 10 },
                { ...track(31, 'b'), title: 'Paranoid Android - 2009 Remaster', popularity: 90 },
            ]),
        });

        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(picks.length).toBe(1);
        expect(picks[0].id).toBe('31'); // the more popular instance wins
    });

    test('resolves Last.fm similar tracks through search', async () => {
        lastFmRead.trackGetSimilar.mockResolvedValue([{ artist: 'Beach House', title: 'Space Song', match: 1 }]);

        const found = { ...track(40, 'bh'), title: 'Space Song', artist: { id: 'bh', name: 'Beach House' } };
        found.artists = [found.artist];

        const api = makeApi({ searchTracks: vi.fn(async () => ({ items: [found] })) });

        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(api.searchTracks).toHaveBeenCalledTimes(1);
        expect(picks.map((t) => t.id)).toContain('40');
        expect(db.putResolution).toHaveBeenCalledWith(
            expect.objectContaining({ key: 'beachhouse|spacesong', notFound: false })
        );
    });

    test('rejects a search result that is not the same recording', async () => {
        lastFmRead.trackGetSimilar.mockResolvedValue([{ artist: 'Beach House', title: 'Space Song', match: 1 }]);

        const cover = { ...track(41, 'other'), title: 'Space Song', artist: { id: 'other', name: 'Karaoke Band' } };
        cover.artists = [cover.artist];

        const api = makeApi({ searchTracks: vi.fn(async () => ({ items: [cover] })) });

        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(picks.map((t) => t.id)).not.toContain('41');
        expect(db.putResolution).toHaveBeenCalledWith(expect.objectContaining({ notFound: true }));
    });

    test('a cached miss skips the search entirely', async () => {
        lastFmRead.trackGetSimilar.mockResolvedValue([{ artist: 'Nobody', title: 'Nothing', match: 1 }]);
        db.getResolution.mockResolvedValue({ key: 'nobody|nothing', notFound: true, ts: Date.now() });

        const api = makeApi();
        await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(api.searchTracks).not.toHaveBeenCalled();
    });

    test('skips Last.fm entirely when it is unavailable', async () => {
        lastFmRead.isAvailable.mockReturnValue(false);

        const api = makeApi({ getTrackRecommendations: vi.fn(async () => [track(10, 'b')]) });
        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(lastFmRead.trackGetSimilar).not.toHaveBeenCalled();
        expect(lastFmRead.trackGetTopTags).not.toHaveBeenCalled();
        expect(picks.length).toBe(1); // TIDAL sources still deliver
    });

    test('fetches BPM and key only for candidates that lack them', async () => {
        const api = makeApi({
            getTrackRecommendations: vi.fn(async () => [
                track(10, 'b', { bpm: 174, key: 'A', keyScale: 'MINOR' }),
                track(11, 'c'),
            ]),
        });

        await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(api.getTrackMetadata).toHaveBeenCalledTimes(1);
        expect(api.getTrackMetadata).toHaveBeenCalledWith('11');
    });

    test('persists fetched features for reuse', async () => {
        const api = makeApi({ getTrackRecommendations: vi.fn(async () => [track(10, 'b')]) });
        await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 });

        expect(db.putTrackFeatures).toHaveBeenCalled();
        const persisted = db.putTrackFeatures.mock.calls.flatMap((call) => call[0]);
        expect(persisted.some((f) => f.id === '10' && f.camelot === '8A')).toBe(true);
    });

    test('caps one artist at two picks per batch of ten', async () => {
        const api = makeApi({
            getTrackRecommendations: vi.fn(async () =>
                Array.from({ length: 6 }, (_, i) => track(100 + i, 'hog')).concat(
                    Array.from({ length: 6 }, (_, i) => track(200 + i, `var${i}`))
                )
            ),
        });

        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 8 });
        const fromHog = picks.filter((t) => t.artist.id === 'hog');

        expect(picks.length).toBe(8);
        expect(fromHog.length).toBeLessThanOrEqual(2);
    });

    test('respects the artist cap against tracks already queued', async () => {
        const api = makeApi({
            getTrackRecommendations: vi.fn(async () => [track(10, 'hog'), track(11, 'fresh')]),
        });

        const picks = await recommendationEngine.recommend({
            api,
            seeds: [track(1, 'a')],
            queueTail: [track(90, 'hog'), track(91, 'hog')],
            count: 1,
        });

        expect(picks[0].artist.id).toBe('fresh');
    });

    test('drops an artist after two of its autoplay picks are skipped', async () => {
        const api = makeApi({
            getTrackRecommendations: vi.fn(async () => [track(10, 'rejected'), track(11, 'kept')]),
        });

        recommendationEngine.onTrackSkipped({ ...track(50, 'rejected'), _source: 'autoplay' }, 0.05);
        recommendationEngine.onTrackSkipped({ ...track(51, 'rejected'), _source: 'autoplay' }, 0.05);

        const picks = await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 2 });

        expect(picks[0].artist.id).toBe('kept');
    });

    test('ignores a skip that happened past the halfway mark', async () => {
        recommendationEngine.onTrackSkipped({ ...track(50, 'rejected'), _source: 'autoplay' }, 0.9);
        expect(recommendationEngine._sessionSkippedArtists.size).toBe(0);
    });

    test('finishing a track clears its artist from the penalty box', () => {
        recommendationEngine.onTrackSkipped({ ...track(50, 'a1'), _source: 'autoplay' }, 0.1);
        expect(recommendationEngine._sessionSkippedArtists.get('a1')).toBe(1);

        recommendationEngine.onTrackFinished(track(51, 'a1'), 0.95);
        expect(recommendationEngine._sessionSkippedArtists.has('a1')).toBe(false);
    });

    test('prunes the caches once per session, not once per batch', async () => {
        const api = makeApi({ getTrackRecommendations: vi.fn(async () => [track(10, 'b')]) });

        await recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 2 });
        await recommendationEngine.recommend({ api, seeds: [track(2, 'a')], count: 2 });

        expect(db.pruneTrackFeatures).toHaveBeenCalledTimes(1);
        expect(db.pruneResolutions).toHaveBeenCalledTimes(1);
    });

    test('survives every recall source failing', async () => {
        const api = makeApi({
            getTrackRecommendations: vi.fn(async () => {
                throw new Error('offline');
            }),
            getSimilarArtists: vi.fn(async () => {
                throw new Error('offline');
            }),
        });
        lastFmRead.trackGetSimilar.mockRejectedValue(new Error('offline'));

        await expect(recommendationEngine.recommend({ api, seeds: [track(1, 'a')], count: 5 })).resolves.toEqual([]);
    });
});
