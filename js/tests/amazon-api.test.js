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

describe('Unified Playback source selection', () => {
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
        // A client-owned token skips the Turnstile solve entirely.
        localStorage.setItem('unified-playback-enabled', 'true');
        localStorage.setItem('unified-playback-api-token', 'amp_private');
        localStorage.removeItem('unified-playback-rate-limited-until');
        api.streamCache?.clear?.();
    });

    afterEach(() => {
        localStorage.removeItem('unified-playback-enabled');
        localStorage.removeItem('unified-playback-api-token');
        vi.restoreAllMocks();
    });

    test('plays the Unified Playback stream and never asks Deezer', async () => {
        const calls = [];
        api.getUnifiedPlaybackStreamUrl = vi.fn(() => {
            calls.push('unified');
            return Promise.resolve({
                url: 'https://cdn.example/audio/track.flac',
                sourceUrl: 'https://cdn.example/audio/track.flac',
                provider: 'monochrome',
                playbackType: 'direct',
                quality: 'LOSSLESS',
            });
        });
        api.getDeezerStreamUrl = vi.fn(() => {
            calls.push('deezer');
            return Promise.resolve({ url: 'https://deezer.example/audio.flac', format: 'FLAC' });
        });

        const result = await api.getStreamUrl('71513806', 'LOSSLESS');

        expect(result.provider).toBe('monochrome');
        expect(calls).toEqual(['unified']);
    });

    test('falls through to Deezer when Unified Playback returns nothing', async () => {
        const calls = [];
        api.getUnifiedPlaybackStreamUrl = vi.fn(() => {
            calls.push('unified');
            return Promise.resolve(null);
        });
        api.getDeezerStreamUrl = vi.fn(() => {
            calls.push('deezer');
            return Promise.resolve({ url: 'https://deezer.example/audio.flac', format: 'FLAC' });
        });

        const result = await api.getStreamUrl('71513806', 'LOSSLESS');

        expect(result.provider).toBe('deezer');
        expect(calls).toEqual(['unified', 'deezer']);
    });

    test('a rate-limited client does not spend a request on the next track', async () => {
        localStorage.setItem('unified-playback-rate-limited-until', String(Date.now() + 60_000));
        const fetchMock = vi.fn();
        vi.stubGlobal('fetch', fetchMock);

        await expect(
            api.fetchUnifiedPlaybackEnvelope({ title: 'Song', artist: { name: 'Artist' } }, 'LOSSLESS')
        ).resolves.toBeNull();
        expect(fetchMock).not.toHaveBeenCalled();

        localStorage.removeItem('unified-playback-rate-limited-until');
        vi.unstubAllGlobals();
    });
});

