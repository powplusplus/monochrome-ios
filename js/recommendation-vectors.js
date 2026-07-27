//js/recommendation-vectors.js
/**
 * Pure math and normalization for the autoplay recommendation engine.
 *
 * Everything here is a plain function over plain data - no imports, no I/O, no
 * globals - so the scoring behaviour can be unit-tested without mocking the
 * player, the database, or the network.
 */

// Tags that describe the listener's relationship to a track rather than the music.
const STOPWORD_TAGS = new Set([
    'seenlive',
    'favorites',
    'favourites',
    'favoritesongs',
    'favouritesongs',
    'awesome',
    'mymusic',
    'beautiful',
    'love',
    'lovedtracks',
    'loveatfirstlisten',
    'checkout',
    'albumsiown',
    'under2000listeners',
    'spotify',
    'goodstuff',
    'amazing',
    'best',
    'bestsongsever',
    'epic',
    'masterpiece',
    'coolstuff',
    'music',
    'song',
    'songs',
    'albumihave',
    'iown',
]);

// Rough energy proxy used only when TIDAL has no BPM for a track.
const ENERGY_TAGS = {
    ambient: 0.05,
    drone: 0.05,
    fieldrecording: 0.05,
    newage: 0.1,
    sleep: 0.1,
    meditation: 0.1,
    classical: 0.2,
    chamber: 0.2,
    lullaby: 0.1,
    chillout: 0.15,
    chill: 0.2,
    downtempo: 0.25,
    lofi: 0.2,
    slowcore: 0.15,
    sadcore: 0.15,
    acoustic: 0.25,
    folk: 0.3,
    singersongwriter: 0.3,
    ballad: 0.2,
    jazz: 0.3,
    bossanova: 0.25,
    soul: 0.4,
    rnb: 0.4,
    dreampop: 0.3,
    shoegaze: 0.45,
    trip: 0.3,
    triphop: 0.3,
    bluegrass: 0.45,
    blues: 0.4,
    country: 0.4,
    reggae: 0.4,
    dub: 0.35,
    pop: 0.55,
    synthpop: 0.55,
    indie: 0.5,
    indiepop: 0.5,
    indierock: 0.55,
    alternative: 0.55,
    rock: 0.6,
    classicrock: 0.6,
    britpop: 0.55,
    funk: 0.6,
    disco: 0.65,
    house: 0.7,
    deephouse: 0.6,
    techhouse: 0.72,
    hiphop: 0.6,
    rap: 0.62,
    trap: 0.65,
    grime: 0.75,
    drill: 0.65,
    electronic: 0.6,
    edm: 0.8,
    trance: 0.8,
    techno: 0.8,
    dubstep: 0.82,
    breakbeat: 0.78,
    jungle: 0.88,
    drumandbass: 0.9,
    hardstyle: 0.95,
    gabber: 0.98,
    punk: 0.85,
    postpunk: 0.65,
    hardcore: 0.95,
    metal: 0.85,
    heavymetal: 0.85,
    deathmetal: 0.95,
    blackmetal: 0.92,
    metalcore: 0.9,
    thrashmetal: 0.95,
    grindcore: 0.98,
    screamo: 0.9,
};

// Camelot wheel: pitch class -> wheel number, for MINOR (A) and MAJOR (B).
const MINOR_WHEEL = { A: 8, 'A#': 3, B: 10, C: 5, 'C#': 12, D: 7, 'D#': 2, E: 9, F: 4, 'F#': 11, G: 6, 'G#': 1 };
const MAJOR_WHEEL = { A: 11, 'A#': 6, B: 1, C: 8, 'C#': 3, D: 10, 'D#': 5, E: 12, F: 7, 'F#': 2, G: 9, 'G#': 4 };
const FLAT_TO_SHARP = { Ab: 'G#', Bb: 'A#', Cb: 'B', Db: 'C#', Eb: 'D#', Fb: 'E', Gb: 'F#' };

const ERA_BUCKETS = [
    [1970, 'pre70s'],
    [1980, '70s'],
    [1990, '80s'],
    [2000, '90s'],
    [2010, '00s'],
    [2020, '10s'],
];

