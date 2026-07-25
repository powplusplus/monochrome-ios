// functions/qobuz-lucida/play.js  ->  GET /qobuz-lucida/play?id=<qobuzId>&quality=original
//
// Serves a Qobuz track as a seekable FLAC stream, backed by Lucida.
//
// Why this is more than a dumb proxy: a Lucida rip's download URL is SINGLE-USE —
// the finished file can be fetched exactly once, then the handoff 404s. A browser
// <audio> element issues many range requests per track (progressive load + seeks),
// so we cannot proxy those straight through. Instead, on the first request we rip
// once, pipe the file into the Cloudflare cache keyed by track id, and serve every
// range request (this one and later seeks) out of the cache. First play pays the
// rip+download cost (~10-35s); afterwards it is instant and fully seekable.

import { CORS, UA, LUCIDA, startRip, downloadUrl } from './_lucida.js';

// Each poll is a subrequest, and following Lucida's 302 to the storage node costs a
// second one. Workers cap subrequests per request (50 on the free tier), so the old
// 40-poll loop could exhaust the budget mid-rip and fail a track that was about to
// be ready. Backing off instead of hammering covers the same ~55s wall clock in 12
// polls.
const MAX_POLLS = 12;
const POLL_BASE_MS = 1500;
const POLL_MAX_MS = 5000;

// Ceiling for the manual range-slice fallback below. Anything larger is served
// whole rather than buffered — a hi-res FLAC does not fit in a Worker's memory.
const MAX_SLICE_BYTES = 96 * 1024 * 1024;

// The cache key must live on a hostname this zone controls; Cloudflare rejects a
// `cache.put` against a made-up host, which meant nothing was ever cached and every
// single play re-ripped the track from scratch. Key off the request's own origin.
const cacheKeyFor = (origin, id, quality) =>
    new Request(`${origin}/qobuz-lucida/_cache/${encodeURIComponent(id)}.${quality}.flac`);

const errorMessage = (e) => String(e && e.message ? e.message : e);

// Poll until the rip finishes, then hand back the still-unread upstream Response so
// the body can be streamed onward. Returns null if it never became ready in time.
async function ripAndDownload(id, quality, pacing = {}) {
    const maxPolls = pacing.maxPolls || MAX_POLLS;
    const baseMs = pacing.baseMs || POLL_BASE_MS;
    const maxMs = pacing.maxMs || POLL_MAX_MS;
    const { handoff, server } = await startRip(id, quality);
    const target = downloadUrl(handoff, server);
    let wait = baseMs;
    for (let attempt = 0; attempt < maxPolls; attempt++) {
        const up = await fetch(target, {
            headers: { 'User-Agent': UA, Referer: `${LUCIDA}/` },
            redirect: 'follow',
        });
        const ct = up.headers.get('content-type') || '';
        if (up.ok && /audio|flac|octet-stream/i.test(ct)) return up;
        // Not ready yet (Lucida returns a non-audio status page mid-rip); this GET does
        // not consume the one-shot download. Drop the body without reading it and wait.
        await up.body?.cancel?.().catch(() => {});
        await new Promise((r) => setTimeout(r, wait));
        wait = Math.min(wait + baseMs, maxMs);
    }
    return null;
}

// Poll pacing is tunable per environment so it can be tightened or relaxed without
// a code change (and so tests do not have to sit through a real backoff).
function pacingFrom(env) {
    const num = (value) => {
        const n = Number(value);
        return Number.isFinite(n) && n > 0 ? n : undefined;
    };
    return {
        maxPolls: num(env?.LUCIDA_MAX_POLLS),
        baseMs: num(env?.LUCIDA_POLL_BASE_MS),
        maxMs: num(env?.LUCIDA_POLL_MAX_MS),
    };
}

