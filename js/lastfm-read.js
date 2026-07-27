//js/lastfm-read.js
import { lastFMStorage } from './storage.js';

const API_URL = 'https://ws.audioscrobbler.com/2.0/';
const DEFAULT_API_KEY = '85214f5abbc730e78770f27784b9bdf7';

// Last.fm documents ~5 req/s per IP; stay a little under it.
const MIN_SPACING_MS = 250;
const BUCKET_CAPACITY = 4;
const BUCKET_REFILL_MS = 1000;

const FAILURES_BEFORE_TRIP = 3;
const BACKOFF_LADDER_MS = [60_000, 5 * 60_000, 30 * 60_000];

const DEFAULT_TIMEOUT_MS = 6000;

/**
 * Read-only Last.fm client for recommendation metadata.
 *
 * Deliberately separate from {@link LastFMScrobbler}: these endpoints need only
 * an api_key, so this client never touches the shared API secret and never
 * signs a request. It also uses GET so responses stay HTTP-cacheable.
 */
class LastFMRead {
    constructor() {
        this._tokens = BUCKET_CAPACITY;
        this._lastRefill = Date.now();
        this._lastRequestAt = 0;
        this._queue = Promise.resolve();

        this._consecutiveFailures = 0;
        this._disabledUntil = 0;
        this._backoffStep = 0;
    }

    get apiKey() {
        try {
            if (lastFMStorage.useCustomCredentials()) {
                return lastFMStorage.getCustomApiKey() || DEFAULT_API_KEY;
            }
        } catch {
            // storage unavailable - fall through to the default key
        }
        return DEFAULT_API_KEY;
    }

    /** Whether a read request would actually be attempted right now. */
    isAvailable() {
        if (!this.apiKey) return false;
        if (typeof navigator !== 'undefined' && navigator.onLine === false) return false;
        return Date.now() >= this._disabledUntil;
    }

    async trackGetTopTags(artist, track) {
        const data = await this._request('track.getTopTags', { artist, track, autocorrect: '1' });
        return this._normalizeTags(data?.toptags?.tag);
    }

    async artistGetTopTags(artist) {
        const data = await this._request('artist.getTopTags', { artist, autocorrect: '1' });
        return this._normalizeTags(data?.toptags?.tag);
    }

    async trackGetSimilar(artist, track, limit = 30) {
        const data = await this._request('track.getSimilar', {
            artist,
            track,
            limit: String(limit),
            autocorrect: '1',
        });
        return this._normalizeTracks(data?.similartracks?.track);
    }

    async tagGetTopTracks(tag, limit = 30) {
        const data = await this._request('tag.getTopTracks', { tag, limit: String(limit) });
        return this._normalizeTracks(data?.tracks?.track);
    }

    _normalizeTags(raw) {
        const list = Array.isArray(raw) ? raw : raw ? [raw] : [];
        return list
            .map((t) => ({ name: String(t.name || '').trim(), count: Number(t.count) || 0 }))
            .filter((t) => t.name);
    }

    _normalizeTracks(raw) {
        const list = Array.isArray(raw) ? raw : raw ? [raw] : [];
        return list
            .map((t) => ({
                title: String(t.name || '').trim(),
                artist: String(t.artist?.name || t.artist || '').trim(),
                // track.getSimilar returns `match` (0-1); tag.getTopTracks does not
                match: t.match != null ? Number(t.match) || 0 : null,
            }))
            .filter((t) => t.title && t.artist);
    }

    /**
     * Issues a throttled GET. Returns `null` rather than throwing so callers can
     * treat "no Last.fm data" as an ordinary, expected outcome.
     */
    async _request(method, params) {
        if (!this.isAvailable()) return null;

        const query = new URLSearchParams({
            method,
            api_key: this.apiKey,
            format: 'json',
            ...params,
        });

        try {
            await this._acquireSlot();

            const response = await fetch(`${API_URL}?${query}`, {
                method: 'GET',
                signal: AbortSignal.timeout(DEFAULT_TIMEOUT_MS),
            });

            if (!response.ok) {
                // 429 is a rate limit; other 5xx are transient too
                this._recordFailure(`HTTP ${response.status}`);
                return null;
            }

            const data = await response.json();
            if (data?.error) {
                // 6 = "no such track"; a legitimate empty answer, not a fault
                if (Number(data.error) === 6) {
                    this._recordSuccess();
                    return null;
                }
                this._recordFailure(data.message || `error ${data.error}`);
                return null;
            }

            this._recordSuccess();
            return data;
        } catch (e) {
            this._recordFailure(e?.message || String(e));
            return null;
        }
    }

    /** Serializes callers through a token bucket plus a minimum spacing. */
    _acquireSlot() {
        const wait = (this._queue = this._queue.then(async () => {
            this._refill();

            while (this._tokens < 1) {
                await new Promise((resolve) => setTimeout(resolve, BUCKET_REFILL_MS / BUCKET_CAPACITY));
                this._refill();
            }

            const sinceLast = Date.now() - this._lastRequestAt;
            if (sinceLast < MIN_SPACING_MS) {
                await new Promise((resolve) => setTimeout(resolve, MIN_SPACING_MS - sinceLast));
            }

            this._tokens -= 1;
            this._lastRequestAt = Date.now();
        }));
        return wait;
    }

    _refill() {
        const now = Date.now();
        const elapsed = now - this._lastRefill;
        if (elapsed <= 0) return;
        const refilled = (elapsed / BUCKET_REFILL_MS) * BUCKET_CAPACITY;
        if (refilled >= 1) {
            this._tokens = Math.min(BUCKET_CAPACITY, this._tokens + refilled);
            this._lastRefill = now;
        }
    }

    _recordSuccess() {
        this._consecutiveFailures = 0;
        this._backoffStep = 0;
        this._disabledUntil = 0;
    }

    _recordFailure(reason) {
        this._consecutiveFailures++;
        if (this._consecutiveFailures < FAILURES_BEFORE_TRIP) return;

        const backoff = BACKOFF_LADDER_MS[Math.min(this._backoffStep, BACKOFF_LADDER_MS.length - 1)];
        this._disabledUntil = Date.now() + backoff;
        this._backoffStep++;
        this._consecutiveFailures = 0;
        console.warn(`[Last.fm] paused for ${backoff / 1000}s after repeated failures (${reason})`);
    }

    /** Test hook: clears throttle and breaker state. */
    reset() {
        this._tokens = BUCKET_CAPACITY;
        this._lastRefill = Date.now();
        this._lastRequestAt = 0;
        this._queue = Promise.resolve();
        this._recordSuccess();
    }
}

export const lastFmRead = new LastFMRead();
