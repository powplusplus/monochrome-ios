import { describe, expect, test, beforeEach, afterEach, vi } from 'vitest';

import { searchQobuzId, startRip, downloadUrl } from '../../functions/qobuz-lucida/_lucida.js';
import { onRequest as playRequest } from '../../functions/qobuz-lucida/play.js';
import { onRequest as resolveRequest } from '../../functions/qobuz-lucida/resolve.js';

const ORIGIN = 'https://monochrome.test';

/**
 * Stand-in for `caches.default`. `honorRange: false` reproduces an edge that
 * answers a Range request with the whole object, which the play handler has to
 * slice itself.
 */
class FakeCache {
    constructor({ honorRange = true } = {}) {
        this.store = new Map();
        this.honorRange = honorRange;
        this.putCount = 0;
    }

    async put(request, response) {
        const url = typeof request === 'string' ? request : request.url;
        const bytes = new Uint8Array(await response.arrayBuffer());
        this.store.set(url, { bytes, headers: new Headers(response.headers) });
        this.putCount += 1;
    }

    async match(request) {
        const url = typeof request === 'string' ? request : request.url;
        const entry = this.store.get(url);
        if (!entry) return undefined;
        const headers = new Headers(entry.headers);
        const range = typeof request === 'string' ? null : request.headers.get('Range');
        if (range && this.honorRange) {
            const m = /bytes=(\d*)-(\d*)/.exec(range);
            const start = parseInt(m[1] || '0', 10);
            const end = m[2] ? parseInt(m[2], 10) : entry.bytes.length - 1;
            const slice = entry.bytes.slice(start, end + 1);
            headers.set('content-length', String(slice.length));
            headers.set('content-range', `bytes ${start}-${end}/${entry.bytes.length}`);
            return new Response(slice, { status: 206, headers });
        }
        headers.set('content-length', String(entry.bytes.length));
        return new Response(entry.bytes, { status: 200, headers });
    }
}

const audioBytes = (size = 64) => Uint8Array.from({ length: size }, (_, i) => i % 256);

const audioResponse = (bytes) =>
    new Response(bytes, {
        status: 200,
        headers: { 'content-type': 'audio/flac', 'content-length': String(bytes.length) },
    });

const notReadyResponse = () =>
    new Response('<html>ripping</html>', {
        status: 200,
        headers: { 'content-type': 'text/html' },
    });

const handoffResponse = (server = 'hund') =>
    new Response(JSON.stringify({ success: true, handoff: 'abc123', server }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
    });

const searchHtml = (id) => `<html><a href="https://play.qobuz.com/track/${id}">Song</a></html>`;

const htmlResponse = (body) => new Response(body, { status: 200, headers: { 'content-type': 'text/html' } });

// Poll fast so a backoff that takes ~55s in production takes milliseconds here.
const FAST_POLLING = { LUCIDA_POLL_BASE_MS: 1, LUCIDA_POLL_MAX_MS: 2 };

function playContext(url, init = {}, env = FAST_POLLING) {
    return { request: new Request(url, init), env, waitUntil: (p) => p };
}

let cache;

beforeEach(() => {
    cache = new FakeCache();
    vi.stubGlobal('caches', { default: cache });
});

afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
    vi.restoreAllMocks();
});

describe('_lucida.searchQobuzId', () => {
    test('falls through to another country when the first catalog has no match', async () => {
        const fetchMock = vi
            .fn()
            .mockResolvedValueOnce(htmlResponse('<html>no results</html>'))
            .mockResolvedValueOnce(htmlResponse(searchHtml('987654')));
        vi.stubGlobal('fetch', fetchMock);

        await expect(searchQobuzId('USABC1234567')).resolves.toBe('987654');
        expect(fetchMock).toHaveBeenCalledTimes(2);
        expect(fetchMock.mock.calls[0][0]).toContain('country=US');
        expect(fetchMock.mock.calls[1][0]).toContain('country=GB');
    });

    test('skips a country whose search request fails outright', async () => {
        const fetchMock = vi
            .fn()
            .mockRejectedValueOnce(new TypeError('network'))
            .mockResolvedValueOnce(new Response('rate limited', { status: 429 }))
            .mockResolvedValueOnce(htmlResponse(searchHtml('42')));
        vi.stubGlobal('fetch', fetchMock);

        await expect(searchQobuzId('Artist Song')).resolves.toBe('42');
        expect(fetchMock).toHaveBeenCalledTimes(3);
    });

    test('returns null when no country has the track', async () => {
        const fetchMock = vi.fn(async () => htmlResponse('<html>no results</html>'));
        vi.stubGlobal('fetch', fetchMock);

        await expect(searchQobuzId('Nothing Here')).resolves.toBeNull();
        expect(fetchMock).toHaveBeenCalledTimes(3);
    });
});

