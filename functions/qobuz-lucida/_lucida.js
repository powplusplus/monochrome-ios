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
export const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36';

export const CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
    'Access-Control-Allow-Headers': 'Range,Content-Type',
    'Access-Control-Expose-Headers': 'Content-Range,Content-Length,Accept-Ranges,Content-Disposition,Content-Type',
};

export function json(obj, status = 200) {
    return new Response(JSON.stringify(obj), {
        status,
        headers: { ...CORS, 'content-type': 'application/json;charset=UTF-8' },
    });
}

// Qobuz licenses per country, so a track that is missing from the US catalog is
// often present in another. Searching only one country turned a regional gap into
// "no Qobuz track found" for the whole request.
export const SEARCH_COUNTRIES = ['US', 'GB', 'DE'];

// Read a short, human-usable reason off a failed upstream response. A bare status
// code could not distinguish "Lucida rate-limited us" from "this track is gone",
// so every failure looked the same in the client.
async function upstreamDetail(res) {
    const text = await res.text().catch(() => '');
    const trimmed = text.trim().replace(/\s+/g, ' ').slice(0, 200);
    return trimmed ? `HTTP ${res.status}: ${trimmed}` : `HTTP ${res.status}`;
}

// Resolve a search string (ISRC, or "artist title") to a Qobuz track id.
// Lucida's search is server-rendered HTML with no JSON API, so we scrape the first
// play.qobuz.com/track/<id> link. Qobuz ranks the exact recording first for an ISRC.
export async function searchQobuzId(query, { countries = SEARCH_COUNTRIES } = {}) {
    if (!query) return null;
    for (const country of countries) {
        let res;
        try {
            res = await fetch(`${LUCIDA}/search?service=qobuz&country=${country}&query=${encodeURIComponent(query)}`, {
                headers: { 'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.9' },
            });
        } catch {
            continue;
        }
        if (!res.ok) {
            await res.body?.cancel?.().catch(() => {});
            continue;
        }
        const html = await res.text();
        const m = html.match(/play\.qobuz\.com\/track\/(\d+)/);
        if (m) return m[1];
    }
    return null;
}

// Kick off a rip job. Returns { handoff, server }. No auth/token is required — the
// "token" the web UI sends is optional anti-abuse.
//
// Retries once on 429/5xx: Lucida hands the job to one of a pool of rip nodes and
// a single busy node used to fail the whole track even though a retry lands
// elsewhere. Client errors (4xx other than 429) are permanent, so they throw
// straight away instead of burning a second request.
export async function startRip(qobuzId, downscale = 'original', { attempts = 2 } = {}) {
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
    let detail = '';
    for (let attempt = 0; attempt < attempts; attempt++) {
        const res = await fetch(`${LUCIDA}/api/load?url=/api/fetch/stream/v2`, {
            method: 'POST',
            headers: {
                'User-Agent': UA,
                'Content-Type': 'application/json',
                Accept: 'application/json',
            },
            body: JSON.stringify(body),
        });
        if (!res.ok) {
            detail = await upstreamDetail(res);
            if (res.status === 429 || res.status >= 500) continue;
            throw new Error(`lucida resolve failed: ${detail}`);
        }
        const j = await res.json().catch(() => null);
        if (j && j.success && j.handoff && j.server) {
            return { handoff: j.handoff, server: j.server };
        }
        detail = j && j.error ? String(j.error) : 'no handoff in response';
    }
    throw new Error(`lucida resolve failed: ${detail || 'unknown error'}`);
}

// The proxied download URL. lucida.to 302-redirects this to the storage node, which
// serves the finished file with Range support. Reusable for the life of the rip.
export function downloadUrl(handoff, server) {
    const inner = encodeURIComponent(`/api/fetch/request/${handoff}/download`);
    return `${LUCIDA}/api/load?url=${inner}&force=${server}&redirect=true`;
}
