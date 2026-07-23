import { expect, test, describe, beforeEach, afterEach, vi } from 'vitest';
import { LosslessAPI } from '../api.js';
import { MusicAPI } from '../music-api.js';

describe('Amazon Music playback metadata', () => {
    const api = new LosslessAPI({});

    test('uses MP4 codec identifiers in generated DASH metadata', () => {
        expect(api.getAmazonCodecString('flac')).toBe('fLaC');
        expect(api.getAmazonCodecString('aac')).toBe('mp4a.40.2');
        expect(api.getAmazonCodecString('eac3')).toBe('ec-3');
    });

    test('uses the normalized codec in Amazon MIME types and manifests', () => {
        const qualityInfo = { codec: 'flac', bandwidth: 1200000, sampleRate: 96000 };
        expect(api.getAmazonMimeType(qualityInfo)).toBe('audio/mp4; codecs="fLaC"');

        const manifest = api.createAmazonMusicDashManifest(
            'https://amazon.example/audio.mp4',
            { asin: 'B000000000' },
            qualityInfo,
            {
                keyId: '00112233445566778899aabbccddeeff',
                initRangeEnd: 999,
                sidx: {
                    start: 1000,
                    end: 1099,
                    durationSeconds: 180,
                    timescale: 44100,
                    earliestPresentationTime: 0,
                },
            }
        );

        expect(manifest).toContain('codecs="fLaC"');
        expect(manifest).toContain('mimeType="audio/mp4"');
        expect(manifest).toContain('cenc:default_KID="00112233-4455-6677-8899-aabbccddeeff"');
    });
});

describe('Amazon Music source selection', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        api.getTrackMetadata = vi.fn(() =>
            Promise.resolve({
                id: '71513806',
                title: 'Song',
                artist: { name: 'Artist' },
                album: { title: 'Album' },
                isrc: 'USABC1234567',
            })
        );
        localStorage.setItem('amazon-music-enabled', 'true');
        localStorage.setItem('amazon-music-turnstile-bypass-token', 'test-bypass');
        localStorage.removeItem('amazon-music-rate-limited-until');
        api.streamCache?.clear?.();
    });

    afterEach(() => {
        localStorage.removeItem('amazon-music-enabled');
        localStorage.removeItem('amazon-music-turnstile-bypass-token');
        vi.restoreAllMocks();
    });

    test('tries Amazon first when the 50/50 playback roll prefers Amazon', async () => {
        vi.spyOn(Math, 'random').mockReturnValue(0.75);
        const calls = [];
        api.getAmazonMusicStreamUrl = vi.fn(() => {
            calls.push('amazon');
            return Promise.resolve({
                url: 'https://amazon.example/audio.mp4',
                sourceUrl: 'https://amazon.example/audio.mp4',
                provider: 'amazon',
                playbackType: 'direct',
                quality: 'HD',
                qualityDisplay: 'FLAC',
            });
        });
        api.getQobuzStreamUrl = vi.fn(() => {
            calls.push('qobuz');
            return Promise.resolve({ url: 'https://qobuz.example/audio.flac' });
        });

        const result = await api.getStreamUrl('71513806', 'LOSSLESS');

        expect(result.provider).toBe('amazon');
        expect(calls).toEqual(['amazon']);
    });

    test('tries Qobuz first when the 50/50 playback roll prefers Qobuz', async () => {
        vi.spyOn(Math, 'random').mockReturnValue(0.25);
        const calls = [];
        api.getAmazonMusicStreamUrl = vi.fn(() => {
            calls.push('amazon');
            return Promise.resolve({
                url: 'https://amazon.example/audio.mp4',
                sourceUrl: 'https://amazon.example/audio.mp4',
                provider: 'amazon',
            });
        });
        api.getQobuzStreamUrl = vi.fn(() => {
            calls.push('qobuz');
            return Promise.resolve({ url: 'https://qobuz.example/audio.flac', rgInfo: null });
        });

        const result = await api.getStreamUrl('71513806', 'LOSSLESS');

        expect(result.provider).toBe('qobuz');
        expect(calls).toEqual(['qobuz']);
    });

    test('falls back to Qobuz when Amazon is preferred but cannot resolve a stream', async () => {
        vi.spyOn(Math, 'random').mockReturnValue(0.75);
        const calls = [];
        api.getAmazonMusicStreamUrl = vi.fn(() => {
            calls.push('amazon');
            return Promise.resolve(null);
        });
        api.getQobuzStreamUrl = vi.fn(() => {
            calls.push('qobuz');
            return Promise.resolve({ url: 'https://qobuz.example/audio.flac', rgInfo: null });
        });

        const result = await api.getStreamUrl('71513806', 'LOSSLESS');

        expect(result.provider).toBe('qobuz');
        expect(calls).toEqual(['amazon', 'qobuz']);
    });

    test('falls back to Amazon when Qobuz is preferred but cannot resolve a stream', async () => {
        vi.spyOn(Math, 'random').mockReturnValue(0.25);
        const calls = [];
        api.getAmazonMusicStreamUrl = vi.fn(() => {
            calls.push('amazon');
            return Promise.resolve({
                url: 'https://amazon.example/audio.mp4',
                sourceUrl: 'https://amazon.example/audio.mp4',
                provider: 'amazon',
            });
        });
        api.getQobuzStreamUrl = vi.fn(() => {
            calls.push('qobuz');
            return Promise.resolve(null);
        });

        const result = await api.getStreamUrl('71513806', 'LOSSLESS');

        expect(result.provider).toBe('amazon');
        expect(calls).toEqual(['qobuz', 'amazon']);
    });
});

