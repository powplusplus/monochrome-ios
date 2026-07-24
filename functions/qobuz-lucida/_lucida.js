// functions/qobuz-lucida/_lucida.js
// Shared helpers for the Lucida-backed Qobuz provider.
//
// Lucida (https://lucida.to) rips a track server-side to a FLAC file, then serves
// it from a rotating storage node (hund/katze/maus/...) that supports HTTP Range.
// There is no live stream: each track is (1) resolved into a "handoff" job, which
// (2) rips for ~5-40s, after which (3) the completed file is downloadable — with
// range support — until it expires. We turn that into progressive playback with a
// resolve/play split so the browser can issue many range requests against one rip.
//
// Files prefixed with "_" are treated as modules by Cloudflare Pages Functions and
// are never routed directly.

export const LUCIDA = 'https://lucida.to';

// A browser-like UA; Lucida's edge is picky about non-browser agents on some paths.
export const UA =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36';

export const CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
    'Access-Control-Allow-Headers': 'Range,Content-Type',
    'Access-Control-Expose-Headers':
        'Content-Range,Content-Length,Accept-Ranges,Content-Disposition,Content-Type',
};

export function json(obj, status = 200) {
    return new Response(JSON.stringify(obj), {
        status,
        headers: { ...CORS, 'content-type': 'application/json;charset=UTF-8' },
    });
}

// Resolve a search string (ISRC, or "artist title") to a Qobuz track id.
// Lucida's search is server-rendered HTML with no JSON API, so we scrape the first
// play.qobuz.com/track/<id> link. Qobuz ranks the exact recording first for an ISRC.
export async function searchQobuzId(query) {
    if (!query) return null;
    const res = await fetch(
        `${LUCIDA}/search?service=qobuz&country=US&query=${encodeURIComponent(query)}`,
        { headers: { 'User-Agent': UA } }
    );
    if (!res.ok) return null;
    const html = await res.text();
    const m = html.match(/play\.qobuz\.com\/track\/(\d+)/);
    return m ? m[1] : null;
}

// Kick off a rip job. Returns { handoff, server }. No auth/token is required — the
// "token" the web UI sends is optional anti-abuse.
export async function startRip(qobuzId, downscale = 'original') {
    const body = {
        url: `https://play.qobuz.com/track/${qobuzId}`,
        metadata: true,
        compat: false,
        private: false,
        handoff: true,
        account: { type: 'country', id: 'auto' },
        upload: { enabled: false, service: 'pixeldrain' },
        downscale, // "original" = source FLAC; "mp3" = transcode
    };
    const res = await fetch(`${LUCIDA}/api/load?url=/api/fetch/stream/v2`, {
        method: 'POST',
        headers: {
            'User-Agent': UA,
            'Content-Type': 'application/json',
            Accept: 'application/json',
        },
        body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`lucida resolve failed: HTTP ${res.status}`);
    const j = await res.json();
    if (!j || !j.success || !j.handoff || !j.server) {
        throw new Error('lucida resolve returned no handoff');
    }
    return { handoff: j.handoff, server: j.server };
}

// The proxied download URL. lucida.to 302-redirects this to the storage node, which
// serves the finished file with Range support. Reusable for the life of the rip.
export function downloadUrl(handoff, server) {
    const inner = encodeURIComponent(`/api/fetch/request/${handoff}/download`);
    return `${LUCIDA}/api/load?url=${inner}&force=${server}&redirect=true`;
}
