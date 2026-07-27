import { expect, test, describe } from 'vitest';
import {
    l2Normalize,
    cosineSparse,
    buildTagVector,
    energyFromTags,
    toCamelot,
    harmonicFit,
    bpmProximity,
    eraBucket,
    popBand,
    durBand,
    eraProximity,
    tasteScore01,
    combineScore,
    candidateSimilarity,
    selectDiverse,
    normalizeForResolution,
    resolveKey,
    SCORE_WEIGHTS,
} from '../recommendation-vectors.js';

describe('sparse vector math', () => {
    test('l2Normalize produces a unit vector and survives an all-zero input', () => {
        const normalized = l2Normalize({ a: 3, b: 4 });
        expect(normalized.a).toBeCloseTo(0.6);
        expect(normalized.b).toBeCloseTo(0.8);

        expect(l2Normalize({ a: 0, b: 0 })).toEqual({});
        expect(l2Normalize({})).toEqual({});
    });

    test('cosineSparse returns 0 rather than NaN when either side is empty', () => {
        expect(cosineSparse({ rock: 1 }, { rock: 1 })).toBeCloseTo(1);
        expect(cosineSparse({ rock: 1 }, { jazz: 1 })).toBe(0);
        expect(cosineSparse({}, { rock: 1 })).toBe(0);
        expect(cosineSparse({ rock: 1 }, {})).toBe(0);
        expect(cosineSparse(null, undefined)).toBe(0);
    });
});

describe('buildTagVector', () => {
    test('drops stopwords and low-count tags', () => {
        const vector = buildTagVector({
            trackTags: [
                { name: 'Shoegaze', count: 100 },
                { name: 'seen live', count: 100 },
                { name: 'noise', count: 5 },
            ],
        });
        expect(Object.keys(vector)).toEqual(['shoegaze']);
    });

    test('normalizes punctuation and ampersands', () => {
        const vector = buildTagVector({
            trackTags: [
                { name: 'Hip-Hop', count: 90 },
                { name: 'Drum & Bass', count: 80 },
            ],
        });
        expect(Object.keys(vector).sort()).toEqual(['drumandbass', 'hiphop']);
    });

    test('takes at most 10 track tags and caps the blended vector at 12', () => {
        const trackTags = Array.from({ length: 20 }, (_, i) => ({ name: `tag${i}`, count: 100 - i }));
        expect(Object.keys(buildTagVector({ trackTags })).length).toBe(10);

        const artistTags = Array.from({ length: 10 }, (_, i) => ({ name: `atag${i}`, count: 100 - i }));
        expect(Object.keys(buildTagVector({ trackTags, artistTags })).length).toBe(12);
    });

    test('blends artist tags harder when the track is barely tagged', () => {
        const artistTags = [{ name: 'ambient', count: 100 }];

        const wellTagged = buildTagVector({
            trackTags: [
                { name: 'rock', count: 100 },
                { name: 'indie', count: 100 },
                { name: 'pop', count: 100 },
            ],
            artistTags,
        });
        const barelyTagged = buildTagVector({
            trackTags: [{ name: 'rock', count: 100 }],
            artistTags,
        });

        // ratio of artist tag to track tag is higher in the sparse case
        expect(barelyTagged.ambient / barelyTagged.rock).toBeGreaterThan(wellTagged.ambient / wellTagged.rock);
    });

    test('an artist tag never overwrites the same tag from the track', () => {
        const vector = buildTagVector({
            trackTags: [{ name: 'techno', count: 100 }],
            artistTags: [{ name: 'techno', count: 20 }],
        });
        expect(Object.keys(vector)).toEqual(['techno']);
    });
});

describe('energyFromTags', () => {
    test('reports zero confidence when no tag is recognized', () => {
        expect(energyFromTags({ somethingunknown: 1 })).toEqual({ energy: 0.5, energyConfidence: 0 });
        expect(energyFromTags({})).toEqual({ energy: 0.5, energyConfidence: 0 });
    });

    test('rates drum and bass hotter than ambient', () => {
        const fast = energyFromTags({ drumandbass: 1 });
        const slow = energyFromTags({ ambient: 1 });
        expect(fast.energy).toBeGreaterThan(slow.energy);
        expect(fast.energyConfidence).toBeGreaterThan(0);
    });
});