describe('Amazon Music combined API lookup', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        localStorage.setItem('amazon-music-enabled', 'true');
        localStorage.setItem('amazon-music-api-base-url', 'https://amz.geeked.wtf');
        localStorage.setItem('amazon-music-turnstile-bypass-token', 'trusted-token');
        localStorage.removeItem('amazon-music-rate-limited-until');
    });

    afterEach(() => {
        localStorage.removeItem('amazon-music-api-base-url');
        localStorage.removeItem('amazon-music-turnstile-bypass-token');
        vi.unstubAllGlobals();
        vi.restoreAllMocks();
    });

    test('requests the combined metadata-to-stream endpoint', async () => {
        api.getAmazonCencMp4Info = vi.fn(() => Promise.resolve(null));
        const fetchMock = vi.fn(() =>
            Promise.resolve({
                ok: true,
                status: 200,
                json: () =>
                    Promise.resolve({
                        stream_url: 'https://amazon.example/audio.mp4',
                        quality_selected: 'HD',
                    }),
            })
        );
        vi.stubGlobal('fetch', fetchMock);

        const result = await api.getAmazonMusicStreamUrl('71513806', 'LOSSLESS', {
            track: {
                title: 'Song & More',
                version: 'Live',
                artist: { name: 'Artist Name' },
                artists: [{ name: 'Artist Name' }, { name: 'Featured Name' }],
                album: { title: 'Album Title' },
                duration: 183.4,
            },
        });

        expect(result.provider).toBe('amazon');
        expect(result.sourceUrl).toBe('https://amazon.example/audio.mp4');

        const requestUrl = new URL(fetchMock.mock.calls[0][0]);
        expect(requestUrl.origin).toBe('https://amz.geeked.wtf');
        expect(requestUrl.pathname).toBe('/api/track/');
        expect(requestUrl.searchParams.get('track')).toBe('Song & More (Live)');
        expect(requestUrl.searchParams.get('duration')).toBe('183');
        expect(requestUrl.searchParams.get('album')).toBe('Album Title');
        expect(requestUrl.searchParams.get('artist')).toBe('Artist Name, Featured Name');
        expect(requestUrl.searchParams.get('quality')).toBe('HD');
        expect(requestUrl.searchParams.get('bypass_token')).toBe('trusted-token');
    });
});

