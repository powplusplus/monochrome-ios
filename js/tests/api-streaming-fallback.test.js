import { describe, expect, test, vi, beforeEach, afterEach } from 'vitest';
import { amazonMusicSettings, lucidaQobuzSettings } from '../storage.js';

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
        lucidaQobuzSettings: {
            isEnabled: vi.fn(() => true),
            setEnabled: vi.fn(),
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
        amazonMusicSettings.isEnabled.mockReturnValue(true);
        lucidaQobuzSettings.isEnabled.mockReturnValue(true);
        vi.spyOn(api, 'getTrackMetadata').mockResolvedValue({ id: '123', isrc: 'TESTISRC123' });
        vi.spyOn(api, 'getAmazonMusicStreamUrl').mockResolvedValue(null);
        vi.spyOn(api, 'getQobuzStreamUrl').mockResolvedValue(null);
        vi.spyOn(api, 'getDeezerStreamUrl').mockResolvedValue(null);
        vi.spyOn(api, 'getTrack').mockResolvedValue(null);
    });

    afterEach(() => {
        vi.restoreAllMocks();
    });

    test('uses Amazon Music before Lucida when Amazon resolves', async () => {
        api.getAmazonMusicStreamUrl.mockResolvedValue({
            url: 'blob:https://app.example/amazon',
            provider: 'amazon',
            playbackType: 'direct',
            quality: 'HD_44',
            rgInfo: {
                trackReplayGain: 0,
                trackPeakAmplitude: 1,
                albumReplayGain: 0,
                albumPeakAmplitude: 1,
            },
        });
        api.getQobuzStreamUrl.mockResolvedValue({
            url: 'https://audio.example/qobuz.flac',
            provider: 'qobuz',
        });

        const result = await api.getStreamUrl('123', 'LOSSLESS');

        expect(result).toMatchObject({
            url: 'blob:https://app.example/amazon',
            provider: 'amazon',
            playbackType: 'direct',
            quality: 'HD_44',
        });
        expect(api.getAmazonMusicStreamUrl).toHaveBeenCalled();
        expect(api.getQobuzStreamUrl).not.toHaveBeenCalled();
        expect(api.getTrack).not.toHaveBeenCalled();
    });

    test('falls back to Lucida when Amazon cannot resolve a stream URL', async () => {
        api.getQobuzStreamUrl.mockResolvedValue({
            url: 'https://audio.example/qobuz.flac',
            rgInfo: {
                trackReplayGain: -2,
                trackPeakAmplitude: 0.8,
                albumReplayGain: -3,
                albumPeakAmplitude: 0.85,
            },
        });

        const result = await api.getStreamUrl('123', 'LOSSLESS');

        expect(result.url).toBe('https://audio.example/qobuz.flac');
        expect(result.provider).toBe('qobuz');
        expect(api.getAmazonMusicStreamUrl).toHaveBeenCalled();
        expect(api.getQobuzStreamUrl).toHaveBeenCalled();
        expect(api.getTrack).not.toHaveBeenCalled();
    });

    test('falls back to Deezer when Amazon and Lucida both miss', async () => {
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
        expect(api.getAmazonMusicStreamUrl).toHaveBeenCalled();
        expect(api.getQobuzStreamUrl).toHaveBeenCalled();
        expect(api.getTrack).not.toHaveBeenCalled();
    });

    test('throws when Amazon, Lucida, and Deezer all miss', async () => {
        await expect(api.getStreamUrl('123', 'LOSSLESS')).rejects.toThrow(
            'Could not resolve stream URL from Amazon Music, Qobuz, or Deezer'
        );
        expect(api.getTrack).not.toHaveBeenCalled();
    });
});
