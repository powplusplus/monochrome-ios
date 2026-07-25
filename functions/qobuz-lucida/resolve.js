// functions/qobuz-lucida/resolve.js  ->  GET /qobuz-lucida/resolve
//
// Maps a lookup (Qobuz track id, ISRC, or "artist title") to a stable, seekable
// stream URL. The actual rip happens lazily inside /qobuz-lucida/play on first
// playback, so this endpoint is fast — it only resolves the Qobuz track id.
//
// Query params:
//   id=<qobuzTrackId>   explicit Qobuz track id (preferred, exact)
//   q=<isrc|text>       search fallback (ISRC, or "artist title")
//   quality=original    "original" (source FLAC, default) or "mp3"
//
// Response: { success, provider:'qobuz', qobuzId, url }  where url is playable.

import { CORS, json, searchQobuzId } from './_lucida.js';

// Lucida rate-limits its search page, and the same ISRC is looked up again on every
// replay, queue advance, and prefetch. Remember the mapping so a throttled search
// cannot turn an already-resolved track into "No Qobuz track found".
const SEARCH_TTL_SECONDS = 86400;

const searchCacheKey = (origin, query) => new Request(`${origin}/qobuz-lucida/_search/${encodeURIComponent(query)}`);

async function cachedSearch(origin, query) {
    if (typeof caches === 'undefined' || !caches.default) return null;
    const hit = await caches.default.match(searchCacheKey(origin, query)).catch(() => null);
    if (!hit) return null;
    const body = await hit.json().catch(() => null);
    return body && body.qobuzId ? String(body.qobuzId) : null;
}

async function rememberSearch(origin, query, qobuzId) {
    if (typeof caches === 'undefined' || !caches.default) return;
    const value = new Response(JSON.stringify({ qobuzId }), {
        headers: {
            'content-type': 'application/json;charset=UTF-8',
            'cache-control': `public, max-age=${SEARCH_TTL_SECONDS}`,
        },
    });
    await caches.default.put(searchCacheKey(origin, query), value).catch(() => {});
}

export async function onRequest(context) {
    const { request, waitUntil } = context;
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });

    const url = new URL(request.url);
    const quality = url.searchParams.get('quality') === 'mp3' ? 'mp3' : 'original';
    let qobuzId = url.searchParams.get('id');
    const q = url.searchParams.get('q');

    try {
        if (!qobuzId || !/^\d+$/.test(qobuzId)) {
            qobuzId = q ? await cachedSearch(url.origin, q) : null;
            if (!qobuzId) {
                qobuzId = await searchQobuzId(q || '');
                if (qobuzId && q) {
                    const remember = rememberSearch(url.origin, q, qobuzId);
                    if (waitUntil) waitUntil(remember);
                    else await remember;
                }
            }
        }
        if (!qobuzId) {
            return json({ success: false, error: 'No Qobuz track found for query' }, 404);
        }
        const play = `/qobuz-lucida/play?id=${encodeURIComponent(qobuzId)}&quality=${quality}`;
        return json({ success: true, provider: 'qobuz', qobuzId, url: play });
    } catch (e) {
        return json({ success: false, error: String(e && e.message ? e.message : e) }, 502);
    }
}
