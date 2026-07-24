// js/youtube-podcast.js
// Resolve YouTube videos for podcasts whose RSS is audio-only (e.g. WAN Show).

const PIPED_SEARCH_HOSTS = [
    'https://api.piped.private.coffee',
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://pipedapi.ducks.party',
];

const YT_ID_RE = /(?:youtube\.com\/(?:watch\?v=|embed\/|shorts\/|live\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})/i;
const YT_CHANNEL_RE = /(?:youtube\.com|youtu\.be)/i;

let ytApiPromise = null;

export function isYoutubeFeedLink(link) {
    return !!(link && YT_CHANNEL_RE.test(String(link)));
}

export function extractYoutubeId(text) {
    if (!text) return null;
    const match = String(text).match(YT_ID_RE);
    return match ? match[1] : null;
}

function normalizeTitle(title) {
    return String(title || '')
        .toLowerCase()
        .replace(/[^\w\s]/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}

function titleSimilarity(a, b) {
    const left = normalizeTitle(a);
    const right = normalizeTitle(b);
    if (!left || !right) return 0;
    if (left === right) return 1;
    if (left.includes(right) || right.includes(left)) return 0.9;
    const aw = new Set(left.split(' ').filter((w) => w.length > 2));
    const bw = right.split(' ').filter((w) => w.length > 2);
    if (!bw.length) return 0;
    let hit = 0;
    for (const w of bw) if (aw.has(w)) hit += 1;
    return hit / bw.length;
}

async function searchPiped(query) {
    const q = encodeURIComponent(query);
    for (const host of PIPED_SEARCH_HOSTS) {
        try {
            const res = await fetch(`${host}/search?q=${q}&filter=videos`, {
                signal: AbortSignal.timeout(10000),
            });
            if (!res.ok) continue;
            const data = await res.json();
            const items = Array.isArray(data) ? data : data.items || data.results || [];
            if (!items.length) continue;
            return items
                .map((item) => {
                    const url = item.url || item.link || '';
                    const id =
                        item.id ||
                        item.videoId ||
                        extractYoutubeId(url.startsWith('http') ? url : `https://youtube.com${url}`);
                    return {
                        id,
                        title: item.title || item.name || '',
                        url,
                    };
                })
                .filter((item) => item.id);
        } catch {
            // try next host
        }
    }
    return [];
}

/**
 * Resolve a YouTube video id for a podcast episode.
 * Prefers explicit links in description/guid, else Piped title search.
 */
export async function resolvePodcastYoutubeId(track) {
    if (track?.youtubeId) return track.youtubeId;

    const fromFields = [
        track?.link,
        track?.description,
        track?.podcastEpisode?.description,
        track?.podcastEpisode?.link,
        track?.guid,
    ]
        .map(extractYoutubeId)
        .find(Boolean);
    if (fromFields) return fromFields;

    const title = track?.title;
    if (!title) return null;

    const podcastName = track?.artist?.name || track?.album?.title || '';
    const queries = [
        title,
        podcastName ? `${title} ${podcastName}` : null,
        podcastName ? `${podcastName} ${title}` : null,
    ].filter(Boolean);

    for (const query of queries) {
        const results = await searchPiped(query);
        if (!results.length) continue;
        let best = null;
        let bestScore = 0;
        for (const item of results.slice(0, 8)) {
            let score = titleSimilarity(title, item.title);
            if (podcastName && normalizeTitle(item.title).includes(normalizeTitle(podcastName))) {
                score += 0.15;
            }
            if (score > bestScore) {
                bestScore = score;
                best = item;
            }
        }
        if (best && bestScore >= 0.55) return best.id;
    }
    return null;
}

export function loadYoutubeIframeApi() {
    if (window.YT?.Player) return Promise.resolve(window.YT);
    if (ytApiPromise) return ytApiPromise;
    ytApiPromise = new Promise((resolve, reject) => {
        const existing = document.querySelector('script[data-monochrome-yt]');
        const done = () => {
            if (window.YT?.Player) resolve(window.YT);
            else reject(new Error('YouTube IFrame API failed to load'));
        };
        window.onYouTubeIframeAPIReady = done;
        if (existing) {
            if (window.YT?.Player) done();
            return;
        }
        const script = document.createElement('script');
        script.src = 'https://www.youtube.com/iframe_api';
        script.async = true;
        script.dataset.monochromeYt = '1';
        script.onerror = () => reject(new Error('YouTube IFrame API script error'));
        document.head.appendChild(script);
        // API may already be mid-load from elsewhere
        setTimeout(() => {
            if (window.YT?.Player) done();
        }, 1500);
    });
    return ytApiPromise;
}

/**
 * Mount / reuse a YouTube iframe player inside the fullscreen video container.
 * Returns a small control surface used by Player.
 */
export async function mountYoutubePlayer({ videoId, startSeconds = 0, onReady, onStateChange, onError }) {
    const YT = await loadYoutubeIframeApi();
    const container = document.getElementById('fullscreen-video-container');
    if (!container) throw new Error('fullscreen-video-container missing');

    container.style.display = 'flex';
    let host = document.getElementById('youtube-podcast-player');
    if (!host) {
        host = document.createElement('div');
        host.id = 'youtube-podcast-player';
        host.style.width = '100%';
        host.style.height = '100%';
        container.appendChild(host);
    }

    // Hide native <video> while YT owns the surface.
    const nativeVideo = document.getElementById('video-player');
    if (nativeVideo) nativeVideo.style.display = 'none';

    return new Promise((resolve, reject) => {
        let settled = false;
        const player = new YT.Player(host.id, {
            videoId,
            width: '100%',
            height: '100%',
            playerVars: {
                autoplay: 1,
                start: Math.max(0, Math.floor(startSeconds || 0)),
                rel: 0,
                modestbranding: 1,
                playsinline: 1,
                origin: window.location.origin,
            },
            events: {
                onReady: (e) => {
                    settled = true;
                    onReady?.(e);
                    resolve(e.target);
                },
                onStateChange: (e) => onStateChange?.(e),
                onError: (e) => {
                    onError?.(e);
                    if (!settled) {
                        settled = true;
                        reject(new Error(`YouTube error ${e?.data}`));
                    }
                },
            },
        });
    });
}

export function destroyYoutubePlayerMount() {
    const host = document.getElementById('youtube-podcast-player');
    if (host) {
        host.replaceChildren();
        // YT replaces the div with iframe; recreate empty host for next mount
        const parent = host.parentElement;
        if (parent) {
            const next = document.createElement('div');
            next.id = 'youtube-podcast-player';
            next.style.width = '100%';
            next.style.height = '100%';
            host.replaceWith(next);
        }
    }
}
