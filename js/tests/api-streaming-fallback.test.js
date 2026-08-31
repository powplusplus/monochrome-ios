import { describe, expect, test, vi, beforeEach, afterEach } from 'vitest';
import { unifiedPlaybackSettings } from '../storage.js';

vi.mock('../utils.js', () => ({
    RATE_LIMIT_ERROR_MESSAGE: 'rate limited',
    deriveTrackQuality: vi.fn(),
    delay: vi.fn(() => Promise.resolve()),
    isTrackUnavailable: vi.fn(() => false),
    getExtensionFromBlob: vi.fn(),
    getTrackDiscNumber: vi.fn(),
    normalizeQualityToken: vi.fn((quality) => quality),
    getTrackCoverId: vi.fn(),
    getCoverBlob: vi.fn(),
}));

vi.mock('../storage.js', async (importOriginal) => {
    const actual = await importOriginal();
    return {
        ...actual,
        preferDolbyAtmosSettings: { isEnabled: vi.fn(() => false) },
        trackDateSettings: { useAlbumYear: vi.fn(() => false) },
        devModeSettings: { isEnabled: vi.fn(() => false), getUrl: vi.fn(() => '') },
        amazonMusicSettings: {
            isEnabled: vi.fn(() => true),
            getTurnstileBypassToken: vi.fn(() => 'bypass'),
            getTurnstileSiteKey: vi.fn(() => 'test-key'),
            getApiBaseUrl: vi.fn(() => 'https://amz.example'),
        },
        unifiedPlaybackSettings: {
            isEnabled: vi.fn(() => true),
            setEnabled: vi.fn(),
            getApiBaseUrl: vi.fn(() => 'https://music-api.example'),
            getApiToken: vi.fn(() => 'amp_private'),
            isDefaultApiToken: vi.fn(() => false),
            TURNSTILE_SITE_KEY: '0xTEST',
            TURNSTILE_ACTION: 'auth',
        },
    };
});

vi.mock('../cache.js', () => ({
    APICache: class {
        async get() {
            return null;
        }
        async set() {}
        async clearExpired() {}
    },
}));

vi.mock('../dash-downloader.ts', () => ({ DashDownloader: class {} }));
vi.mock('../hls-downloader.js', () => ({ HlsDownloader: class {} }));
vi.mock('../proxy-utils.js', () => ({ getProxyUrl: vi.fn((url) => url), wrapTidalUrl: vi.fn((url) => url) }));
vi.mock('../ffmpeg.js', () => ({ loadFfmpeg: vi.fn(), FfmpegError: class extends Error {}, ffmpeg: vi.fn() }));
vi.mock('../download-utils.ts', () => ({ triggerDownload: vi.fn(), applyAudioPostProcessing: vi.fn() }));
vi.mock('../ffmpegFormats.ts', () => ({ isCustomFormat: vi.fn(() => false) }));
vi.mock('../progressEvents.js', () => ({ DownloadProgress: class {} }));
vi.mock('../readableStreamIterator.js', () => ({ readableStreamIterator: vi.fn() }));
vi.mock('../HiFi.ts', () => ({
    HiFiClient: { instance: { query: vi.fn() } },
    TidalResponse: class {},
}));
vi.mock('../platform-detection.js', () => ({
    isIos: false,
    isSafari: false,
    isChrome: true,
    canUseNativeAmazonCenc: true,
}));
vi.mock('../container-classes.js', () => ({
    TrackAlbum: class {},
    EnrichedAlbum: class {},
    EnrichedTrack: class {},
    ReplayGain: class {},
    PlaybackInfo: class {
        constructor(value) {
            Object.assign(this, value);
        }
    },
    Track: class {},
    Album: class {},
    PreparedVideo: class {},
    PreparedTrack: class {},
}));

const { LosslessAPI } = await import('../api.js');