describe('_lucida.startRip', () => {
    test('retries once when a rip node answers 5xx', async () => {
        const fetchMock = vi
            .fn()
            .mockResolvedValueOnce(new Response('busy', { status: 503 }))
            .mockResolvedValueOnce(handoffResponse('katze'));
        vi.stubGlobal('fetch', fetchMock);

        await expect(startRip('123')).resolves.toEqual({ handoff: 'abc123', server: 'katze' });
        expect(fetchMock).toHaveBeenCalledTimes(2);
    });

    test('surfaces the upstream body so the failure is diagnosable', async () => {
        vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('track is region locked', { status: 400 })));

        await expect(startRip('123')).rejects.toThrow('HTTP 400: track is region locked');
    });

    test('does not burn a second request on a permanent client error', async () => {
        const fetchMock = vi.fn(async () => new Response('nope', { status: 404 }));
        vi.stubGlobal('fetch', fetchMock);

        await expect(startRip('123')).rejects.toThrow('HTTP 404');
        expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    test('download URL pins the storage node that holds the rip', () => {
        const url = downloadUrl('abc123', 'maus');
        expect(url).toContain('force=maus');
        expect(url).toContain(encodeURIComponent('/api/fetch/request/abc123/download'));
    });
});

describe('qobuz-lucida/play', () => {
    test('rejects a non-numeric track id before touching Lucida', async () => {
        const fetchMock = vi.fn();
        vi.stubGlobal('fetch', fetchMock);

        const res = await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=../etc`));

        expect(res.status).toBe(400);
        expect(fetchMock).not.toHaveBeenCalled();
    });

    test('caches the rip under the request origin so the edge will accept it', async () => {
        const bytes = audioBytes(128);
        vi.stubGlobal(
            'fetch',
            vi.fn().mockResolvedValueOnce(handoffResponse()).mockResolvedValueOnce(audioResponse(bytes))
        );

        const res = await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555&quality=original`));

        expect(res.status).toBe(200);
        expect(cache.putCount).toBe(1);
        expect([...cache.store.keys()]).toEqual([`${ORIGIN}/qobuz-lucida/_cache/555.original.flac`]);
        expect(new Uint8Array(await res.arrayBuffer())).toEqual(bytes);
    });

    test('does not buffer the rip in worker memory before caching it', async () => {
        const bytes = audioBytes(128);
        const upstream = audioResponse(bytes);
        const arrayBuffer = vi.spyOn(upstream, 'arrayBuffer');
        vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(handoffResponse()).mockResolvedValueOnce(upstream));

        await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`));

        expect(arrayBuffer).not.toHaveBeenCalled();
    });

    test('serves a seek out of the cache as a 206 without re-ripping', async () => {
        const bytes = audioBytes(256);
        const fetchMock = vi.fn().mockResolvedValueOnce(handoffResponse()).mockResolvedValueOnce(audioResponse(bytes));
        vi.stubGlobal('fetch', fetchMock);

        await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`));
        const seek = await playRequest(
            playContext(`${ORIGIN}/qobuz-lucida/play?id=555`, { headers: { Range: 'bytes=100-199' } })
        );

        expect(seek.status).toBe(206);
        expect(seek.headers.get('content-range')).toBe('bytes 100-199/256');
        expect(seek.headers.get('access-control-allow-origin')).toBe('*');
        expect(new Uint8Array(await seek.arrayBuffer())).toEqual(bytes.slice(100, 200));
        expect(fetchMock).toHaveBeenCalledTimes(2);
    });

    test('slices the range itself when the cache answers with the whole object', async () => {
        cache = new FakeCache({ honorRange: false });
        vi.stubGlobal('caches', { default: cache });
        const bytes = audioBytes(256);
        vi.stubGlobal(
            'fetch',
            vi.fn().mockResolvedValueOnce(handoffResponse()).mockResolvedValueOnce(audioResponse(bytes))
        );

        await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`));
        const seek = await playRequest(
            playContext(`${ORIGIN}/qobuz-lucida/play?id=555`, { headers: { Range: 'bytes=-10' } })
        );

        expect(seek.status).toBe(206);
        expect(seek.headers.get('content-range')).toBe('bytes 246-255/256');
        expect(new Uint8Array(await seek.arrayBuffer())).toEqual(bytes.slice(246));
    });

    test('answers HEAD without a body but with the real length', async () => {
        const bytes = audioBytes(64);
        vi.stubGlobal(
            'fetch',
            vi.fn().mockResolvedValueOnce(handoffResponse()).mockResolvedValueOnce(audioResponse(bytes))
        );

        await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`));
        const head = await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`, { method: 'HEAD' }));

        expect(head.status).toBe(200);
        expect(head.headers.get('content-length')).toBe('64');
        expect(head.headers.get('accept-ranges')).toBe('bytes');
        expect(await head.text()).toBe('');
    });

    test('keeps polling while the rip is still running', async () => {
        const bytes = audioBytes(32);
        const fetchMock = vi
            .fn()
            .mockResolvedValueOnce(handoffResponse())
            .mockResolvedValueOnce(notReadyResponse())
            .mockResolvedValueOnce(notReadyResponse())
            .mockResolvedValueOnce(audioResponse(bytes));
        vi.stubGlobal('fetch', fetchMock);

        const res = await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`));

        expect(res.status).toBe(200);
        expect(fetchMock).toHaveBeenCalledTimes(4);
    });

    test('stays inside the worker subrequest budget when the rip never finishes', async () => {
        const fetchMock = vi.fn(async (_url, init) =>
            init?.method === 'POST' ? handoffResponse() : notReadyResponse()
        );
        vi.stubGlobal('fetch', fetchMock);

        const res = await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`));

        expect(res.status).toBe(503);
        expect(res.headers.get('retry-after')).toBe('5');
        // 1 rip request + at most MAX_POLLS download polls; each poll also spends a
        // subrequest on the redirect to the storage node.
        expect(fetchMock.mock.calls.length).toBeLessThanOrEqual(13);
        expect(cache.putCount).toBe(0);
    });

    test('reports the Lucida failure instead of a bare status code', async () => {
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response('quota exceeded', { status: 402 }))
        );

        const res = await playRequest(playContext(`${ORIGIN}/qobuz-lucida/play?id=555`));

        expect(res.status).toBe(502);
        expect(await res.text()).toContain('quota exceeded');
    });
});

describe('qobuz-lucida/resolve', () => {
    test('returns a play URL for an explicit Qobuz id without searching', async () => {
        const fetchMock = vi.fn();
        vi.stubGlobal('fetch', fetchMock);

        const res = await resolveRequest(playContext(`${ORIGIN}/qobuz-lucida/resolve?id=555&quality=mp3`));
        const body = await res.json();

        expect(body).toMatchObject({ success: true, qobuzId: '555' });
        expect(body.url).toBe('/qobuz-lucida/play?id=555&quality=mp3');
        expect(fetchMock).not.toHaveBeenCalled();
    });

    test('remembers a resolved ISRC so a throttled search cannot lose the track', async () => {
        const fetchMock = vi.fn(async () => htmlResponse(searchHtml('777')));
        vi.stubGlobal('fetch', fetchMock);

        const first = await resolveRequest(playContext(`${ORIGIN}/qobuz-lucida/resolve?q=USABC1234567`));
        expect((await first.json()).qobuzId).toBe('777');
        expect(fetchMock).toHaveBeenCalledTimes(1);

        fetchMock.mockImplementation(async () => new Response('rate limited', { status: 429 }));
        const second = await resolveRequest(playContext(`${ORIGIN}/qobuz-lucida/resolve?q=USABC1234567`));

        expect((await second.json()).qobuzId).toBe('777');
        expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    test('404s when no country has the track', async () => {
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => htmlResponse('<html>no results</html>'))
        );

        const res = await resolveRequest(playContext(`${ORIGIN}/qobuz-lucida/resolve?q=Unknown+Track`));

        expect(res.status).toBe(404);
        expect((await res.json()).success).toBe(false);
    });
});