const DURATION_BANDS = ['short', 'med', 'long', 'epic'];

// Score weights. Positive terms sum to 1; penalties are subtractive.
export const SCORE_WEIGHTS = {
    tagSimilarity: 0.26,
    bpmProximity: 0.14,
    harmonicFit: 0.08,
    artistProximity: 0.15,
    taste: 0.13,
    eraProximity: 0.07,
    popProximity: 0.06,
    sourcePrior: 0.06,
    energyProximity: 0.03,
    durProximity: 0.02,
};

export const NEGATIVE_WEIGHTS = {
    dislikeSimilarity: 0.25,
    artistPenalty: 0.1,
};

export const DIVERSITY_PRESETS = {
    low: { lambda: 0.85, exploreRatio: 0.1 },
    balanced: { lambda: 0.72, exploreRatio: 0.2 },
    high: { lambda: 0.58, exploreRatio: 0.32 },
};

/* ------------------------------------------------------------------ */
/* Sparse vector math                                                  */
/* ------------------------------------------------------------------ */

export function l2Normalize(vector) {
    const out = {};
    let sumSquares = 0;
    for (const value of Object.values(vector || {})) {
        sumSquares += value * value;
    }
    if (sumSquares <= 0) return out;

    const magnitude = Math.sqrt(sumSquares);
    for (const [key, value] of Object.entries(vector)) {
        if (value !== 0) out[key] = value / magnitude;
    }
    return out;
}

/**
 * Cosine similarity of two sparse maps. Returns 0 - never NaN - when either
 * side is empty, which is the common case for tracks Last.fm has no tags for.
 */
export function cosineSparse(a, b) {
    if (!a || !b) return 0;
    const aKeys = Object.keys(a);
    const bKeys = Object.keys(b);
    if (aKeys.length === 0 || bKeys.length === 0) return 0;

    const [small, large] = aKeys.length <= bKeys.length ? [a, b] : [b, a];

    let dot = 0;
    for (const [key, value] of Object.entries(small)) {
        const other = large[key];
        if (other) dot += value * other;
    }
    if (dot === 0) return 0;

    let magA = 0;
    for (const value of Object.values(a)) magA += value * value;
    let magB = 0;
    for (const value of Object.values(b)) magB += value * value;
    if (magA <= 0 || magB <= 0) return 0;

    return dot / (Math.sqrt(magA) * Math.sqrt(magB));
}

export function addScaled(target, vector, scale) {
    for (const [key, value] of Object.entries(vector || {})) {
        target[key] = (target[key] || 0) + value * scale;
    }
    return target;
}

export function topEntries(vector, limit) {
    return Object.entries(vector || {})
        .sort((a, b) => b[1] - a[1])
        .slice(0, limit);
}

/* ------------------------------------------------------------------ */
/* Tag vectors                                                         */
/* ------------------------------------------------------------------ */

