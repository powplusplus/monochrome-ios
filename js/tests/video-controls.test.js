import { describe, expect, test } from 'vitest';
import { collectTranscriptSources, heightToQualityLabel, srtToVtt } from '../video-controls.js';

describe('video-controls helpers', () => {
    test('srtToVtt converts commas and adds header', () => {
        const srt = '1\n00:00:01,000 --> 00:00:02,000\nHello\n';
        const vtt = srtToVtt(srt);
        expect(vtt.startsWith('WEBVTT')).toBe(true);
        expect(vtt).toContain('00:00:01.000 --> 00:00:02.000');
    });

    test('collectTranscriptSources prefers listed transcripts', () => {
        const sources = collectTranscriptSources({
            isPodcast: true,
            transcriptUrl: 'https://ex/a.srt',
            transcripts: [{ url: 'https://ex/b.vtt', type: 'text/vtt', language: 'en' }],
        });
        expect(sources[0].url).toBe('https://ex/b.vtt');
        expect(sources.some((s) => s.url === 'https://ex/a.srt')).toBe(true);
    });

    test('heightToQualityLabel', () => {
        expect(heightToQualityLabel(1080)).toBe('1080p');
        expect(heightToQualityLabel(0, 64000)).toBe('64k');
        expect(heightToQualityLabel(0)).toBe('Source');
    });
});
