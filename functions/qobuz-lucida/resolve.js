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

export async function onRequest(context) {
    const { request } = context;
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });

    const url = new URL(request.url);
    const quality = url.searchParams.get('quality') === 'mp3' ? 'mp3' : 'original';
    let qobuzId = url.searchParams.get('id');
    const q = url.searchParams.get('q');

    try {
        if (!qobuzId || !/^\d+$/.test(qobuzId)) {
            qobuzId = await searchQobuzId(q || '');
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