describe('camelot wheel', () => {
    test('maps keys to wheel codes, including flats', () => {
        expect(toCamelot('A', 'MINOR')).toBe('8A');
        expect(toCamelot('C', 'MAJOR')).toBe('8B');
        expect(toCamelot('Bb', 'MINOR')).toBe('3A');
        expect(toCamelot('Db', 'MAJOR')).toBe('3B');
        expect(toCamelot(null, 'MINOR')).toBeNull();
        expect(toCamelot('H', 'MAJOR')).toBeNull();
    });

    test('harmonicFit scores identical, adjacent, relative and unrelated keys', () => {
        expect(harmonicFit('8A', '8A')).toBe(1);
        expect(harmonicFit('8A', '8B')).toBe(0.8); // relative major/minor
        expect(harmonicFit('8A', '9A')).toBe(0.8); // one step round the wheel
        expect(harmonicFit('12A', '1A')).toBe(0.8); // wraps around
        expect(harmonicFit('8A', '2A')).toBe(0.3);
        expect(harmonicFit('8A', null)).toBeNull();
    });
});

describe('bpmProximity', () => {
    test('peaks on an exact match', () => {
        expect(bpmProximity(128, 128)).toBe(1);
    });

    test('gives half/double-time credit', () => {
        expect(bpmProximity(174, 87)).toBe(1);
        expect(bpmProximity(87, 174)).toBe(1);
    });

    test('penalizes genuinely different tempos', () => {
        expect(bpmProximity(100, 145)).toBeLessThan(0.2);
    });

    test('returns null when either tempo is unknown', () => {
        expect(bpmProximity(null, 120)).toBeNull();
        expect(bpmProximity(120, null)).toBeNull();
    });
});

describe('metadata bands', () => {
    test('era buckets split on the decade boundary', () => {
        expect(eraBucket(1979)).toBe('70s');
        expect(eraBucket(1980)).toBe('80s');
        expect(eraBucket(1969)).toBe('pre70s');
        expect(eraBucket(2024)).toBe('20s');
        expect(eraBucket(null)).toBeNull();
    });

    test('popularity bands split on the documented thresholds', () => {
        expect(popBand(19)).toBe(0);
        expect(popBand(20)).toBe(1);
        expect(popBand(79)).toBe(3);
        expect(popBand(80)).toBe(4);
        expect(popBand(undefined)).toBeNull();
    });

    test('duration bands split on the documented thresholds (ms)', () => {
        expect(durBand(119_999)).toBe('short');
        expect(durBand(120_000)).toBe('med');
        expect(durBand(419_999)).toBe('long');
        expect(durBand(420_000)).toBe('epic');
        expect(durBand(0)).toBeNull();
    });

    test('unknown release years score neutral, not zero', () => {
        expect(eraProximity(null, 2000)).toBe(0.5);
        expect(eraProximity(2000, 2000)).toBe(1);
        expect(eraProximity(1960, 2000)).toBe(0);
    });

    test('tasteScore01 maps the raw range into [0,1]', () => {
        expect(tasteScore01(-5)).toBe(0);
        expect(tasteScore01(6)).toBe(1);
        expect(tasteScore01(0.5)).toBeCloseTo(0.5);
        expect(tasteScore01(-100)).toBe(0);
        expect(tasteScore01(undefined)).toBe(0.5);
    });
});

describe('combineScore', () => {
    test('computes the plain weighted sum when every term is present', () => {
        const terms = Object.fromEntries(Object.keys(SCORE_WEIGHTS).map((name) => [name, 0.5]));
        const { score } = combineScore(terms);
        expect(score).toBeCloseTo(0.5);
    });

    test('renormalizes surviving weights when terms are missing', () => {
        const { score, usedWeights } = combineScore({
            tagSimilarity: null,
            bpmProximity: null,
            harmonicFit: null,
            artistProximity: 1,
            taste: 1,
            eraProximity: 1,
            popProximity: 1,
            sourcePrior: 1,
            energyProximity: 1,
            durProximity: 1,
        });

        const total = Object.values(usedWeights).reduce((a, b) => a + b, 0);
        expect(total).toBeCloseTo(1);
        expect(usedWeights.tagSimilarity).toBeUndefined();
        expect(score).toBeCloseTo(1);
    });

    test('subtracts penalties and clamps the result', () => {
        const { score } = combineScore({ artistProximity: 0 }, { dislikeSimilarity: 1, artistPenalty: 1 });
        expect(score).toBeCloseTo(-0.35);

        const floored = combineScore({ artistProximity: 0 }, { dislikeSimilarity: 10, artistPenalty: 10 });
        expect(floored.score).toBe(-1);
    });

    test('returns 0 when no term at all is available', () => {
        expect(combineScore({}).score).toBe(0);
    });
});