describe('Amazon Music Turnstile auth', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        document.body.innerHTML = '';
        localStorage.setItem('amazon-music-turnstile-site-key', 'test-site-key');
    });

    afterEach(() => {
        document.body.innerHTML = '';
        localStorage.removeItem('amazon-music-turnstile-site-key');
        localStorage.removeItem('amazon_turnstile_jwt');
        localStorage.removeItem('amazon_turnstile_expiry');
        vi.restoreAllMocks();
    });

    test('retries with a visible widget when the first Turnstile attempt fails', async () => {
        const renderConfigs = [];
        const turnstile = {
            render: vi.fn((_container, config) => {
                renderConfigs.push(config);
                const id = `widget-${renderConfigs.length}`;
                if (renderConfigs.length === 2) {
                    queueMicrotask(() => config.callback('visible-token'));
                }
                return id;
            }),
            execute: vi.fn(() => {
                renderConfigs[0]['error-callback']('110500');
            }),
            remove: vi.fn(),
        };
        api.loadTurnstile = vi.fn(() => Promise.resolve(turnstile));

        await expect(api.getTurnstileResponse()).resolves.toBe('visible-token');

        expect(turnstile.render).toHaveBeenCalledTimes(2);
        expect(renderConfigs[0]).toMatchObject({
            execution: 'execute',
            appearance: 'interaction-only',
        });
        expect(renderConfigs[1]).toMatchObject({
            execution: 'render',
            appearance: 'always',
        });
        expect(turnstile.execute).toHaveBeenCalledWith('widget-1');
    });

    test('keeps the Turnstile panel hidden when the invisible challenge auto-passes', async () => {
        const turnstile = {
            render: vi.fn((_container, config) => {
                queueMicrotask(() => config.callback('auto-token'));
                return 'widget-1';
            }),
            execute: vi.fn(),
            remove: vi.fn(),
        };
        api.loadTurnstile = vi.fn(() => Promise.resolve(turnstile));

        await expect(api.getTurnstileResponse()).resolves.toBe('auto-token');

        const panel = document.getElementById('amazon-music-turnstile-panel');
        expect(panel).toBeNull();
        expect(turnstile.execute).toHaveBeenCalledWith('widget-1');
    });

    test('shows the Turnstile panel only when Cloudflare requests interaction', async () => {
        let finishChallenge;
        const turnstile = {
            render: vi.fn((_container, config) => {
                queueMicrotask(() => {
                    config['before-interactive-callback']();
                });
                finishChallenge = () => config.callback('interactive-token');
                return 'widget-1';
            }),
            execute: vi.fn(),
            remove: vi.fn(),
        };
        api.loadTurnstile = vi.fn(() => Promise.resolve(turnstile));

        const tokenPromise = api.getTurnstileResponse();
        await vi.waitFor(() => {
            const panel = document.getElementById('amazon-music-turnstile-panel');
            expect(panel?.style.display).toBe('block');
        });
        finishChallenge();
        await expect(tokenPromise).resolves.toBe('interactive-token');
        expect(document.getElementById('amazon-music-turnstile-panel')).toBeNull();
    });

    test('returns cached Turnstile JWT until expiry', async () => {
        localStorage.setItem('amazon_turnstile_jwt', 'cached-jwt');
        localStorage.setItem('amazon_turnstile_expiry', String(Date.now() + 60_000));
        api.getTurnstileResponse = vi.fn();

        await expect(api.getTurnstileJwt()).resolves.toBe('cached-jwt');
        expect(api.getTurnstileResponse).not.toHaveBeenCalled();
    });

    test('exchanges a Turnstile token for a JWT', async () => {
        api.getTurnstileResponse = vi.fn(() => Promise.resolve('cf-token'));
        vi.stubGlobal(
            'fetch',
            vi.fn(() =>
                Promise.resolve({
                    ok: true,
                    status: 200,
                    json: () => Promise.resolve({ access_token: 'fresh-jwt' }),
                })
            )
        );

        await expect(api.getTurnstileJwt({ forceRefresh: true })).resolves.toBe('fresh-jwt');
        expect(localStorage.getItem('amazon_turnstile_jwt')).toBe('fresh-jwt');
        expect(fetch).toHaveBeenCalledWith(
            expect.stringContaining('/api/auth/turnstile'),
            expect.objectContaining({
                method: 'POST',
                body: JSON.stringify({ cf_turnstile_response: 'cf-token' }),
            })
        );
    });
});

describe('MusicAPI Amazon playback capability delegation', () => {
    test('forwards Amazon playback capability checks to the active API', async () => {
        const musicApi = new MusicAPI({});
        musicApi.tidalAPI.canPlayAmazonMusicStream = vi.fn(() => Promise.resolve(false));

        await expect(musicApi.canPlayAmazonMusicStream({ provider: 'amazon' })).resolves.toBe(false);
        expect(musicApi.tidalAPI.canPlayAmazonMusicStream).toHaveBeenCalledWith({ provider: 'amazon' });
    });
});
