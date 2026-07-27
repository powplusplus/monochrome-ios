import { expect, test, describe, beforeEach, afterEach, vi } from 'vitest';
import { MusicDatabase } from '../db.js';

describe('MusicDatabase', () => {
    let db;
    const TEST_DB_NAME = 'TestMonochromeDB';

    beforeEach(async () => {
        db = new MusicDatabase();
        db.dbName = TEST_DB_NAME;
        const req = indexedDB.deleteDatabase(TEST_DB_NAME);
        await new Promise((resolve) => {
            req.onsuccess = resolve;
            req.onerror = resolve;
        });
    });

    afterEach(async () => {
        if (db.db) {
            db.db.close();
        }
        const req = indexedDB.deleteDatabase(TEST_DB_NAME);
        await new Promise((resolve) => {
            req.onsuccess = resolve;
            req.onerror = resolve;
        });
    });

    test('opens database and creates stores', async () => {
        const openedDb = await db.open();
        expect(openedDb.name).toBe(TEST_DB_NAME);
        expect(openedDb.objectStoreNames.contains('favorites_tracks')).toBe(true);
        expect(openedDb.objectStoreNames.contains('history_tracks')).toBe(true);
        expect(openedDb.objectStoreNames.contains('user_playlists')).toBe(true);
        expect(openedDb.objectStoreNames.contains('podcast_progress')).toBe(true);
        expect(openedDb.objectStoreNames.contains('track_features')).toBe(true);
        expect(openedDb.objectStoreNames.contains('lastfm_resolution')).toBe(true);
    });

    test('track features round-trip in a single batch', async () => {
        await db.putTrackFeatures([
            { id: 1, bpm: 128, tags: { house: 1 } },
            { id: '2', bpm: null, tags: {} },
        ]);

        const found = await db.getTrackFeatures([1, 2, 3]);
        expect(found.size).toBe(2);
        expect(found.get('1').bpm).toBe(128);
        expect(found.get('2').bpm).toBeNull();
        expect(found.get('1').fetchedAt).toBeGreaterThan(0);
        expect(found.has('3')).toBe(false);

        const single = await db.getTrackFeature(1);
        expect(single.tags).toEqual({ house: 1 });
    });

    test('getTrackFeatures returns an empty map for no ids', async () => {
        await db.open();
        expect((await db.getTrackFeatures([])).size).toBe(0);
    });

    test('pruneTrackFeatures drops expired rows then trims to the cap', async () => {
        const now = Date.now();
        await db.putTrackFeatures([
            { id: 'expired', fetchedAt: now - 1000, stale: true },
            { id: 'old', fetchedAt: now - 300 },
            { id: 'mid', fetchedAt: now - 200 },
            { id: 'new', fetchedAt: now - 100 },
        ]);

        const deleted = await db.pruneTrackFeatures({
            maxEntries: 2,
            isExpired: (row) => row.stale === true,
        });

        expect(deleted).toBe(2); // 1 expired + 1 over the cap
        const remaining = await db.getTrackFeatures(['expired', 'old', 'mid', 'new']);
        expect([...remaining.keys()].sort()).toEqual(['mid', 'new']);
    });

    test('lastfm resolutions cache both hits and misses', async () => {
        await db.putResolution({ key: 'radiohead|creep', trackId: '42' });
        await db.putResolution({ key: 'nobody|nothing', notFound: true });

        expect((await db.getResolution('radiohead|creep')).trackId).toBe('42');
        expect((await db.getResolution('nobody|nothing')).notFound).toBe(true);
        expect(await db.getResolution('missing|key')).toBeUndefined();

        const deleted = await db.pruneResolutions({ maxEntries: 1 });
        expect(deleted).toBe(1);
    });

    test('podcast progress saves to the second and resume rejects finished', async () => {
        await db.open();
        await db.savePodcastProgress('podcast_1', 125, 600, { title: 'Ep' });
        const progress = await db.getPodcastProgress('podcast_1');
        expect(progress.position).toBe(125);
        expect(progress.duration).toBe(600);

        expect(await db.getPodcastResumePosition('podcast_1')).toBe(125);

        await db.savePodcastProgress('podcast_1', 590, 600);
        expect(await db.getPodcastResumePosition('podcast_1')).toBe(0);
        expect(await db.getPodcastProgress('podcast_1')).toBeUndefined();
    });

    test('rejects podcasts from playlists', async () => {
        const podcast = { id: 'podcast_99', title: 'Ep', isPodcast: true, enclosureUrl: 'https://x' };
        const playlist = await db.createPlaylist('Mix', [podcast]);
        expect(playlist.tracks.length).toBe(0);

        await expect(db.addTrackToPlaylist(playlist.id, podcast)).rejects.toThrow(
            'Podcasts cannot be added to playlists'
        );
    });

    test('toggleFavorite adds and removes items', async () => {
        const track = { id: 'track1', title: 'Test Track', artist: { name: 'Artist' } };

        const added = await db.toggleFavorite('track', track);
        expect(added).toBe(true);
        const favorites = await db.getFavorites('track');
        expect(favorites.length).toBe(1);
        expect(favorites[0].id).toBe('track1');

        const removed = await db.toggleFavorite('track', track);
        expect(removed).toBe(false);
        const favoritesAfter = await db.getFavorites('track');
        expect(favoritesAfter.length).toBe(0);
    });

    test('addToHistory manages recent tracks and avoids duplicates', async () => {
        const track1 = { id: 't1', title: 'Track 1' };
        const track2 = { id: 't2', title: 'Track 2' };

        await db.addToHistory(track1);
        await db.addToHistory(track2);
        await db.addToHistory(track1);

        const history = await db.getHistory();
        expect(history.length).toBe(2);
        expect(history[0].id).toBe('t1');
        expect(history[1].id).toBe('t2');
    });

    test('playlist operations: create, add, remove, delete', async () => {
        const track = { id: 'track1', title: 'Test Track' };

        const playlist = await db.createPlaylist('My Playlist', [track]);
        expect(playlist.name).toBe('My Playlist');
        expect(playlist.tracks.length).toBe(1);

        const track2 = { id: 'track2', title: 'Track 2' };
        await db.addTrackToPlaylist(playlist.id, track2);

        const updated = await db.getPlaylist(playlist.id);
        expect(updated.tracks.length).toBe(2);
        expect(updated.tracks[1].id).toBe('track2');

        await db.removeTrackFromPlaylist(playlist.id, 'track1');
        const afterRemove = await db.getPlaylist(playlist.id);
        expect(afterRemove.tracks.length).toBe(1);
        expect(afterRemove.tracks[0].id).toBe('track2');

        await db.deletePlaylist(playlist.id);
        const deleted = await db.getPlaylist(playlist.id);
        expect(deleted).toBeUndefined();
    });

    test('pinned items management', async () => {
        const album = { id: 'album1', title: 'Album 1', type: 'album' };

        await db.togglePinned(album, 'album');
        let pinned = await db.getPinned();
        expect(pinned.length).toBe(1);
        expect(pinned[0].id).toBe('album1');

        await db.togglePinned({ id: 'a2', title: 'A2' }, 'album');
        await db.togglePinned({ id: 'a3', title: 'A3' }, 'album');
        await db.togglePinned({ id: 'a4', title: 'A4' }, 'album');

        pinned = await db.getPinned();
        expect(pinned.length).toBe(3);
        expect(pinned.some((p) => p.id === 'a4')).toBe(true);
        expect(pinned.some((p) => p.id === 'album1')).toBe(false);
    });
});