describe('selectDiverse', () => {
    const track = (id, artist, score, extra = {}) => ({
        id,
        score,
        artistIds: [artist],
        albumId: `alb-${id}`,
        tags: {},
        bpm: null,
        ...extra,
    });

    test('caps a single artist at two per ten even when it dominates on score', () => {
        const candidates = [
            ...Array.from({ length: 5 }, (_, i) => track(`hog${i}`, 'A', 1)),
            ...Array.from({ length: 5 }, (_, i) => track(`other${i}`, `B${i}`, 0.1)),
        ];

        const selected = selectDiverse(candidates, 5, [], { exploreRatio: 0 });
        expect(selected.length).toBe(5);
        expect(selected.filter((t) => t.artistIds[0] === 'A').length).toBe(2);
    });

    test('counts the already-queued tail against the cap', () => {
        const queueTail = [track('q1', 'A', 1), track('q2', 'A', 1)];
        const candidates = [track('c1', 'A', 1), track('c2', 'B', 0.1)];

        const selected = selectDiverse(candidates, 1, queueTail, { exploreRatio: 0 });
        expect(selected[0].artistIds[0]).toBe('B');
    });

    test('prefers a dissimilar candidate over a near-duplicate of a pick', () => {
        const candidates = [
            track('a', 'A', 1.0, { tags: { techno: 1 } }),
            track('b', 'B', 0.95, { tags: { techno: 1 } }),
            track('c', 'C', 0.9, { tags: { folk: 1 } }),
        ];

        const selected = selectDiverse(candidates, 2, [], { exploreRatio: 0, lambda: 0.5 });
        expect(selected.map((t) => t.id)).toEqual(['a', 'c']);
    });

    test('fills the exploration quota even when explore picks score worst', () => {
        const candidates = [
            ...Array.from({ length: 8 }, (_, i) => track(`known${i}`, `K${i}`, 1)),
            track('fresh1', 'F1', 0.01, { isExplore: true }),
            track('fresh2', 'F2', 0.01, { isExplore: true }),
        ];

        const selected = selectDiverse(candidates, 10, [], { exploreRatio: 0.2 });
        expect(selected.filter((t) => t.isExplore).length).toBeGreaterThanOrEqual(2);
    });

    test('relaxes constraints rather than stalling on a homogeneous pool', () => {
        const candidates = Array.from({ length: 6 }, (_, i) =>
            track(`same${i}`, 'A', 1, { albumId: 'one-album' })
        );
        const selected = selectDiverse(candidates, 5, [], { exploreRatio: 0.2 });
        expect(selected.length).toBe(5);
    });

    test('never returns more than the pool holds', () => {
        expect(selectDiverse([track('x', 'A', 1)], 8).length).toBe(1);
        expect(selectDiverse([], 8).length).toBe(0);
    });

    test('candidateSimilarity falls back to artist overlap with no tags', () => {
        const a = track('a', 'A', 1);
        const b = track('b', 'A', 1);
        const c = track('c', 'C', 1);
        expect(candidateSimilarity(a, b)).toBeCloseTo(0.3);
        expect(candidateSimilarity(a, c)).toBe(0);
    });
});

describe('resolution normalization', () => {
    test('strips remaster suffixes, features, punctuation and diacritics', () => {
        expect(normalizeForResolution('Paranoid Android - 2009 Remaster')).toBe('paranoidandroid');
        expect(normalizeForResolution('Paranoid Android')).toBe('paranoidandroid');
        expect(normalizeForResolution('Song (feat. X)')).toBe('song');
        expect(normalizeForResolution('Song [ft. Someone Else]')).toBe('song');
        expect(normalizeForResolution('Sigur Rós')).toBe('sigurros');
        expect(normalizeForResolution('Drum & Bass')).toBe('drumbass');
        expect(normalizeForResolution(null)).toBe('');
    });

    test('resolveKey joins the normalized pair', () => {
        expect(resolveKey('Radiohead', 'Paranoid Android - 2009 Remaster')).toBe('radiohead|paranoidandroid');
        expect(resolveKey('Radiohead', 'Paranoid Android')).toBe(resolveKey('radiohead', 'PARANOID ANDROID'));
    });
});
