import { describe, expect, test, beforeEach, afterEach, vi } from 'vitest';
import { LosslessAPI } from '../api.js';

const base64Url = (value) => btoa(value).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const jwtWithExp = (expSeconds) => `header.${base64Url(JSON.stringify({ exp: expSeconds }))}.signature`;

const JWT_KEY = 'unified-playback-turnstile-jwt';
const EXPIRY_KEY = 'unified-playback-turnstile-expiry';

describe('LosslessAPI.getUnifiedTurnstileJwt', () => {
    let api;

    beforeEach(() => {
        api = new LosslessAPI({});
        localStorage.removeItem(JWT_KEY);
        localStorage.removeItem(EXPIRY_KEY);
    });

    afterEach(() => {
        localStorage.removeItem(JWT_KEY);
        localStorage.removeItem(EXPIRY_KEY);
        vi.restoreAllMocks();
        vi.unstubAllGlobals();
    });

    test('caches the JWT against its own exp, not a flat hour', async () => {
        // The exchange signs its own lifetime; caching a flat hour would keep
        // sending a token the API already considers dead.
        const exp = Math.floor(Date.now() / 1000) + 300;
        const jwt = jwtWithExp(exp);
        vi.spyOn(api, 'getTurnstileResponse').mockResolvedValue('cf-token');
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response(JSON.stringify({ access_token: jwt }), { status: 200 }))
        );

        await expect(api.getUnifiedTurnstileJwt()).resolves.toBe(jwt);
        expect(Number(localStorage.getItem(EXPIRY_KEY))).toBe(exp);
    });

    test('re-solves once the server-signed exp has passed', async () => {
        const expired = jwtWithExp(Math.floor(Date.now() / 1000) - 10);
        const fresh = jwtWithExp(Math.floor(Date.now() / 1000) + 900);
        localStorage.setItem(JWT_KEY, expired);
        localStorage.setItem(EXPIRY_KEY, String(Math.floor(Date.now() / 1000) - 10));

        const solve = vi.spyOn(api, 'getTurnstileResponse').mockResolvedValue('cf-token');
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response(JSON.stringify({ access_token: fresh }), { status: 200 }))
        );

        await expect(api.getUnifiedTurnstileJwt()).resolves.toBe(fresh);
        expect(solve).toHaveBeenCalledTimes(1);
    });

    test('retires a token that is inside the expiry skew rather than sending it once more', async () => {
        const nearlyDone = jwtWithExp(Math.floor(Date.now() / 1000) + 5);
        localStorage.setItem(JWT_KEY, nearlyDone);
        localStorage.setItem(EXPIRY_KEY, String(Math.floor(Date.now() / 1000) + 5));

        expect(api.getCachedUnifiedTurnstileJwt()).toBeNull();
        expect(localStorage.getItem(JWT_KEY)).toBeNull();
    });

    test('rejects an exchange that answers without a token instead of caching undefined', async () => {
        vi.spyOn(api, 'getTurnstileResponse').mockResolvedValue('cf-token');
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response(JSON.stringify({}), { status: 200 }))
        );

        await expect(api.getUnifiedTurnstileJwt()).rejects.toThrow('no JWT');
        expect(localStorage.getItem(JWT_KEY)).toBeNull();
    });

    test('shares one in-flight solve between concurrent callers', async () => {
        const jwt = jwtWithExp(Math.floor(Date.now() / 1000) + 900);
        const solve = vi.spyOn(api, 'getTurnstileResponse').mockResolvedValue('cf-token');
        vi.stubGlobal(
            'fetch',
            vi.fn(async () => new Response(JSON.stringify({ access_token: jwt }), { status: 200 }))
        );

        const [first, second] = await Promise.all([api.getUnifiedTurnstileJwt(), api.getUnifiedTurnstileJwt()]);

        expect(first).toBe(jwt);
        expect(second).toBe(jwt);
        expect(solve).toHaveBeenCalledTimes(1);
        expect(api._unifiedTurnstileJwtPromise).toBeNull();
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