// Build a range (or full) Response from a complete buffer.
export function serveRange(bytes, contentType, rangeHeader, isHead) {
    const total = bytes.length;
    let start = 0;
    let end = total - 1;
    let status = 200;

    const m = rangeHeader && /bytes=(\d*)-(\d*)/.exec(rangeHeader);
    if (m) {
        if (m[1] === '' && m[2] !== '') {
            // suffix range: last N bytes
            start = Math.max(0, total - parseInt(m[2], 10));
        } else {
            start = parseInt(m[1] || '0', 10);
            end = m[2] ? Math.min(parseInt(m[2], 10), total - 1) : total - 1;
        }
        if (isNaN(start) || start >= total || start < 0) {
            return new Response('range not satisfiable', {
                status: 416,
                headers: { ...CORS, 'content-range': `bytes */${total}` },
            });
        }
        status = 206;
    }

    const body = isHead ? null : bytes.subarray(start, end + 1);
    const headers = new Headers(CORS);
    headers.set('content-type', contentType || 'audio/flac');
    headers.set('accept-ranges', 'bytes');
    headers.set('content-length', String(end - start + 1));
    if (status === 206) headers.set('content-range', `bytes ${start}-${end}/${total}`);
    return new Response(body, { status, headers });
}

// Ask the cache for the byte range the client wants. The Cache API answers a Range
// request with a 206 itself, so the common seek never touches Worker memory.
function matchCached(cache, key, rangeHeader) {
    const probe = rangeHeader ? new Request(key.url, { headers: { Range: rangeHeader } }) : key;
    return cache.match(probe);
}

// Turn a cache hit into the client-facing response: re-stamp CORS (cached copies
// carry the headers we stored, not this request's), and cover the case where the
// cache ignored the Range and handed back the whole file.
async function fromCache(hit, rangeHeader, isHead) {
    const headers = new Headers(hit.headers);
    for (const [k, v] of Object.entries(CORS)) headers.set(k, v);
    headers.set('accept-ranges', 'bytes');

    const length = Number(headers.get('content-length') || 0);
    if (hit.status === 206 || !rangeHeader || length > MAX_SLICE_BYTES) {
        if (isHead) {
            await hit.body?.cancel?.().catch(() => {});
            return new Response(null, { status: hit.status, headers });
        }
        return new Response(hit.body, { status: hit.status, headers });
    }

    const bytes = new Uint8Array(await hit.arrayBuffer());
    return serveRange(bytes, headers.get('content-type'), rangeHeader, isHead);
}

export async function onRequest(context) {
    const { request, env } = context;
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });

    const url = new URL(request.url);
    const id = url.searchParams.get('id');
    const quality = url.searchParams.get('quality') === 'mp3' ? 'mp3' : 'original';
    if (!id || !/^\d+$/.test(id)) {
        return new Response('missing qobuz id', { status: 400, headers: CORS });
    }

    const isHead = request.method === 'HEAD';
    const rangeHeader = request.headers.get('Range');
    const cache = caches.default;
    const key = cacheKeyFor(url.origin, id, quality);

    // Fast path: already cached.
    const hit = await matchCached(cache, key, rangeHeader);
    if (hit) return fromCache(hit, rangeHeader, isHead);

    // Slow path: rip once, stream into the cache, then serve out of it.
    let ripped;
    try {
        ripped = await ripAndDownload(id, quality, pacingFrom(env));
    } catch (e) {
        return new Response(`lucida error: ${errorMessage(e)}`, { status: 502, headers: CORS });
    }
    if (!ripped) {
        // 503 + Retry-After, not 504: the rip is still running, and a client that
        // comes back in a few seconds usually finds it finished.
        return new Response('Lucida rip not ready yet', {
            status: 503,
            headers: { ...CORS, 'retry-after': '5' },
        });
    }

    // Pipe the download straight into the cache. Reading it into a Uint8Array first
    // held the entire file in Worker memory, which a hi-res FLAC blows past (128 MB
    // limit) — the track then died with an opaque edge error every time.
    const storeHeaders = new Headers({
        'content-type': ripped.headers.get('content-type') || 'audio/flac',
        'accept-ranges': 'bytes',
        // Cache within the edge for a day; re-rip on miss/eviction.
        'cache-control': 'public, max-age=86400',
    });
    const upstreamLength = ripped.headers.get('content-length');
    if (upstreamLength) storeHeaders.set('content-length', upstreamLength);

    try {
        await cache.put(key, new Response(ripped.body, { headers: storeHeaders }));
    } catch (e) {
        return new Response(`lucida cache error: ${errorMessage(e)}`, { status: 502, headers: CORS });
    }

    const stored = await matchCached(cache, key, rangeHeader);
    if (!stored) {
        return new Response('Lucida rip stored but not readable yet', {
            status: 503,
            headers: { ...CORS, 'retry-after': '2' },
        });
    }
    return fromCache(stored, rangeHeader, isHead);
}
