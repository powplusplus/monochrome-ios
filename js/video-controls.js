// js/video-controls.js
// Fullscreen captions + video quality menus for music videos and video podcasts.

import { podcastsAPI } from './podcasts-api.js';
import { isPodcastTrack, isRealVideoTrack } from './utils.js';

const TRANSCRIPT_MIME_PREFER = [
    'text/vtt',
    'application/vtt',
    'application/srt',
    'text/srt',
    'application/x-subrip',
];

export function srtToVtt(srt) {
    const body = String(srt || '')
        .replace(/^\uFEFF/, '')
        .replace(/\r+/g, '')
        .replace(/(\d{2}:\d{2}:\d{2}),(\d{3})/g, '$1.$2');
    return body.trimStart().startsWith('WEBVTT') ? body : `WEBVTT\n\n${body}`;
}

export function heightToQualityLabel(height, bandwidth = 0) {
    if (height >= 1080) return '1080p';
    if (height >= 720) return '720p';
    if (height >= 480) return '480p';
    if (height >= 360) return '360p';
    if (height >= 180) return '180p';
    if (bandwidth > 0) return `${Math.round(bandwidth / 1000)}k`;
    return 'Source';
}

function normalizeTranscriptEntry(entry) {
    if (!entry) return null;
    if (typeof entry === 'string') {
        return { url: entry, type: '', language: '', label: 'Subtitles' };
    }
    const url = entry.url || entry.transcriptUrl || '';
    if (!url) return null;
    const language = entry.language || entry.lang || '';
    const type = entry.type || entry.mimeType || '';
    const label = entry.label || language || 'Subtitles';
    return { url, type, language, label };
}

export function collectTranscriptSources(track) {
    const sources = [];
    const seen = new Set();
    const push = (entry) => {
        const normalized = normalizeTranscriptEntry(entry);
        if (!normalized || seen.has(normalized.url)) return;
        seen.add(normalized.url);
        sources.push(normalized);
    };

    if (Array.isArray(track?.transcripts)) {
        track.transcripts.forEach(push);
    }
    if (track?.transcriptUrl) push(track.transcriptUrl);
    if (track?.podcastEpisode) {
        if (Array.isArray(track.podcastEpisode.transcripts)) {
            track.podcastEpisode.transcripts.forEach(push);
        }
        if (track.podcastEpisode.transcriptUrl) push(track.podcastEpisode.transcriptUrl);
    }

    sources.sort((a, b) => {
        const ai = TRANSCRIPT_MIME_PREFER.indexOf(String(a.type || '').toLowerCase());
        const bi = TRANSCRIPT_MIME_PREFER.indexOf(String(b.type || '').toLowerCase());
        return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
    });
    return sources;
}

async function resolveTranscriptSources(track) {
    let sources = collectTranscriptSources(track);
    if (sources.length || !isPodcastTrack(track)) return sources;

    const rawId = String(track.id || '').replace(/^podcast_/, '');
    if (!rawId) return sources;
    try {
        const episode = await podcastsAPI.getEpisodeById(rawId);
        if (!episode) return sources;
        track.transcriptUrl = episode.transcriptUrl || track.transcriptUrl;
        track.transcripts = episode.transcripts || track.transcripts;
        if (track.podcastEpisode) {
            track.podcastEpisode.transcriptUrl = episode.transcriptUrl;
            track.podcastEpisode.transcripts = episode.transcripts;
        }
        sources = collectTranscriptSources(track);
    } catch (e) {
        console.warn('Failed to fetch podcast episode transcripts', e);
    }
    return sources;
}