describe('LosslessAPI stream source fallback', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        api.streamCache?.clear?.();
        unifiedPlaybackSettings.isEnabled.mockReturnValue(true);
        vi.spyOn(api, 'getTrackMetadata').mockResolvedValue({ id: '123', isrc: 'TESTISRC123' });
        vi.spyOn(api, 'getUnifiedPlaybackStreamUrl').mockResolvedValue(null);
        vi.spyOn(api, 'getDeezerStreamUrl').mockResolvedValue(null);
        vi.spyOn(api, 'getTrack').mockResolvedValue(null);
    });

    afterEach(() => {
        vi.restoreAllMocks();
    });

    test('plays what Unified Playback resolves without touching Deezer', async () => {
        api.getUnifiedPlaybackStreamUrl.mockResolvedValue({
            url: 'https://cdn.example/audio/track.flac',
            sourceUrl: 'https://cdn.example/audio/track.flac',
            provider: 'monochrome',
            playbackType: 'direct',
            quality: 'LOSSLESS',
            rgInfo: {
                trackReplayGain: 0,
                trackPeakAmplitude: 1,
                albumReplayGain: 0,
                albumPeakAmplitude: 1,
            },
        });

        const result = await api.getStreamUrl('123', 'LOSSLESS');

        expect(result).toMatchObject({
            url: 'https://cdn.example/audio/track.flac',
            provider: 'monochrome',
            playbackType: 'direct',
            quality: 'LOSSLESS',
        });
        expect(api.getUnifiedPlaybackStreamUrl).toHaveBeenCalled();
        expect(api.getDeezerStreamUrl).not.toHaveBeenCalled();
        expect(api.getTrack).not.toHaveBeenCalled();
    });

    test('asks Unified Playback for the stream intent and the requested tier', async () => {
        api.getUnifiedPlaybackStreamUrl.mockResolvedValue({
            url: 'https://cdn.example/audio/track.flac',
            provider: 'monochrome',
            playbackType: 'direct',
            quality: 'LOSSLESS',
        });

        await api.getStreamUrl('123', 'HI_RES_LOSSLESS');

        expect(api.getUnifiedPlaybackStreamUrl).toHaveBeenCalledWith(
            '123',
            'HI_RES_LOSSLESS',
            expect.objectContaining({ intent: 'stream' })
        );
    });

    test('falls back to Deezer when Unified Playback cannot resolve the track', async () => {
        api.getDeezerStreamUrl.mockResolvedValue({
            url: 'https://audio.example/deezer.flac',
            format: 'FLAC',
        });

        const result = await api.getStreamUrl('123', 'LOSSLESS');

        expect(result).toMatchObject({
            url: 'https://audio.example/deezer.flac',
            provider: 'deezer',
            deezerFormat: 'FLAC',
        });
        expect(api.getUnifiedPlaybackStreamUrl).toHaveBeenCalled();
        expect(api.getTrack).not.toHaveBeenCalled();
    });

    test('throws when Unified Playback and Deezer both miss', async () => {
        await expect(api.getStreamUrl('123', 'LOSSLESS')).rejects.toThrow(
            'Could not resolve stream URL from Unified Playback or Deezer'
        );
        expect(api.getTrack).not.toHaveBeenCalled();
    });

    test('names the missing ISRC when there is nothing for Deezer to look up', async () => {
        api.getTrackMetadata.mockResolvedValue({ id: '123', title: 'Song', artist: { name: 'Artist' } });

        await expect(api.getStreamUrl('123', 'LOSSLESS')).rejects.toThrow('has no ISRC for Deezer lookup');
        expect(api.getDeezerStreamUrl).not.toHaveBeenCalled();
    });

    test('caches the resolved stream so a repeat play costs no lookup', async () => {
        api.getUnifiedPlaybackStreamUrl.mockResolvedValue({
            url: 'https://cdn.example/audio/track.flac',
            provider: 'monochrome',
            playbackType: 'direct',
            quality: 'LOSSLESS',
        });

        await api.getStreamUrl('123', 'LOSSLESS');
        await api.getStreamUrl('123', 'LOSSLESS');

        expect(api.getUnifiedPlaybackStreamUrl).toHaveBeenCalledTimes(1);
    });
});

describe('LosslessAPI Unified Playback CENC routing', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        api.streamCache?.clear?.();
        unifiedPlaybackSettings.isEnabled.mockReturnValue(true);
        vi.spyOn(api, 'getTrackMetadata').mockResolvedValue({ id: '123', isrc: 'TESTISRC123' });
        vi.spyOn(api, 'getDeezerStreamUrl').mockResolvedValue(null);
    });

    afterEach(() => {
        vi.restoreAllMocks();
    });

    test('leaves an Amazon CENC manifest alone where EME works', async () => {
        // `canUseNativeAmazonCenc` is stubbed true for this suite, so the DASH
        // manifest goes to the player untouched.
        vi.spyOn(api, 'getUnifiedPlaybackStreamUrl').mockResolvedValue({
            url: 'blob:https://app.example/manifest',
            sourceUrl: 'https://cdn.example/audio/track.mp4',
            provider: 'amazon',
            playbackType: 'dash-cenc',
            quality: 'UHD_96_24',
            decryptionKey: '00112233445566778899aabbccddeeff',
            codec: 'flac',
        });

        const result = await api.getStreamUrl('123', 'HI_RES_LOSSLESS');

        expect(result.url).toBe('blob:https://app.example/manifest');
        expect(result.playbackType).toBe('dash-cenc');
    });
});