export function normalizeTagName(name) {
    return String(name || '')
        .toLowerCase()
        .replace(/&/g, ' and ')
        .replace(/['’\-_.]/g, '')
        .replace(/\s+/g, '')
        .trim();
}

/**
 * Builds an L2-normalized tag vector from Last.fm track and artist tags.
 * Track tags dominate; artist tags fill in so an album cut with no tags of its
 * own still lands in its artist's neighbourhood.
 */
export function buildTagVector({ trackTags = [], artistTags = [] } = {}) {
    const usable = (tags) =>
        (tags || [])
            .map((t) => ({ name: normalizeTagName(t.name), count: Number(t.count) || 0 }))
            .filter((t) => t.name && !STOPWORD_TAGS.has(t.name) && t.count >= 10);

    const track = usable(trackTags).sort((a, b) => b.count - a.count);
    const artist = usable(artistTags).sort((a, b) => b.count - a.count);

    const vector = {};
    for (const tag of track.slice(0, 10)) {
        vector[tag.name] = Math.max(vector[tag.name] || 0, tag.count / 100);
    }

    // Thin track tagging means we lean harder on the artist's profile.
    const artistWeight = track.length < 3 ? 0.55 : 0.35;
    for (const tag of artist.slice(0, 6)) {
        if (vector[tag.name]) continue;
        vector[tag.name] = (tag.count / 100) * artistWeight;
    }

    const trimmed = {};
    for (const [name, weight] of topEntries(vector, 12)) {
        trimmed[name] = weight;
    }
    return l2Normalize(trimmed);
}

/**
 * Energy proxy in [0,1] derived from tag vocabulary.
 * `energyConfidence` is 0 when no tag matched, so callers can drop the term.
 */
export function energyFromTags(tagVector) {
    let weighted = 0;
    let total = 0;
    for (const [name, weight] of Object.entries(tagVector || {})) {
        const energy = ENERGY_TAGS[name];
        if (energy == null) continue;
        weighted += energy * weight;
        total += weight;
    }
    if (total <= 0) return { energy: 0.5, energyConfidence: 0 };
    return { energy: weighted / total, energyConfidence: Math.min(1, total) };
}

/* ------------------------------------------------------------------ */
/* Musical key (Camelot wheel)                                         */
/* ------------------------------------------------------------------ */

export function toCamelot(key, keyScale) {
    if (!key) return null;

    let pitch = String(key).trim();
    pitch = pitch.charAt(0).toUpperCase() + pitch.slice(1);
    if (FLAT_TO_SHARP[pitch]) pitch = FLAT_TO_SHARP[pitch];
    pitch = pitch.replace('♯', '#').replace('♭', 'b');
    if (FLAT_TO_SHARP[pitch]) pitch = FLAT_TO_SHARP[pitch];

    const minor = String(keyScale || '').toUpperCase() === 'MINOR';
    const number = minor ? MINOR_WHEEL[pitch] : MAJOR_WHEEL[pitch];
    if (!number) return null;

    return `${number}${minor ? 'A' : 'B'}`;
}

function parseCamelot(code) {
    const match = /^(\d{1,2})([AB])$/.exec(String(code || ''));
    if (!match) return null;
    return { number: Number(match[1]), letter: match[2] };
}

/**
 * Harmonic compatibility in [0,1] using standard DJ mixing rules: identical
 * key, one step around the wheel, or the relative major/minor all blend well.
 * Returns null when either key is unknown so the term can be dropped.
 */
export function harmonicFit(candidateCamelot, referenceCamelot) {
    const a = parseCamelot(candidateCamelot);
    const b = parseCamelot(referenceCamelot);
    if (!a || !b) return null;

    if (a.number === b.number && a.letter === b.letter) return 1;
    if (a.number === b.number) return 0.8; // relative major/minor

    const distance = Math.abs(a.number - b.number);
    const wheelDistance = Math.min(distance, 12 - distance);
    if (wheelDistance === 1 && a.letter === b.letter) return 0.8;

    return 0.3;
}

/* ------------------------------------------------------------------ */
/* Scalar proximities                                                  */
/* ------------------------------------------------------------------ */

/**
 * Tempo similarity with half/double-time credit - 87 BPM and 174 BPM are the
 * same groove, so they should not be treated as opposites.
 */
export function bpmProximity(candidateBpm, referenceBpm) {
    if (!candidateBpm || !referenceBpm) return null;

    const targets = [referenceBpm, referenceBpm / 2, referenceBpm * 2];
    let best = 0;
    for (const target of targets) {
        const proximity = 1 - Math.min(1, Math.abs(candidateBpm - target) / 30);
        if (proximity > best) best = proximity;
    }
    return best;
}

export function eraBucket(year) {
    if (!year) return null;
    for (const [threshold, label] of ERA_BUCKETS) {
        if (year < threshold) return label;
    }
    return '20s';
}

export function popBand(popularity) {
    const value = Number(popularity);
    if (!Number.isFinite(value)) return null;
    if (value < 20) return 0;
    if (value < 40) return 1;
    if (value < 60) return 2;
    if (value < 80) return 3;
    return 4;
}

/** @param durationMs milliseconds, matching the player's track duration units. */
export function durBand(durationMs) {
    const value = Number(durationMs);
    if (!Number.isFinite(value) || value <= 0) return null;
    if (value < 120_000) return 'short';
    if (value < 300_000) return 'med';
    if (value < 420_000) return 'long';
    return 'epic';
}

export function durBandIndex(band) {
    const index = DURATION_BANDS.indexOf(band);
    return index === -1 ? null : index;
}

function linearProximity(candidate, reference, span) {
    if (candidate == null || reference == null) return null;
    return 1 - Math.min(1, Math.abs(candidate - reference) / span);
}

export function eraProximity(candidateYear, meanYear) {
    // Unknown release dates are common; treat them as neutral rather than bad.
    if (!candidateYear || !meanYear) return 0.5;
    return linearProximity(candidateYear, meanYear, 20);
}

export function popProximity(candidateBand, meanBand) {
    if (candidateBand == null || meanBand == null) return 0.5;
    return linearProximity(candidateBand, meanBand, 4);
}

export function durProximity(candidateBand, meanBandIndex) {
    const index = durBandIndex(candidateBand);
    if (index == null || meanBandIndex == null) return 0.5;
    return linearProximity(index, meanBandIndex, 3);
}

export function energyProximity(candidate, meanEnergy) {
    if (candidate == null || meanEnergy == null) return 0.5;
    if (!candidate.energyConfidence) return 0.5;
    return 1 - Math.min(1, Math.abs(candidate.energy - meanEnergy));
}

export function affinitySigmoid(affinity) {
    const value = Number(affinity) || 0;
    return 1 / (1 + Math.exp(-value / 2));
}

/** Maps smartRecommendations.scoreRecommendation (roughly [-8, 6]) into [0,1]. */
export function tasteScore01(rawScore) {
    const value = Number(rawScore);
    if (!Number.isFinite(value)) return 0.5;
    return clamp((value + 5) / 11, 0, 1);
}

export function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
}

/* ------------------------------------------------------------------ */
/* Scoring                                                             */
/* ------------------------------------------------------------------ */

/**
 * Weighted sum of the available signals.
 *
 * Terms whose value is null (no BPM, no key, no tags on either side) are
 * dropped and the remaining weights are renormalized to sum to 1. Without this
 * a Last.fm outage or a BPM-less catalogue would flatten every score to zero
 * instead of degrading to metadata-only ranking.
 *
 * @param {Object} terms - term name -> value in [0,1], or null when unavailable
 * @param {Object} [penalties] - term name -> value in [0,1]
 * @returns {{score: number, usedWeights: Object}}
 */
export function combineScore(terms, penalties = {}) {
    const available = [];
    let weightSum = 0;

    for (const [name, weight] of Object.entries(SCORE_WEIGHTS)) {
        const value = terms[name];
        if (value == null || Number.isNaN(value)) continue;
        available.push([name, weight, value]);
        weightSum += weight;
    }

    const usedWeights = {};
    let score = 0;

    if (weightSum > 0) {
        for (const [name, weight, value] of available) {
            const normalized = weight / weightSum;
            usedWeights[name] = normalized;
            score += normalized * value;
        }
    }

    for (const [name, weight] of Object.entries(NEGATIVE_WEIGHTS)) {
        const value = penalties[name];
        if (value == null || Number.isNaN(value)) continue;
        score -= weight * value;
    }

    return { score: clamp(score, -1, 1.5), usedWeights };
}

/* ------------------------------------------------------------------ */
/* Diversity                                                           */
/* ------------------------------------------------------------------ */

function artistIdsOf(track) {
    return Array.isArray(track?.artistIds) ? track.artistIds.map(String) : [];
}

function artistOverlap(a, b) {
    const idsB = new Set(artistIdsOf(b));
    return artistIdsOf(a).some((id) => idsB.has(id)) ? 1 : 0;
}

/**
 * Similarity used to suppress near-duplicates during re-ranking.
 * Degrades gracefully to artist overlap alone when tag vectors are missing.
 */
export function candidateSimilarity(a, b) {
    const tagPart = cosineSparse(a?.tags, b?.tags);
    const bpmPart = bpmProximity(a?.bpm, b?.bpm) ?? 0;
    return 0.55 * tagPart + 0.3 * artistOverlap(a, b) + 0.15 * bpmPart;
}

function countInWindow(track, window, key) {
    const ids = key === 'artist' ? artistIdsOf(track) : [track?.albumId].filter(Boolean).map(String);
    if (ids.length === 0) return 0;

    let count = 0;
    for (const other of window) {
        const otherIds = key === 'artist' ? artistIdsOf(other) : [other?.albumId].filter(Boolean).map(String);
        if (otherIds.some((id) => ids.includes(id))) count++;
    }
    return count;
}

/**
 * Greedy MMR selection with per-artist and per-album caps plus an exploration
 * quota, so a batch can never collapse into one artist on repeat.
 *
 * Caps are measured against a sliding window that includes the tracks already
 * queued - otherwise three consecutive batches could each legally add two
 * tracks by the same artist.
 *
 * @param {Array} candidates - each `{ id, score, tags, bpm, artistIds, albumId, isExplore }`
 * @param {number} count
 * @param {Array} queueTail - already-scheduled tracks, in play order
 * @param {Object} [options] - `{ lambda, exploreRatio, maxPerArtist, maxPerAlbum }`
 */
export function selectDiverse(candidates, count, queueTail = [], options = {}) {
    const { lambda = 0.72, exploreRatio = 0.2, maxPerArtist = 2, maxPerAlbum = 2 } = options;

    const remainingPool = [...candidates];
    const selected = [];
    const exploreQuota = Math.ceil(exploreRatio * count);
    let exploreFilled = 0;

    while (selected.length < count && remainingPool.length > 0) {
        const remaining = count - selected.length;
        const forceExplore = exploreQuota - exploreFilled >= remaining;
        const window = [...queueTail, ...selected].slice(-10);

        // Relax constraints in tiers so a homogeneous pool can never deadlock.
        let pool = remainingPool.filter(
            (t) =>
                countInWindow(t, window, 'artist') < maxPerArtist &&
                countInWindow(t, window, 'album') < maxPerAlbum &&
                (!forceExplore || t.isExplore)
        );
        if (pool.length === 0) {
            pool = remainingPool.filter((t) => countInWindow(t, window, 'artist') < maxPerArtist);
        }
        if (pool.length === 0) pool = remainingPool;

        const compareAgainst = [...queueTail.slice(-5), ...selected];

        let best = null;
        let bestValue = -Infinity;
        for (const candidate of pool) {
            let maxSim = 0;
            for (const other of compareAgainst) {
                const similarity = candidateSimilarity(candidate, other);
                if (similarity > maxSim) maxSim = similarity;
            }
            const value = lambda * candidate.score - (1 - lambda) * maxSim;
            if (value > bestValue) {
                bestValue = value;
                best = candidate;
            }
        }

        if (!best) break;
        selected.push(best);
        if (best.isExplore) exploreFilled++;
        remainingPool.splice(remainingPool.indexOf(best), 1);
    }

    return selected;
}

/* ------------------------------------------------------------------ */
/* Track/artist string normalization                                   */
/* ------------------------------------------------------------------ */

const FEATURE_PATTERN = /\s*[([]\s*(feat|ft|featuring|with)\.?[^)\]]*[)\]]/gi;
const EDITION_PATTERN =
    /\s*-\s*(\d{4}\s+)?(remaster(ed)?|remix|radio edit|single version|album version|mono|stereo|live|deluxe|anniversary|edit)\b.*$/i;

/**
 * Collapses the cosmetic differences between how Last.fm and TIDAL spell the
 * same recording, so "Paranoid Android - 2009 Remaster" matches "Paranoid
 * Android".
 */
export function normalizeForResolution(value) {
    return String(value || '')
        .toLowerCase()
        .normalize('NFKD')
        .replace(/[̀-ͯ]/g, '')
        .replace(FEATURE_PATTERN, '')
        .replace(EDITION_PATTERN, '')
        .replace(/[^\p{L}\p{N}]+/gu, '');
}

export function resolveKey(artist, title) {
    return `${normalizeForResolution(artist)}|${normalizeForResolution(title)}`;
}