async function fetchAsVttObjectUrl(source) {
    const response = await fetch(source.url);
    if (!response.ok) throw new Error(`Transcript fetch failed: ${response.status}`);
    const rawType = (source.type || response.headers.get('content-type') || '').toLowerCase();
    const text = await response.text();

    if (rawType.includes('html') || /^\s*</.test(text)) {
        throw new Error('HTML transcripts not supported');
    }
    if (rawType.includes('json') || text.trimStart().startsWith('{') || text.trimStart().startsWith('[')) {
        throw new Error('JSON transcripts not supported');
    }

    const isVtt =
        rawType.includes('vtt') ||
        text.trimStart().startsWith('WEBVTT') ||
        /\.vtt(\?|#|$)/i.test(source.url);
    const vtt = isVtt ? (text.trimStart().startsWith('WEBVTT') ? text : `WEBVTT\n\n${text}`) : srtToVtt(text);
    return URL.createObjectURL(new Blob([vtt], { type: 'text/vtt' }));
}

export class VideoControlsController {
    constructor(player) {
        this.player = player;
        this._blobUrls = [];
        this._qualityMode = null; // 'hls' | 'shaka' | 'progressive' | null
        this._qualityOptions = [];
        this._selectedQualityId = 'auto';
        this._captionsReady = false;
        this._onDocumentClick = (e) => this._closeMenusIfOutside(e);
    }

    get video() {
        return this.player.video;
    }

    clearExternalSubtitles() {
        const video = this.video;
        if (!video) return;
        video.querySelectorAll('track[data-monochrome-sub]').forEach((el) => el.remove());
        this._blobUrls.forEach((url) => URL.revokeObjectURL(url));
        this._blobUrls = [];
        this._captionsReady = false;
        this._setCaptionsButtonVisible(false);
        const menu = document.getElementById('fs-captions-menu');
        if (menu) {
            menu.style.display = 'none';
            menu.innerHTML = '';
        }
    }

    async setupForTrack(track) {
        this.clearExternalSubtitles();
        this.resetQualityUi();

        if (!isRealVideoTrack(track) || !this.video) return;

        await this.attachSubtitles(track);
        await this.setupQualityForCurrentPlayback(track);
        this._wireButtons();
    }

    async attachSubtitles(track) {
        const video = this.video;
        const sources = await resolveTranscriptSources(track);
        let attached = 0;

        for (const source of sources) {
            try {
                const type = String(source.type || '').toLowerCase();
                if (type.includes('html') || type.includes('json')) continue;
                const objectUrl = await fetchAsVttObjectUrl(source);
                this._blobUrls.push(objectUrl);
                const trackEl = document.createElement('track');
                trackEl.kind = 'subtitles';
                trackEl.label = source.label || source.language || `Subtitles ${attached + 1}`;
                trackEl.srclang = source.language || 'und';
                trackEl.src = objectUrl;
                trackEl.dataset.monochromeSub = '1';
                if (attached === 0) trackEl.default = true;
                video.appendChild(trackEl);
                attached += 1;
            } catch (e) {
                console.warn('Skipping transcript source', source.url, e);
            }
        }

        // Wait a tick so browser registers textTracks from <track> tags.
        await new Promise((r) => setTimeout(r, 0));

        const textTracks = Array.from(video.textTracks || []).filter(
            (t) => t.kind === 'subtitles' || t.kind === 'captions'
        );
        if (textTracks.length === 0) {
            this._captionsReady = false;
            this._setCaptionsButtonVisible(false);
            return;
        }

        textTracks.forEach((t, i) => {
            t.mode = i === 0 ? 'showing' : 'disabled';
        });
        this._captionsReady = true;
        this._setCaptionsButtonVisible(true);
        this.renderCaptionsMenu();
    }

    getSubtitleOptions() {
        const video = this.video;
        if (!video) return [{ id: 'off', label: 'Off', active: true }];
        const tracks = Array.from(video.textTracks || []).filter(
            (t) => t.kind === 'subtitles' || t.kind === 'captions'
        );
        const options = [{ id: 'off', label: 'Off', active: tracks.every((t) => t.mode !== 'showing') }];
        tracks.forEach((t, i) => {
            options.push({
                id: String(i),
                label: t.label || t.language || `Track ${i + 1}`,
                active: t.mode === 'showing',
            });
        });
        return options;
    }

    setSubtitleTrack(id) {
        const video = this.video;
        if (!video) return;
        const tracks = Array.from(video.textTracks || []).filter(
            (t) => t.kind === 'subtitles' || t.kind === 'captions'
        );
        tracks.forEach((t, i) => {
            t.mode = id !== 'off' && String(i) === String(id) ? 'showing' : 'disabled';
        });
        this.renderCaptionsMenu();
    }

    renderCaptionsMenu() {
        const menu = document.getElementById('fs-captions-menu');
        const btn = document.getElementById('fs-captions-btn');
        if (!menu || !btn) return;
        const options = this.getSubtitleOptions();
        menu.innerHTML = options
            .map(
                (opt) =>
                    `<button class="fs-quality-option ${opt.active ? 'active' : ''}" data-sub-id="${opt.id}">${opt.label}</button>`
            )
            .join('');
        menu.querySelectorAll('[data-sub-id]').forEach((el) => {
            el.onclick = (e) => {
                e.stopPropagation();
                this.setSubtitleTrack(el.dataset.subId);
                menu.style.display = 'none';
            };
        });
        btn.classList.toggle('active', options.some((o) => o.id !== 'off' && o.active));
    }

    resetQualityUi() {
        this._qualityMode = null;
        this._qualityOptions = [];
        this._selectedQualityId = 'auto';
        const qualityBtn = document.getElementById('fs-quality-btn');
        const qualityMenu = document.getElementById('fs-quality-menu');
        if (qualityMenu) {
            qualityMenu.style.display = 'none';
            qualityMenu.innerHTML = '';
        }
        if (qualityBtn) {
            qualityBtn.style.display = 'none';
            const labelSpan = qualityBtn.querySelector('.fs-quality-label');
            if (labelSpan) labelSpan.textContent = 'Auto';
        }
    }

    async setupQualityForCurrentPlayback(track) {
        if (this.player.hls?.levels?.length) {
            await this.setupHlsQuality();
            return;
        }
        if (this.player.shakaInitialized && this.player.shakaPlayer) {
            this.setupShakaQuality();
            return;
        }
        // Progressive MP4 / single-URL video podcast
        if (isRealVideoTrack(track)) {
            this.setupProgressiveQuality();
        }
    }

    async setupHlsQuality() {
        if (!this.player.hls?.levels?.length) return;
        const levels = this.player.hls.levels;
        this._qualityMode = 'hls';
        this._qualityOptions = [
            { id: 'auto', label: 'Auto' },
            ...levels.map((level, i) => ({
                id: String(i),
                label: heightToQualityLabel(level.height || 0, level.bitrate || 0),
            })),
        ];
        this._selectedQualityId = this.player.hls.currentLevel === -1 ? 'auto' : String(this.player.hls.currentLevel);
        this._setQualityButtonVisible(true);
        this.renderQualityMenu();

        const Hls = (await import('hls.js')).default;
        this.player.hls.on(Hls.Events.LEVEL_SWITCHED, () => {
            if (this.player.hls.currentLevel >= 0) {
                this._selectedQualityId = String(this.player.hls.currentLevel);
            }
            this.renderQualityMenu();
        });
    }

    setupShakaQuality() {
        const shaka = this.player.shakaPlayer;
        if (!shaka) return;
        const variants = (shaka.getVariantTracks?.() || [])
            .filter((v) => v.height || v.bandwidth)
            .sort((a, b) => (b.height || 0) - (a.height || 0) || (b.bandwidth || 0) - (a.bandwidth || 0));

        const byHeight = new Map();
        for (const v of variants) {
            const key = v.height || v.bandwidth || v.id;
            if (!byHeight.has(key)) byHeight.set(key, v);
        }
        const unique = [...byHeight.values()];
        if (unique.length === 0) {
            this.setupProgressiveQuality();
            return;
        }

        this._qualityMode = 'shaka';
        this._qualityOptions = [
            { id: 'auto', label: 'Auto' },
            ...unique.map((v) => ({
                id: String(v.id),
                label: heightToQualityLabel(v.height || 0, v.bandwidth || 0),
                trackId: v.id,
            })),
        ];
        const active = unique.find((v) => v.active);
        this._selectedQualityId = active ? String(active.id) : 'auto';
        this._setQualityButtonVisible(true);
        this.renderQualityMenu();
    }

    setupProgressiveQuality() {
        const video = this.video;
        const apply = () => {
            const label = heightToQualityLabel(video?.videoHeight || 0);
            this._qualityMode = 'progressive';
            this._qualityOptions = [{ id: 'source', label }];
            this._selectedQualityId = 'source';
            this._setQualityButtonVisible(true);
            this.renderQualityMenu();
        };
        if (video && video.videoHeight > 0) apply();
        else if (video) {
            video.addEventListener('loadedmetadata', apply, { once: true });
            this._qualityMode = 'progressive';
            this._qualityOptions = [{ id: 'source', label: 'Source' }];
            this._selectedQualityId = 'source';
            this._setQualityButtonVisible(true);
            this.renderQualityMenu();
        }
    }

    getQualityOptions() {
        return this._qualityOptions.map((opt) => ({
            ...opt,
            active: String(opt.id) === String(this._selectedQualityId),
        }));
    }

    setQuality(id) {
        this._selectedQualityId = String(id);
        if (this._qualityMode === 'hls' && this.player.hls) {
            this.player.hls.currentLevel = id === 'auto' ? -1 : parseInt(id, 10);
        } else if (this._qualityMode === 'shaka' && this.player.shakaPlayer) {
            if (id === 'auto') {
                this.player.shakaPlayer.configure({ abr: { enabled: true } });
            } else {
                const variants = this.player.shakaPlayer.getVariantTracks?.() || [];
                const match = variants.find((v) => String(v.id) === String(id));
                if (match) {
                    this.player.shakaPlayer.configure({ abr: { enabled: false } });
                    this.player.shakaPlayer.selectVariantTrack(match, /* clearBuffer= */ true);
                }
            }
        }
        this.renderQualityMenu();
    }

    renderQualityMenu() {
        const menu = document.getElementById('fs-quality-menu');
        const btn = document.getElementById('fs-quality-btn');
        if (!menu || !btn) return;
        const options = this.getQualityOptions();
        menu.innerHTML = options
            .map(
                (opt) =>
                    `<button class="fs-quality-option ${opt.active ? 'active' : ''}" data-quality-id="${opt.id}">${opt.label}</button>`
            )
            .join('');
        menu.querySelectorAll('[data-quality-id]').forEach((el) => {
            el.onclick = (e) => {
                e.stopPropagation();
                this.setQuality(el.dataset.qualityId);
                menu.style.display = 'none';
            };
        });
        const labelSpan = btn.querySelector('.fs-quality-label');
        const active = options.find((o) => o.active);
        if (labelSpan) labelSpan.textContent = active?.label || 'Auto';
    }

    toggleCaptionsMenu() {
        if (!this._captionsReady) return;
        const menu = document.getElementById('fs-captions-menu');
        const qualityMenu = document.getElementById('fs-quality-menu');
        if (qualityMenu) qualityMenu.style.display = 'none';
        if (!menu) return;
        this.renderCaptionsMenu();
        menu.style.display = menu.style.display === 'block' ? 'none' : 'block';
    }

    toggleQualityMenu() {
        if (!this._qualityOptions.length) return;
        const menu = document.getElementById('fs-quality-menu');
        const captionsMenu = document.getElementById('fs-captions-menu');
        if (captionsMenu) captionsMenu.style.display = 'none';
        if (!menu) return;
        this.renderQualityMenu();
        menu.style.display = menu.style.display === 'block' ? 'none' : 'block';
    }

    _setCaptionsButtonVisible(visible) {
        const btn = document.getElementById('fs-captions-btn');
        if (btn) btn.style.display = visible ? 'flex' : 'none';
    }

    _setQualityButtonVisible(visible) {
        const btn = document.getElementById('fs-quality-btn');
        if (btn) btn.style.display = visible ? 'flex' : 'none';
    }

    _wireButtons() {
        const captionsBtn = document.getElementById('fs-captions-btn');
        const qualityBtn = document.getElementById('fs-quality-btn');
        if (captionsBtn) {
            captionsBtn.onclick = (e) => {
                e.stopPropagation();
                this.toggleCaptionsMenu();
            };
        }
        if (qualityBtn) {
            qualityBtn.onclick = (e) => {
                e.stopPropagation();
                this.toggleQualityMenu();
            };
        }
        document.removeEventListener('click', this._onDocumentClick);
        document.addEventListener('click', this._onDocumentClick);
    }

    _closeMenusIfOutside(e) {
        const captionsMenu = document.getElementById('fs-captions-menu');
        const qualityMenu = document.getElementById('fs-quality-menu');
        const captionsBtn = document.getElementById('fs-captions-btn');
        const qualityBtn = document.getElementById('fs-quality-btn');
        if (
            captionsMenu &&
            !captionsMenu.contains(e.target) &&
            e.target !== captionsBtn &&
            !captionsBtn?.contains(e.target)
        ) {
            captionsMenu.style.display = 'none';
        }
        if (
            qualityMenu &&
            !qualityMenu.contains(e.target) &&
            e.target !== qualityBtn &&
            !qualityBtn?.contains(e.target)
        ) {
            qualityMenu.style.display = 'none';
        }
    }
}
