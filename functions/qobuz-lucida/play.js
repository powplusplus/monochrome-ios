// functions/qobuz-lucida/play.js  ->  GET /qobuz-lucida/play?id=<qobuzId>&quality=original
//
// Serves a Qobuz track as a seekable FLAC stream, backed by Lucida.
//
// Why this is more than a dumb proxy: a Lucida rip's download URL is SINGLE-USE —
// the finished file can be fetched exactly once, then the handoff 404s. A browser
// <audio> element issues many range requests per track (progressive load + seeks),
// so we cannot proxy those straight through. Instead, on the first request we rip
// once, pull the whole file, and stash it in the Cloudflare Cache keyed by track id;
// every range request (this one and later seeks) is then served by slicing the
// cached buffer. First play pays the rip+download cost (~10-35s); afterwards it is
// instant and fully seekable.

import { CORS, UA, LUCIDA, startRip, downloadUrl } from './_lucida.js';

const RIP_WAIT_MS = 60000;
const POLL_MS = 1500;

const cacheKeyFor = (id, quality) =>
    new Request(`https://qobuz-lucida.cache/${encodeURIComponent(id)}.${quality}.flac`);

// Pull the finished rip in a single GET (the one allowed download). Returns the full
// bytes, or null if it never became ready in time.
async function ripAndDownload(id, quality) {
    const { handoff, server } = await startRip(id, quality);
    const target = downloadUrl(handoff, server);
    const deadline = Date.now() + RIP_WAIT_MS;
    while (Date.now() < deadline) {
        const up = await fetch(target, {
            headers: { 'User-Agent': UA, Referer: `${LUCIDA}/` },
            redirect: 'follow',
        });
        const ct = up.headers.get('content-type') || '';
        if (up.status === 200 && /audio|flac|octet-stream/i.test(ct)) {
            const bytes = new Uint8Array(await up.arrayBuffer());
            const cd = up.headers.get('content-disposition') || '';
            return { bytes, contentType: ct || 'audio/flac', contentDisposition: cd };
        }
        // Not ready yet (Lucida returns a non-audio status page mid-rip); this GET does
        // not consume the one-shot download. Drain and wait.
        await up.arrayBuffer().catch(() => {});
        await new Promise((r) => setTimeout(r, POLL_MS));
    }
    return null;
}

// Build a range (or full) Response from a complete buffer.
function serveRange(bytes, contentType, rangeHeader, isHead) {
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

export async function onRequest(context) {
    const { request, waitUntil } = context;
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
    const key = cacheKeyFor(id, quality);

    // Fast path: already cached.
    const hit = await cache.match(key);
    if (hit) {
        const bytes = new Uint8Array(await hit.arrayBuffer());
        const ct = hit.headers.get('content-type') || 'audio/flac';
        return serveRange(bytes, ct, rangeHeader, isHead);
    }

    // Slow path: rip once, cache, then serve.
    let ripped;
    try {
        ripped = await ripAndDownload(id, quality);
    } catch (e) {
        return new Response(`lucida error: ${String(e && e.message ? e.message : e)}`, {
            status: 502,
            headers: CORS,
        });
    }
    if (!ripped) {
        return new Response('Lucida rip not ready in time', { status: 504, headers: CORS });
    }

    // Store the full file for subsequent range requests / seeks.
    const cacheResp = new Response(ripped.bytes, {
        headers: {
            'content-type': ripped.contentType,
            'content-length': String(ripped.bytes.length),
            'accept-ranges': 'bytes',
            // Cache within the edge for a day; re-rip on miss/eviction.
            'cache-control': 'public, max-age=86400',
        },
    });
    waitUntil(cache.put(key, cacheResp.clone()));

    return serveRange(ripped.bytes, ripped.contentType, rangeHeader, isHead);
}