describe('Unified Playback API lookup', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        localStorage.setItem('unified-playback-enabled', 'true');
        localStorage.setItem('unified-playback-api-base-url', 'https://music-api.geeked.wtf');
        localStorage.setItem('unified-playback-api-token', 'amp_private');
        localStorage.removeItem('unified-playback-rate-limited-until');
    });

    afterEach(() => {
        localStorage.removeItem('unified-playback-enabled');
        localStorage.removeItem('unified-playback-api-base-url');
        localStorage.removeItem('unified-playback-api-token');
        vi.unstubAllGlobals();
        vi.restoreAllMocks();
    });

    test('sends the envelope lookup the API documents', async () => {
        const fetchMock = vi.fn(() =>
            Promise.resolve({
                ok: true,
                status: 200,
                headers: new Headers(),
                json: () =>
                    Promise.resolve({
                        schema_version: '2.0',
                        quality_requested: 'HI_RES_LOSSLESS',
                        selected_source: 'mono',
                        track: { id: 'REC1', duration_ms: 183400 },
                        playback: [
                            {
                                kind: 'audio',
                                delivery: 'direct',
                                source: 'mono',
                                quality: 'LOSSLESS',
                                url: 'https://cdn.example/audio/track.flac',
                                mime_type: 'audio/flac',
                                bit_depth: 24,
                                sample_rate_hz: 96000,
                            },
                        ],
                    }),
            })
        );
        vi.stubGlobal('fetch', fetchMock);

        const result = await api.getUnifiedPlaybackStreamUrl('71513806', 'HI_RES_LOSSLESS', {
            track: {
                title: 'Song & More',
                version: 'Live',
                artist: { name: 'Artist Name' },
                artists: [{ name: 'Artist Name' }, { name: 'Featured Name' }],
                album: { title: 'Album Title' },
                duration: 183.4,
                isrc: 'usabc1234567',
            },
        });

        expect(result.provider).toBe('monochrome');
        expect(result.url).toBe('https://cdn.example/audio/track.flac');
        expect(result.playbackType).toBe('direct');
        expect(result.bitDepth).toBe(24);
        expect(result.sampleRate).toBe(96000);

        const requestUrl = new URL(fetchMock.mock.calls[0][0]);
        expect(requestUrl.origin).toBe('https://music-api.geeked.wtf');
        expect(requestUrl.pathname).toBe('/api/v2/track/');
        expect(requestUrl.searchParams.get('track')).toBe('Song & More (Live)');
        expect(requestUrl.searchParams.get('duration')).toBe('183');
        expect(requestUrl.searchParams.get('album')).toBe('Album Title');
        expect(requestUrl.searchParams.get('artist')).toBe('Artist Name, Featured Name');
        expect(requestUrl.searchParams.get('isrc')).toBe('USABC1234567');
        expect(requestUrl.searchParams.get('intent')).toBe('stream');
        expect(requestUrl.searchParams.get('quality')).toBe('HI_RES_LOSSLESS');

        const headers = fetchMock.mock.calls[0][1].headers;
        expect(headers.Authorization).toBe('Bearer amp_private');
    });

    test('refuses an envelope whose schema version it cannot read', async () => {
        vi.stubGlobal(
            'fetch',
            vi.fn(() =>
                Promise.resolve({
                    ok: true,
                    status: 200,
                    headers: new Headers(),
                    json: () => Promise.resolve({ schema_version: '3.0', playback: [] }),
                })
            )
        );

        // The resolver swallows the failure so the caller can drop to Deezer.
        await expect(
            api.getUnifiedPlaybackStreamUrl('71513806', 'LOSSLESS', { track: { title: 'Song' } })
        ).resolves.toBeNull();
    });

    test('takes the whole leg out of service on a 429', async () => {
        vi.stubGlobal(
            'fetch',
            vi.fn(() =>
                Promise.resolve({
                    ok: false,
                    status: 429,
                    headers: new Headers({ 'Retry-After': '120' }),
                    json: () => Promise.resolve({ detail: 'rate limited' }),
                })
            )
        );

        await expect(
            api.getUnifiedPlaybackStreamUrl('71513806', 'LOSSLESS', { track: { title: 'Song' } })
        ).resolves.toBeNull();
        expect(api.isUnifiedPlaybackRateLimited()).toBe(true);
        localStorage.removeItem('unified-playback-rate-limited-until');
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

    test('returns the cached Unified Playback JWT until it is close to expiry', async () => {
        localStorage.setItem('unified-playback-turnstile-jwt', 'cached-jwt');
        localStorage.setItem('unified-playback-turnstile-expiry', String(Math.floor(Date.now() / 1000) + 600));
        api.getTurnstileResponse = vi.fn();

        await expect(api.getUnifiedTurnstileJwt()).resolves.toBe('cached-jwt');
        expect(api.getTurnstileResponse).not.toHaveBeenCalled();

        localStorage.removeItem('unified-playback-turnstile-jwt');
        localStorage.removeItem('unified-playback-turnstile-expiry');
    });

    test('exchanges a Turnstile token for a Unified Playback JWT', async () => {
        api.getTurnstileResponse = vi.fn(() => Promise.resolve('cf-token'));
        vi.stubGlobal(
            'fetch',
            vi.fn(() =>
                Promise.resolve({
                    ok: true,
                    status: 200,
                    headers: new Headers(),
                    json: () => Promise.resolve({ access_token: 'fresh-jwt' }),
                })
            )
        );

        await expect(api.getUnifiedTurnstileJwt({ forceRefresh: true })).resolves.toBe('fresh-jwt');
        expect(localStorage.getItem('unified-playback-turnstile-jwt')).toBe('fresh-jwt');
        // The exchange verifies the action the widget was rendered with.
        expect(api.getTurnstileResponse).toHaveBeenCalledWith(
            expect.objectContaining({ action: 'auth' })
        );
        expect(fetch).toHaveBeenCalledWith(
            expect.stringContaining('/api/auth/turnstile'),
            expect.objectContaining({
                method: 'POST',
                body: JSON.stringify({ turnstile_token: 'cf-token' }),
            })
        );

        localStorage.removeItem('unified-playback-turnstile-jwt');
        localStorage.removeItem('unified-playback-turnstile-expiry');
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
