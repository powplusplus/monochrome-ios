import { describe, expect, test, beforeEach, afterEach, vi } from 'vitest';
import { LosslessAPI, turnstileJwtExpiry } from '../api.js';

const base64Url = (value) => btoa(value).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const jwtWithExp = (expSeconds) => `header.${base64Url(JSON.stringify({ exp: expSeconds }))}.signature`;

describe('turnstileJwtExpiry', () => {
    test('retires the token a minute before the server-signed exp', () => {
        const exp = Math.floor(Date.now() / 1000) + 900;
        expect(turnstileJwtExpiry(jwtWithExp(exp))).toBe((exp - 60) * 1000);
    });

    test('never trusts a flat hour over a short-lived token', () => {
        const now = Date.now();
        const exp = Math.floor(now / 1000) + 300;
        expect(turnstileJwtExpiry(jwtWithExp(exp), now)).toBeLessThan(now + 60 * 60 * 1000);
    });

    test('falls back to 55 minutes when the token carries no usable exp', () => {
        const now = 1_700_000_000_000;
        expect(turnstileJwtExpiry('not-a-jwt', now)).toBe(now + 55 * 60 * 1000);
        expect(turnstileJwtExpiry(jwtWithExp(0), now)).toBe(now + 55 * 60 * 1000);
        expect(turnstileJwtExpiry(`header.${base64Url('{oops')}.sig`, now)).toBe(now + 55 * 60 * 1000);
    });
});

describe('LosslessAPI.getTurnstileJwt', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        localStorage.removeItem('amazon_turnstile_jwt');
        localStorage.removeItem('amazon_turnstile_expiry');
    });

    afterEach(() => {
        localStorage.removeItem('amazon_turnstile_jwt');
        localStorage.removeItem('amazon_turnstile_expiry');
        vi.restoreAllMocks();
        vi.unstubAllGlobals();
    });

    test('caches the JWT against its own exp, not a flat hour', async () => {
        const exp = Math.floor(Date.now() / 1000) + 300;
        const jwt = jwtWithExp(exp);
        vi.spyOn(api, 'getTurnstileResponse').mockResolvedValue('cf-token');
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response(JSON.stringify({ access_token: jwt }), { status: 200 }))
        );

        await expect(api.getTurnstileJwt()).resolves.toBe(jwt);
        expect(Number(localStorage.getItem('amazon_turnstile_expiry'))).toBe((exp - 60) * 1000);
    });

    test('re-solves once the server-signed exp has passed', async () => {
        const expired = jwtWithExp(Math.floor(Date.now() / 1000) - 10);
        const fresh = jwtWithExp(Math.floor(Date.now() / 1000) + 900);
        localStorage.setItem('amazon_turnstile_jwt', expired);
        localStorage.setItem('amazon_turnstile_expiry', turnstileJwtExpiry(expired).toString());

        const solve = vi.spyOn(api, 'getTurnstileResponse').mockResolvedValue('cf-token');
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response(JSON.stringify({ access_token: fresh }), { status: 200 }))
        );

        await expect(api.getTurnstileJwt()).resolves.toBe(fresh);
        expect(solve).toHaveBeenCalledTimes(1);
    });

    test('a forced refresh is not cancelled by the solve it replaced', async () => {
        const slow = jwtWithExp(Math.floor(Date.now() / 1000) + 900);
        const forced = jwtWithExp(Math.floor(Date.now() / 1000) + 1800);

        let releaseSlow;
        let releaseForced;
        const slowSolve = new Promise((resolve) => {
            releaseSlow = resolve;
        });
        const forcedSolve = new Promise((resolve) => {
            releaseForced = resolve;
        });
        let call = 0;
        vi.spyOn(api, 'getTurnstileResponse').mockImplementation(async () => {
            call += 1;
            if (call === 1) {
                await slowSolve;
                return 'slow-token';
            }
            await forcedSolve;
            return 'forced-token';
        });
        vi.stubGlobal(
            'fetch',
            vi.fn(async (_url, init) => {
                const token = JSON.parse(init.body).cf_turnstile_response;
                return new Response(JSON.stringify({ access_token: token === 'forced-token' ? forced : slow }), {
                    status: 200,
                });
            })
        );

        const first = api.getTurnstileJwt();
        const second = api.getTurnstileJwt({ forceRefresh: true });
        // The forced run owns the slot now; the first one finishing must not clear it.
        releaseSlow();
        await first;

        expect(api._turnstileJwtPromise).not.toBeNull();
        releaseForced();
        await expect(second).resolves.toBe(forced);
        expect(api._turnstileJwtPromise).toBeNull();
    });

    test('rejects an exchange that answers without a token instead of caching undefined', async () => {
        vi.spyOn(api, 'getTurnstileResponse').mockResolvedValue('cf-token');
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response(JSON.stringify({}), { status: 200 }))
        );

        await expect(api.getTurnstileJwt()).rejects.toThrow('no access token');
        expect(localStorage.getItem('amazon_turnstile_jwt')).toBeNull();
    });
});

describe('Turnstile challenge container', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
    });

    afterEach(() => {
        document.getElementById('amazon-music-turnstile-panel')?.remove();
        vi.restoreAllMocks();
    });

    test('gives every concurrent solve its own widget host', () => {
        const first = api.getTurnstileContainer();
        const second = api.getTurnstileContainer();

        expect(first).not.toBe(second);
        expect(document.querySelectorAll('.amazon-music-turnstile-container')).toHaveLength(2);
        expect(document.querySelectorAll('#amazon-music-turnstile-panel')).toHaveLength(1);
    });

    test('a finished solve does not tear the panel out from under a running one', async () => {
        const widgets = [];
        const turnstile = {
            render: (container, opts) => {
                const id = `w${widgets.length}`;
                widgets.push({ id, container, opts });
                return id;
            },
            execute: () => {},
            remove: () => {},
        };
        vi.spyOn(api, 'loadTurnstile').mockResolvedValue(turnstile);

        const first = api.getTurnstileResponse();
        const second = api.getTurnstileResponse();
        await Promise.resolve();
        await Promise.resolve();

        expect(widgets).toHaveLength(2);
        expect(widgets[0].container).not.toBe(widgets[1].container);

        widgets[0].opts.callback('token-one');
        await expect(first).resolves.toBe('token-one');
        // The second widget's host survived the first one's cleanup.
        expect(document.getElementById('amazon-music-turnstile-panel')).not.toBeNull();
        expect(widgets[1].container.isConnected).toBe(true);

        widgets[1].opts.callback('token-two');
        await expect(second).resolves.toBe('token-two');
        expect(document.getElementById('amazon-music-turnstile-panel')).toBeNull();
    });
});
