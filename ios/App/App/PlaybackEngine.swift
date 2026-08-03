import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class PlaybackEngine: ObservableObject {
    static let shared = PlaybackEngine()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var playbackRate: Float = 1 { didSet { if isPlaying { player.rate = playbackRate }; updateNowPlaying() } }
    /// Keeps the music going once the queue runs out, using content-aware
    /// recommendations rather than more of the same artist.
    @Published var autoplayEnabled: Bool = UserDefaults.standard.bool(forKey: "native.autoplayEnabled") {
        didSet {
            UserDefaults.standard.set(autoplayEnabled, forKey: "native.autoplayEnabled")
            if autoplayEnabled { maybePrefetchContinuation() }
        }
    }
    /// Holds the display on while the app is in the foreground — for lyrics,
    /// the visualizer, or a phone propped up as a now-playing screen. The system
    /// clears the idle-timer override on every background transition, so this is
    /// re-applied from `warmForeground()`.
    @Published var keepAwakeEnabled: Bool = UserDefaults.standard.bool(forKey: "native.keepAwakeEnabled") {
        didSet {
            UserDefaults.standard.set(keepAwakeEnabled, forKey: "native.keepAwakeEnabled")
            applyIdleTimer()
        }
    }
    /// True while a recommendation batch is in flight, for the "finding more
    /// songs" affordance in the player UI.
    @Published private(set) var isFindingMore = false
    @Published var repeatMode: RepeatMode = .off { didSet { prefetchUpcoming() } }
    @Published var shuffleEnabled = false { didSet { prefetchUpcoming() } }
    @Published var errorMessage: String?
    @Published private(set) var currentStreamQuality: String?
    /// The track the engine has finished working on — set once its item is ready
    /// (or has definitively failed), not when the queue index moves. UI that must
    /// not run ahead of the audio (synced lyrics) keys off this rather than
    /// `currentTrack`, which flips several network hops earlier.
    @Published private(set) var loadedTrackID: String?
    /// `24/96` when the provider reports bit depth and sample rate.
    @Published private(set) var currentStreamQualityDetail: String?
    /// What the decoded audio itself turned out to be, once `AudioAnalyzer` has
    /// looked at it. Arrives a few seconds after playback starts, so the badge
    /// shows the provider's claim first and corrects itself.
    @Published private(set) var currentStreamAnalysis: AudioAnalysis?
    /// Active stream provider — drives the Lucida badge above the lossless indicator.
    @Published private(set) var currentStreamProvider: Provider?
    /// Loudness for playlist now-playing bars. Separate store so ~30 Hz meter
    /// ticks do not rebuild every `TrackRow` via `PlaybackEngine.objectWillChange`.
    let audioMeter = AudioMeterStore()

    let player = AVQueuePlayer()
    private let musicService: MusicService
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    private var pendingAutoplay = false
    private var fadeTask: Task<Void, Never>?
    /// Background audio keeps the process alive only while AVPlayer is producing
    /// audio. During a skip or a cold start we deliberately remove the old item
    /// before resolving the new stream, leaving a suspension window where the
    /// resolver would otherwise resume only after the app returns to foreground.
    private var backgroundLoadTask: UIBackgroundTaskIdentifier = .invalid
    private let fadeDuration: TimeInterval = 0.25
    private let levelMonitor = AudioLevelMonitor()
    private var meterAttachTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    /// Analyses stay for the session so replays and queue loops cost nothing.
    private var audioAnalysisCache: [String: AudioAnalysis] = [:]

    /// A stream that has already been resolved and whose asset header has been fetched.
    /// `AVURLAsset` is not `Sendable`, but this one is only ever touched on the main actor.
    private struct PreparedStream: @unchecked Sendable {
        let stream: StreamResponse
        let asset: AVURLAsset
    }

    private static func asset(for stream: StreamResponse) -> AVURLAsset {
        guard !stream.requestHeaders.isEmpty else { return AVURLAsset(url: stream.url) }
        return AVURLAsset(
            url: stream.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": stream.requestHeaders]
        )
    }

    private var prefetch: [String: (task: Task<PreparedStream, Error>, startedAt: Date)] = [:]
    /// Signed CDN URLs go stale; past this age we re-resolve instead of handing
    /// AVPlayer a dead URL.
    private let prefetchTTL: TimeInterval = 8 * 60
    /// On foreground, warms older than this are re-resolved: short enough that a
    /// signed URL is unlikely to have expired mid-flight, long enough that rapid
    /// background/foreground toggles don't re-resolve a still-fresh warm.
    private let foregroundStaleTTL: TimeInterval = 90
    private let prefetchDepth = 2
    /// Seconds of audio to keep buffered ahead of the playhead. Caps progressive
    /// download to a sliding chunk window so a track starts on its first chunk and
    /// the rest streams in behind the playhead, rather than AVPlayer greedily
    /// pulling the whole file up front once bandwidth allows.
    private let forwardBufferSeconds: TimeInterval = 30
    /// Providers whose stream URL already failed AVPlayer for the current track.
    /// Cleared when playback moves to a different track. Lets Amazon "success"
    /// that AVPlayer rejects fall through to Lucida automatically.
    private var skippedProviders: Set<Provider> = []
    private var providerFailureCounts: [Provider: Int] = [:]
    private var recoveryQuality: PlaybackQuality?
    private var lastNowPlayingElapsed: Double = -1
    private var pendingPodcastSeek: Double?
    private var lastPodcastProgressSave: Date = .distantPast
    private var lastPodcastProgressPosition: Int = -1

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// The transport position sampled on demand rather than read from the 4 Hz
    /// republished `elapsed`. Anything that drives a per-frame animation from the
    /// clock — the instrumental dots in the lyrics pane — steps visibly on 250 ms
    /// values; asking the player directly costs nothing and is exact after a seek.
    /// Falls back to `elapsed` while a load is in flight, when the player's time
    /// still belongs to the item being torn down.
    var preciseElapsed: Double {
        guard !isLoading else { return elapsed }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : elapsed
    }

    init(musicService: MusicService = .shared) {
        self.musicService = musicService
        // We advance the catalog queue ourselves. Leaving AVQueuePlayer on .advance
        // races removeAllItems/insert and can fire stale end notifications.
        player.actionAtItemEnd = .none
        // Stream in chunks: begin playback as soon as the first chunk is buffered
        // and let AVPlayer range-request the rest behind the playhead, instead of
        // stalling until a large lead (or the whole file) has landed.
        player.automaticallyWaitsToMinimizeStalling = true
        restoreQueue()
        configureRemoteCommands()
        applyIdleTimer()
        levelMonitor.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                // Ignore tap leftovers after pause / while a new item is loading.
                guard self.isPlaying, !self.isLoading else { return }
                self.audioMeter.setLevel(level)
            }
        }
        // Ticks at 4 Hz so synced lyrics land on the beat instead of up to half
        // a second late. The published values and the now-playing centre are
        // still throttled below so the faster clock costs nothing downstream.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                // A load in flight owns `elapsed`/`duration`; trailing ticks from the
                // item being torn down would otherwise repaint the scrubber with the
                // previous track's position.
                guard !self.isLoading else { return }
                let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
                let value = self.player.currentItem?.duration.seconds ?? 0
                let nextDuration = value.isFinite ? max(0, value) : (self.currentTrack?.duration ?? 0)
                // Avoid thrashing SwiftUI (AsyncImage / pill art) on every tick.
                if abs(self.elapsed - seconds) >= 0.2 { self.elapsed = seconds }
                if abs(self.duration - nextDuration) >= 0.25 { self.duration = nextDuration }
                // Cross-process call — once a second is plenty for lock screen.
                if abs(seconds - self.lastNowPlayingElapsed) >= 0.9 {
                    self.lastNowPlayingElapsed = seconds
                    self.updateNowPlaying()
                }
                self.savePodcastProgressIfNeeded(force: false)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let finished = notification.object as? AVPlayerItem,
                      finished === self.player.currentItem else { return }
                self.itemDidFinish()
            }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      !self.isLoading,
                      let failed = notification.object as? AVPlayerItem,
                      failed === self.player.currentItem,
                      let provider = self.currentStreamProvider,
                      [.rythm, .amazon, .qobuz, .deezer].contains(provider) else { return }
                self.recoverPlaybackFailure(provider: provider, autoplay: true)
            }
        }
        stalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      !self.isLoading,
                      let stalled = notification.object as? AVPlayerItem,
                      stalled === self.player.currentItem,
                      let provider = self.currentStreamProvider,
                      [.rythm, .amazon, .qobuz, .deezer].contains(provider) else { return }
                let position = self.player.currentTime().seconds
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, stalled === self.player.currentItem,
                      self.isPlaying,
                      abs(self.player.currentTime().seconds - position) < 0.25,
                      self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                self.recoverPlaybackFailure(provider: provider, autoplay: true)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
    }

    func play(_ track: Track, in context: [Track]? = nil) {
        savePodcastProgressIfNeeded(force: true)
        resetPlaybackRecovery()
        let tracks = context ?? [track]
        queue = tracks
        currentIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        persistQueue()
        loadCurrent(autoplay: true)
    }

    func playPause() {
        // A resolve is already in flight. Cold provider instances take several
        // seconds, during which isPlaying is false and currentItem is nil — so
        // this used to fall through to loadCurrent, which cancels the in-flight
        // loadTask and restarts resolution from scratch. Spamming the button
        // reset the resolve on every tap, so the track never finished loading
        // until the user stopped tapping (or backgrounded and reopened the app).
        // Leave the running resolve alone; it already autoplays when ready.
        guard !isLoading else { return }
        if isPlaying { pause() } else if player.currentItem != nil { resume() } else { loadCurrent(autoplay: true) }
    }

    func pause() {
        isPlaying = false
        endBackgroundLoad()
        audioMeter.reset()
        updateNowPlaying()
        savePodcastProgressIfNeeded(force: true)
        fadeTask?.cancel()
        let startVolume = player.volume
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fade(from: startVolume, to: 0, duration: self.fadeDuration)
            guard !Task.isCancelled else { return }
            self.player.pause()
            self.player.volume = startVolume
        }
    }

    func resume() {
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { errorMessage = error.localizedDescription }
        fadeTask?.cancel()
        let targetVolume = player.volume > 0 ? player.volume : 1
        player.volume = 0
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
        updateNowPlaying()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fade(from: 0, to: targetVolume, duration: self.fadeDuration)
        }
    }

    private func fade(from startVolume: Float, to endVolume: Float, duration: TimeInterval) async {
        let steps = 10
        let stepDuration = duration / Double(steps)
        for step in 1...steps {
            if Task.isCancelled { return }
            let progress = Float(step) / Float(steps)
            player.volume = startVolume + (endVolume - startVolume) * progress
            try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
        }
    }

    func next() {
        savePodcastProgressIfNeeded(force: true)
        resetPlaybackRecovery()
        guard !queue.isEmpty else { return }
        if repeatMode == .one { seek(to: 0); resume(); return }

        // Skipping past a track that autoplay chose is the strongest negative
        // signal available, so tell the recommender before the index moves.
        reportOutcomeForCurrentTrack(skipped: true)

        if shuffleEnabled, queue.count > 1 {
            var next = Int.random(in: queue.indices)
            while next == currentIndex { next = Int.random(in: queue.indices) }
            currentIndex = next
        } else if let index = currentIndex, index + 1 < queue.count { currentIndex = index + 1 }
        else if repeatMode == .all { currentIndex = 0 }
        else if autoplayEnabled {
            // Queue is exhausted: fetch more rather than silently stopping.
            beginBackgroundLoad()
            Task { await self.extendQueue(advanceAfterwards: true) }
            return
        } else { pause(); return }
        persistQueue(); loadCurrent(autoplay: true)
        maybePrefetchContinuation()
    }

    func previous() {
        if elapsed > 4 {
            seek(to: 0)
            if let track = currentTrack, track.isPodcast {
                PodcastProgressStore.shared.clear(track.id)
            }
            return
        }
        savePodcastProgressIfNeeded(force: true)
        resetPlaybackRecovery()
        guard !queue.isEmpty else { return }
        if let index = currentIndex, index > 0 { currentIndex = index - 1 }
        else if repeatMode == .all { currentIndex = queue.count - 1 }
        else { seek(to: 0); return }
        persistQueue(); loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = max(0, seconds)
        savePodcastProgressIfNeeded(force: true)
    }

    func remove(at offsets: IndexSet) {
        guard let currentIndex else { queue.remove(atOffsets: offsets); persistQueue(); return }
        if offsets.contains(currentIndex) { next() }
        let removedBefore = offsets.filter { $0 < currentIndex }.count
        queue.remove(atOffsets: offsets)
        self.currentIndex = queue.isEmpty ? nil : min(max(0, currentIndex - removedBefore), queue.count - 1)
        persistQueue()
    }

    func move(from offsets: IndexSet, to destination: Int) { queue.move(fromOffsets: offsets, toOffset: destination); persistQueue() }

    // MARK: - Autoplay

    /// How many tracks may remain ahead before we start topping the queue up.
    /// Prefetching here, rather than repairing once the last track ends, is what
    /// keeps autoplay gapless.
    private static let continuationPrefetchThreshold = 3
    private static let continuationBatchSize = 8

    private var continuationTask: Task<Void, Never>?

    private func maybePrefetchContinuation() {
        guard autoplayEnabled, repeatMode != .one, continuationTask == nil,
              let index = currentIndex else { return }
        guard queue.count - 1 - index <= Self.continuationPrefetchThreshold else { return }
        Task { await extendQueue(advanceAfterwards: false) }
    }

    /// Appends a batch of recommendations. Concurrent callers join the in-flight
    /// request instead of starting a second one, so a prefetch and an
    /// end-of-queue repair can never race.
    private func extendQueue(advanceAfterwards: Bool) async {
        if let existing = continuationTask {
            await existing.value
            if advanceAfterwards { advanceIntoAppendedTracks() }
            return
        }

        let seeds = continuationSeeds()
        guard !seeds.isEmpty else {
            if advanceAfterwards { pause() }
            return
        }

        isFindingMore = true
        let queueTail = Array(queue.suffix(from: min((currentIndex ?? 0) + 1, queue.count)))
        let exclude = Set(queue.map(\.id) + recentlyPlayedIDs)
        let batch = advanceAfterwards ? 5 : Self.continuationBatchSize

        let task = Task { [weak self] in
            let picks = await RecommendationEngine.shared.recommend(
                seeds: seeds, queueTail: queueTail, exclude: exclude, count: batch)
            guard let self else { return }
            await MainActor.run {
                let existing = Set(self.queue.map(\.id))
                let additions = picks.filter { !existing.contains($0.id) }.map { track -> Track in
                    var tagged = track
                    tagged.recSource = "autoplay"
                    return tagged
                }
                if !additions.isEmpty {
                    self.queue.append(contentsOf: additions)
                    self.persistQueue()
                }
            }
        }

        continuationTask = task
        await task.value
        continuationTask = nil
        isFindingMore = false

        if advanceAfterwards { advanceIntoAppendedTracks() }
    }

    private func advanceIntoAppendedTracks() {
        guard let index = currentIndex, index + 1 < queue.count else {
            pause()
            return
        }
        resetPlaybackRecovery()
        currentIndex = index + 1
        persistQueue()
        loadCurrent(autoplay: true)
    }

    /// Recent listening drives the recommendation; the current track alone is a
    /// thin seed and produces a much narrower batch.
    private func continuationSeeds() -> [Track] {
        guard let index = currentIndex else { return currentTrack.map { [$0] } ?? [] }
        let window = queue[max(0, index - 4)...index]
        return Array(window.reversed().prefix(3))
    }

    private var recentlyPlayedIDs: [String] = []

    private func reportOutcomeForCurrentTrack(skipped: Bool) {
        guard let track = currentTrack, !track.isPodcast else { return }
        let completion = duration > 0 ? min(1, elapsed / duration) : (skipped ? 0 : 1)

        recentlyPlayedIDs.append(track.id)
        if recentlyPlayedIDs.count > 100 { recentlyPlayedIDs.removeFirst(recentlyPlayedIDs.count - 100) }

        Task {
            if skipped {
                await RecommendationEngine.shared.recordSkip(track, completion: completion)
            } else {
                await RecommendationEngine.shared.recordFinish(track, completion: completion)
            }
        }
    }

    func append(_ track: Track) { queue.append(track); persistQueue(); prefetchUpcoming() }
    func playNext(_ track: Track) { queue.insert(track, at: min((currentIndex ?? -1) + 1, queue.count)); persistQueue(); prefetchUpcoming() }

    func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began { isPlaying = false; audioMeter.reset() }
        else if let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) { resume() }
    }

    func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        pause()
    }

    private func loadCurrent(autoplay: Bool, usePrefetch: Bool = true) {
        guard let track = currentTrack else {
            endBackgroundLoad()
            return
        }
        loadTask?.cancel()
        // Acquire this before stopping the outgoing item. Once that item is
        // removed there may be no playing audio to prevent iOS suspending us.
        // Keeping one lease across provider retries lets the replacement item
        // become ready and start even if the phone locks during resolution.
        beginBackgroundLoad()
        pendingAutoplay = false
        isLoading = true
        loadedTrackID = nil
        errorMessage = nil
        currentStreamQuality = nil
        currentStreamQualityDetail = nil
        currentStreamProvider = nil
        analysisTask?.cancel()
        currentStreamAnalysis = nil
        pendingPodcastSeek = track.isPodcast
            ? PodcastProgressStore.shared.resumePosition(for: track.id, duration: track.duration)
            : nil
        lastPodcastProgressPosition = -1
        // Retire the outgoing item now. Resolving a stream is several network hops,
        // and leaving the previous item playing across them left the scrubber running
        // and the synced lyrics scrolling against audio the rest of the UI had already
        // replaced with the incoming track.
        fadeTask?.cancel()
        itemStatusObservation = nil
        detachMeter()
        player.pause()
        player.removeAllItems()
        player.volume = 1
        isPlaying = false
        audioMeter.reset()
        elapsed = 0
        duration = track.duration
        lastNowPlayingElapsed = -1
        updateNowPlaying()
        let warm = usePrefetch ? takePrefetch(for: track) : nil
        let skipProviders = skippedProviders
        let requestedQuality = recoveryQuality ?? PlaybackQuality.stored
        loadTask = Task {
            do {
                let stream: StreamResponse
                let asset: AVURLAsset
                var wasPrefetched = false
                var fromLocalFile = false
                if skipProviders.isEmpty, let local = DownloadManager.shared.localPlayURL(for: track) {
                    let offline = DownloadManager.shared.offlineEntry(for: track)
                    // Prefer recorded offline / catalog / enclosure format — never the
                    // download-quality preference (that lied "Lossless" for MP3 podcasts).
                    let honestQuality = offline?.offlineQuality
                        ?? track.offlineQuality
                        ?? track.audioQuality
                        ?? (track.isPodcast
                            ? PlaybackQuality.enclosureToken(mimeType: track.enclosureType, url: track.streamURL ?? local)
                            : nil)
                        ?? track.catalogQuality?.rawValue
                        ?? "UNKNOWN"
                    stream = StreamResponse(
                        url: local,
                        provider: offline?.offlineProvider ?? track.offlineProvider ?? .tidal,
                        quality: honestQuality,
                        replayGain: nil,
                        peak: nil,
                        isPreview: false,
                        mediaDuration: track.duration > 0 ? track.duration : nil,
                        qualityDetail: offline?.offlineQualityDetail ?? track.offlineQualityDetail
                    )
                    asset = AVURLAsset(url: local)
                    fromLocalFile = true
                } else if skipProviders.isEmpty, let warm, let prepared = try? await warm.value {
                    stream = prepared.stream
                    asset = prepared.asset
                    wasPrefetched = true
                } else {
                    stream = try await musicService.resolveStream(
                        for: track,
                        quality: requestedQuality,
                        skipping: skipProviders
                    )
                    asset = Self.asset(for: stream)
                }
                guard !Task.isCancelled else { return }
                currentStreamQuality = stream.quality
                currentStreamQualityDetail = stream.qualityDetail
                currentStreamProvider = stream.provider
                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .timeDomain
                // Local files are already on disk — a 30s look-ahead made Downloaded
                // tracks feel like a network start. Remote keeps the sliding chunk cap.
                item.preferredForwardBufferDuration = fromLocalFile ? 0 : forwardBufferSeconds
                pendingAutoplay = autoplay
                let failedProvider = stream.provider
                itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        switch item.status {
                        case .readyToPlay:
                            self.isLoading = false
                            self.loadedTrackID = track.id
                            self.attachMeter(to: item)
                            self.startAudioAnalysis(for: track, stream: stream)
                            self.applyPendingPodcastSeekIfNeeded()
                            if self.pendingAutoplay {
                                self.pendingAutoplay = false
                                self.resume()
                            }
                            self.endBackgroundLoad()
                            self.updateNowPlaying()
                        case .failed:
                            self.pendingAutoplay = false
                            self.player.pause()
                            if wasPrefetched {
                                // Warmed URL went stale. Re-resolve once before blaming the track.
                                self.loadCurrent(autoplay: autoplay, usePrefetch: false)
                                return
                            }
                            if !fromLocalFile,
                               [.rythm, .amazon, .qobuz, .deezer].contains(failedProvider) {
                                self.recoverPlaybackFailure(provider: failedProvider, autoplay: autoplay)
                                return
                            }
                            self.isLoading = false
                            self.loadedTrackID = track.id
                            self.isPlaying = false
                            self.errorMessage = item.error?.localizedDescription ?? "This song could not be played."
                            self.endBackgroundLoad()
                        case .unknown:
                            break
                        @unknown default:
                            break
                        }
                    }
                }
                player.removeAllItems(); player.insert(item, after: nil)
                elapsed = 0
                duration = stream.mediaDuration ?? track.duration
                if stream.isPreview {
                    let previewSeconds = Int((stream.mediaDuration ?? 30).rounded())
                    errorMessage = "Preview only (\(previewSeconds)s). Full track needs a TIDAL subscription."
                }
                // Autoplay waits for `.readyToPlay` so AVPlayer is not raced.
                if item.status == .readyToPlay {
                    isLoading = false
                    loadedTrackID = track.id
                    attachMeter(to: item)
                    applyPendingPodcastSeekIfNeeded()
                    if pendingAutoplay {
                        pendingAutoplay = false
                        resume()
                    }
                    endBackgroundLoad()
                }
                LibraryRepository.shared.recordPlayback(track)
                if !track.isPodcast {
                    ScrobblingCoordinator.shared.nowPlaying(track)
                    Task { try? await DownloadManager.shared.prefetchArtwork(for: track) }
                    // Purely a cache warm for the related-tracks shelf. At default priority
                    // it fans out across the instance pool and competes with the audio
                    // download that the user is actually waiting on.
                    Task(priority: .background) { _ = try? await musicService.recommendations(for: track.playbackID) }
                } else {
                    Task { try? await DownloadManager.shared.prefetchArtwork(for: track) }
                }
                updateNowPlaying()
                prefetchUpcoming()
            } catch {
                guard !Task.isCancelled else { return }
                pendingAutoplay = false
                // resolveStream already retries the cold provider internally
                // (Amazon 30s→20s window, plus a fresh-JWT retry on 401/428) and
                // the Deezer leg now fails fast on an unreachable pool. A second
                // full re-resolve here just stacked another cold Amazon window in
                // front of the same failure — the "infinite loading" tail. Surface
                // the error now instead.
                skippedProviders = []
                loadedTrackID = track.id
                isLoading = false; isPlaying = false; errorMessage = error.localizedDescription
                endBackgroundLoad()
            }
        }
    }

    /// Requests the finite amount of execution time iOS provides for an audio
    /// transition. This is intentionally not a permanent background assertion:
    /// once AVPlayer starts, the `audio` background mode owns process lifetime.
    private func beginBackgroundLoad() {
        guard backgroundLoadTask == .invalid else { return }
        backgroundLoadTask = UIApplication.shared.beginBackgroundTask(withName: "Prepare next song") { [weak self] in
            Task { @MainActor in
                // Do not cancel the resolver. If the system suspends us at expiry,
                // it can still finish naturally on the next foreground activation.
                self?.endBackgroundLoad()
            }
        }
    }

    private func endBackgroundLoad() {
        guard backgroundLoadTask != .invalid else { return }
        let identifier = backgroundLoadTask
        backgroundLoadTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// The next `limit` tracks in play order, or none when the next pick is unpredictable
    /// (shuffle) or is the current track again (repeat one).
    private func upcomingTracks(limit: Int) -> [Track] {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return [] }
        guard !shuffleEnabled, repeatMode != .one else { return [] }
        var result: [Track] = []
        var index = currentIndex
        while result.count < limit {
            index += 1
            if index >= queue.count {
                guard repeatMode == .all else { break }
                index = 0
            }
            if index == currentIndex { break }
            result.append(queue[index])
        }
        return result
    }

    /// Resolving a stream is several network hops (Amazon Turnstile → Deezer fallback)
    /// and dominates skip latency, so warm the next couple of tracks while this one plays.
    private func prefetchUpcoming() {
        let targets = upcomingTracks(limit: prefetchDepth)
        var keep = Set(targets.map(\.id))
        if let id = currentTrack?.id { keep.insert(id) }
        for (id, entry) in prefetch where !keep.contains(id) {
            entry.task.cancel()
            prefetch[id] = nil
        }
        for track in targets { warm(track) }
    }

    /// Resolve `track` into a warmed, playable asset and hold it in the prefetch
    /// cache. No-op when a warm is already in flight or ready for that track.
    private func warm(_ track: Track) {
        guard prefetch[track.id] == nil else { return }
        let service = musicService
        let task = Task<PreparedStream, Error> {
            let stream = try await service.resolveStream(for: track, quality: PlaybackQuality.stored)
            try Task.checkCancellation()
            let asset = Self.asset(for: stream)
            // Header-only warm: fetch just enough (manifest / moov box) to confirm the
            // asset is playable so the first tap starts on bytes we already hold. Don't
            // load `.duration` here — for progressive files that can range-request deep
            // into the track, turning a warm into a near-full download. Playback then
            // streams the rest in chunks bounded by `forwardBufferSeconds`.
            _ = try? await asset.load(.isPlayable)
            return PreparedStream(stream: stream, asset: asset)
        }
        prefetch[track.id] = (task, Date())
        Task { try? await DownloadManager.shared.prefetchArtwork(for: track) }
    }

    /// Re-warm stream resolution every time the app is foregrounded. Backgrounding
    /// lets signed CDN URLs and the Amazon Turnstile JWT expire and can suspend the
    /// warm tasks mid-flight, so the first tap after a reopen otherwise pays a full
    /// cold resolve — the main source of "could not resolve stream" errors. Pay it
    /// ahead of the user instead: refresh auth/pool, drop warms old enough that the
    /// URL may be dead, then warm the current track (when stopped) and the queue.
    func warmForeground() {
        applyIdleTimer()
        savePodcastProgressIfNeeded(force: true)
        Task { await InstanceDirectory.shared.refreshIfStale() }
        AmazonTurnstileAuth.shared.prewarm()
        let now = Date()
        for (id, entry) in prefetch where now.timeIntervalSince(entry.startedAt) > foregroundStaleTTL {
            entry.task.cancel()
            prefetch[id] = nil
        }
        if let track = currentTrack, loadedTrackID != track.id, !isLoading { warm(track) }
        prefetchUpcoming()
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwakeEnabled
    }

    /// Installs a pass-through audio tap so playlist rows can bounce with loudness.
    /// Called once the item is `.readyToPlay` so audio tracks exist (HLS-safe).
    private func attachMeter(to item: AVPlayerItem) {
        meterAttachTask?.cancel()
        audioMeter.reset()
        let player = self.player
        meterAttachTask = Task { [levelMonitor] in
            await levelMonitor.attach(to: item) {
                player.currentItem === item
            }
        }
    }

    private func detachMeter() {
        meterAttachTask?.cancel()
        meterAttachTask = nil
        levelMonitor.detach()
        audioMeter.reset()
    }

    /// Reads the audio itself so the badge can stop repeating the container's
    /// claim: a FLAC transcoded from an MP3 and a CD rip resampled to 96 kHz both
    /// look lossless in every header we get. Runs once the item is ready, off the
    /// main actor, and only for streams whose claim is worth checking — a track
    /// already badged AAC has nothing to expose.
    private func startAudioAnalysis(for track: Track, stream: StreamResponse) {
        analysisTask?.cancel()
        analysisTask = nil
        guard PlaybackSourceSettings.audioAnalysisEnabled, !track.isPodcast else { return }
        // Keyed by provider and claimed tier as well as track: the same song from
        // Amazon HD and from a Deezer MP3 fallback are different files, and a
        // quality-preference change re-resolves to a different one again.
        let key = "\(track.id)|\(stream.provider.rawValue)|\(stream.quality)"
        if let cached = audioAnalysisCache[key] {
            currentStreamAnalysis = cached
            return
        }
        guard Self.deservesAudioAnalysis(stream) else { return }
        let url = stream.url
        let headers = stream.requestHeaders
        let trackID = track.id
        analysisTask = Task { [weak self] in
            // The analyzer pulls its own byte ranges. Let the player's opening
            // buffer fill first so a slow connection stalls the audio for nobody.
            if !url.isFileURL {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
            }
            let analysis = await AudioAnalyzer.analyze(url: url, headers: headers)
            guard let self, !Task.isCancelled, let analysis else { return }
            // Cheap bound: a listening session is nowhere near this many tracks,
            // and dropping the lot beats evicting in play order.
            if self.audioAnalysisCache.count >= 256 { self.audioAnalysisCache.removeAll() }
            self.audioAnalysisCache[key] = analysis
            guard self.loadedTrackID == trackID else { return }
            self.currentStreamAnalysis = analysis
        }
    }

    /// Only lossless-ish claims are worth the bandwidth: MP3/AAC/OPUS tokens are
    /// already honest, and adaptive manifests cannot be read frame-accurately.
    private static func deservesAudioAnalysis(_ stream: StreamResponse) -> Bool {
        guard !AudioAnalyzer.isAdaptiveManifest(stream.url) else { return false }
        guard let label = PlaybackQuality.badgeLabel(forToken: stream.quality) else {
            // Tier tokens (`LOSSLESS`, `HI_RES_LOSSLESS`, `HD`, …) and `UNKNOWN`
            // say nothing about the file — exactly the case worth measuring.
            return (PlaybackQuality(providerToken: stream.quality)?.rank ?? PlaybackQuality.lossless.rank)
                >= PlaybackQuality.lossless.rank
        }
        return ["FLAC", "WAV", "ALAC"].contains(label)
    }

    /// Hands back the warmed task for `track` (possibly still in flight) and stops tracking it.
    private func takePrefetch(for track: Track) -> Task<PreparedStream, Error>? {
        guard let entry = prefetch.removeValue(forKey: track.id) else { return nil }
        guard Date().timeIntervalSince(entry.startedAt) < prefetchTTL else {
            entry.task.cancel()
            return nil
        }
        return entry.task
    }

    private func resetPlaybackRecovery() {
        skippedProviders.removeAll()
        providerFailureCounts.removeAll()
        currentStreamProvider = nil
        recoveryQuality = nil
    }

    /// A provider can resolve successfully and still hand AVPlayer an expired,
    /// truncated, or non-seekable asset. Re-resolve automatically (fresh signed
    /// URL / file), downgrade Amazon from FLAC to its simpler AAC path when needed,
    /// then exclude an exhausted provider. The user never has to hammer Play.
    private func recoverPlaybackFailure(provider: Provider, autoplay: Bool) {
        guard currentTrack != nil else { return }
        // The Amazon resolver intentionally reuses decrypted local files. If
        // AVPlayer rejects one, remove that cache entry before resolving again;
        // otherwise every retry reopens the exact same corrupt file.
        if provider == .amazon,
           let asset = player.currentItem?.asset as? AVURLAsset,
           asset.url.isFileURL,
           asset.url.lastPathComponent.hasPrefix("monochrome-amz-") {
            try? FileManager.default.removeItem(at: asset.url)
        }
        let failures = (providerFailureCounts[provider] ?? 0) + 1
        providerFailureCounts[provider] = failures
        if provider == .amazon, failures == 2, (recoveryQuality ?? PlaybackQuality.stored).rank > PlaybackQuality.high.rank {
            // FLAC-in-fMP4 is the least forgiving AVFoundation path. Preserve the
            // first retry at the requested tier, then choose Amazon AAC before
            // abandoning a track whose catalog lookup itself was successful.
            recoveryQuality = .high
        } else if provider == .amazon, failures == 4 {
            recoveryQuality = .low
        }
        if (provider == .amazon && failures >= 6) || (provider != .amazon && failures >= 3) {
            skippedProviders.insert(provider)
        }
        pendingAutoplay = false
        itemStatusObservation = nil
        player.pause()
        isPlaying = false
        isLoading = true
        errorMessage = nil
        loadCurrent(autoplay: autoplay, usePrefetch: false)
    }

    private func itemDidFinish() {
        // Ignore end events that arrive while a replacement item is mid-load.
        guard !isLoading else { return }
        if let track = currentTrack {
            if track.isPodcast {
                PodcastProgressStore.shared.clear(track.id)
            } else {
                ScrobblingCoordinator.shared.completed(track, listened: max(elapsed, duration))
            }
        }
        reportOutcomeForCurrentTrack(skipped: false)
        advanceAfterCompletion()
    }

    /// End-of-track advance. Separate from `next()` so a natural finish is not
    /// misreported to the recommender as a skip.
    private func advanceAfterCompletion() {
        savePodcastProgressIfNeeded(force: true)
        resetPlaybackRecovery()
        guard !queue.isEmpty else { return }
        if repeatMode == .one { seek(to: 0); resume(); return }

        if shuffleEnabled, queue.count > 1 {
            var next = Int.random(in: queue.indices)
            while next == currentIndex { next = Int.random(in: queue.indices) }
            currentIndex = next
        } else if let index = currentIndex, index + 1 < queue.count { currentIndex = index + 1 }
        else if repeatMode == .all { currentIndex = 0 }
        else if autoplayEnabled {
            Task { await self.extendQueue(advanceAfterwards: true) }
            return
        } else { pause(); return }

        persistQueue()
        loadCurrent(autoplay: true)
        maybePrefetchContinuation()
    }

    private func applyPendingPodcastSeekIfNeeded() {
        guard let seekTo = pendingPodcastSeek, seekTo > 0 else {
            pendingPodcastSeek = nil
            return
        }
        pendingPodcastSeek = nil
        player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = seekTo
    }

    private func savePodcastProgressIfNeeded(force: Bool) {
        guard let track = currentTrack, track.isPodcast else { return }
        guard !isLoading else { return }
        let position = Int(elapsed.rounded(.down))
        let dur = duration > 0 ? duration : track.duration
        guard dur > 0 else { return }
        if position >= 5, Double(position) / dur >= 0.95 || dur - Double(position) < 15 {
            PodcastProgressStore.shared.clear(track.id)
            lastPodcastProgressPosition = -1
            return
        }
        guard position >= 5 else { return }
        if !force {
            if position == lastPodcastProgressPosition { return }
            if Date().timeIntervalSince(lastPodcastProgressSave) < 2 { return }
        }
        lastPodcastProgressSave = Date()
        lastPodcastProgressPosition = position
        PodcastProgressStore.shared.save(
            episodeID: track.id,
            position: Double(position),
            duration: dur,
            title: track.title,
            podcastTitle: track.album?.title ?? track.artist.name
        )
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playPause() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }; return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist.name,
                                  MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : track.duration,
                                  MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                                  MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0]
        if let title = track.album?.title { info[MPMediaItemPropertyAlbumTitle] = title }
        if let url = track.artworkURL {
            if let cached = ArtworkImageCache.shared.image(for: url) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cached.size) { _ in cached }
            } else {
                Task { [weak self] in
                    try? await DownloadManager.shared.prefetchArtwork(for: track)
                    guard let self, self.currentTrack?.id == track.id else { return }
                    self.updateNowPlaying()
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func persistQueue() {
        if let data = try? JSONEncoder().encode(queue) { UserDefaults.standard.set(data, forKey: "native.queue") }
        UserDefaults.standard.set(currentIndex, forKey: "native.queueIndex")
    }

    private func restoreQueue() {
        if let data = UserDefaults.standard.data(forKey: "native.queue"), let decoded = try? JSONDecoder().decode([Track].self, from: data) { queue = decoded }
        if !queue.isEmpty { currentIndex = min(UserDefaults.standard.integer(forKey: "native.queueIndex"), queue.count - 1) }
    }
}

/// Isolated loudness publisher so meter ticks do not invalidate the whole player UI tree.
@MainActor
final class AudioMeterStore: ObservableObject {
    @Published private(set) var level: Float = 0

    func setLevel(_ value: Float) {
        if abs(level - value) >= 0.015 || value < 0.04 {
            level = value
        }
    }

    func reset() {
        if level != 0 { level = 0 }
    }
}

/// Pass-through `MTAudioProcessingTap` that publishes a smoothed RMS loudness.
/// Runs on the audio render thread — keep `process` allocation-free and coalesce
/// UI callbacks onto the main queue.
private final class AudioLevelMonitor: @unchecked Sendable {
    var onLevel: ((Float) -> Void)?

    private let lock = NSLock()
    private var tap: MTAudioProcessingTap?
    private weak var attachedItem: AVPlayerItem?
    private var generation: UInt64 = 0
    private var isFloat32 = false
    private var smoothed: Float = 0
    private var pending: Float = 0
    private var emitScheduled = false

    func attach(to item: AVPlayerItem, stillCurrent: @MainActor @escaping () -> Bool) async {
        let gen: UInt64
        let previousItem: AVPlayerItem?
        lock.lock()
        generation &+= 1
        gen = generation
        previousItem = attachedItem
        attachedItem = nil
        tap = nil
        isFloat32 = false
        smoothed = 0
        pending = 0
        emitScheduled = false
        lock.unlock()

        await MainActor.run { previousItem?.audioMix = nil }

        let tracks = (try? await item.asset.load(.tracks)) ?? []
        guard !Task.isCancelled else { return }
        lock.lock()
        let generationMatches = generation == gen
        lock.unlock()
        guard generationMatches else { return }
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else { return }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { _ in },
            prepare: { tap, _, processingFormat in
                let monitor = Unmanaged<AudioLevelMonitor>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                let format = processingFormat.pointee
                let isFloat = format.mFormatID == kAudioFormatLinearPCM
                    && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                    && format.mBitsPerChannel == 32
                monitor.lock.lock()
                monitor.isFloat32 = isFloat
                monitor.lock.unlock()
            },
            unprepare: { tap in
                let monitor = Unmanaged<AudioLevelMonitor>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                monitor.lock.lock()
                monitor.isFloat32 = false
                monitor.lock.unlock()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
                )
                if status != noErr {
                    numberFramesOut.pointee = 0
                    return
                }
                let monitor = Unmanaged<AudioLevelMonitor>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                monitor.ingest(bufferList: bufferListInOut, frames: numberFramesOut.pointee)
            }
        )

        var tapRef: MTAudioProcessingTap?
        let createStatus = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tapRef
        )
        guard createStatus == noErr, let created = tapRef else { return }
        guard !Task.isCancelled else { return }
        lock.lock()
        let stillSameGeneration = generation == gen
        lock.unlock()
        guard stillSameGeneration else { return }

        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.audioTapProcessor = created
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]

        await MainActor.run {
            guard !Task.isCancelled, stillCurrent() else { return }
            guard item.status != .failed else { return }
            self.lock.lock()
            let ok = self.generation == gen
            if ok {
                self.tap = created
                self.attachedItem = item
                self.smoothed = 0
                self.pending = 0
            }
            self.lock.unlock()
            guard ok else { return }
            item.audioMix = mix
        }
    }

    func detach() {
        lock.lock()
        generation &+= 1
        let item = attachedItem
        attachedItem = nil
        tap = nil
        isFloat32 = false
        smoothed = 0
        pending = 0
        emitScheduled = false
        lock.unlock()

        let finish = {
            item?.audioMix = nil
            self.onLevel?(0)
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    private func ingest(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard frames > 0 else { return }
        lock.lock()
        let allowFloat = isFloat32
        lock.unlock()
        guard allowFloat else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var sumSquares: Float = 0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let byteSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(Int(frames) * channelCount, byteSamples)
            guard count > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                let sample = samples[i]
                sumSquares += sample * sample
            }
            sampleCount += count
        }

        guard sampleCount > 0 else { return }
        // Music RMS sits well below 1.0; gain brings typical peaks near full scale.
        let rms = sqrt(sumSquares / Float(sampleCount))
        let normalized = min(1, max(0, rms * 5.2))

        lock.lock()
        smoothed = smoothed * 0.62 + normalized * 0.38
        pending = smoothed
        let shouldSchedule = !emitScheduled
        if shouldSchedule { emitScheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let value = self.pending
            self.emitScheduled = false
            self.lock.unlock()
            self.onLevel?(value)
        }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    /// 0...1 while a track is downloading. Missing key = idle / finished.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var offlineTracks: [Track] = []

    private var trackByTaskID: [Int: Track] = [:]
    private var finishers: [Int: CheckedContinuation<URL, Error>] = [:]
    private var workTasks: [String: Task<Void, Never>] = [:]
    /// Metadata for in-flight downloads (not yet in `offlineTracks`).
    private var activeTracks: [String: Track] = [:]
    /// Bumped by `cancelAll` so an in-flight `downloadAll` stops instead of advancing.
    private var bulkGeneration = 0
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let catalogKey = "native.offlineTracks"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override init() {
        super.init()
        loadCatalog()
        pruneMissingFiles()
    }

    // MARK: - Paths

    private var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func safeFileName(for trackID: String) -> String {
        trackID.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    func fileURL(for track: Track) -> URL {
        playableFileURL(forID: track.id) ?? legacyAudioURL(forID: track.id)
    }

    /// Prefer a sniff-renamed playable file (`.flac`/`.m4a`/`.mp3`) over the legacy
    /// `.audio` stub — AVPlayer probes unknown extensions slowly or fails outright.
    private func playableFileURL(forID id: String) -> URL? {
        let base = downloadsDirectory.appendingPathComponent(safeFileName(for: id))
        for ext in ["flac", "m4a", "mp3", "mp4", "wav", "audio"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func legacyAudioURL(forID id: String) -> URL {
        downloadsDirectory
            .appendingPathComponent(safeFileName(for: id))
            .appendingPathExtension("audio")
    }

    func isDownloaded(_ track: Track) -> Bool {
        localPlayURL(for: track) != nil
    }

    /// Catalog row for an offline track (provider/quality written at download time).
    func offlineEntry(for track: Track) -> Track? {
        if let match = offlineTracks.first(where: { $0.id == track.id }) { return match }
        return offlineTracks.first(where: { $0.playbackID == track.playbackID })
    }

    /// Playable local file when present — prefer over network resolve.
    func localPlayURL(for track: Track) -> URL? {
        if let url = playableFileURL(forID: track.id) { return url }
        if let match = offlineEntry(for: track), match.id != track.id,
           let url = playableFileURL(forID: match.id) {
            return url
        }
        // Bare playbackID filename (older downloads without `tidal:` prefix).
        if track.id != track.playbackID, let url = playableFileURL(forID: track.playbackID) {
            return url
        }
        return nil
    }

    func isDownloading(_ track: Track) -> Bool {
        progress[track.id] != nil || workTasks[track.id] != nil
    }

    /// True while resolving stream URL before bytes flow (ring should spin, not fill).
    func isPreparing(_ track: Track) -> Bool {
        guard workTasks[track.id] != nil else { return false }
        guard let value = progress[track.id] else { return true }
        return value <= 0
    }

    /// Aggregate 0...1 for a playlist/mix collection.
    func collectionProgress(for tracks: [Track]) -> Double? {
        guard !tracks.isEmpty else { return nil }
        let anyActive = tracks.contains { progress[$0.id] != nil || workTasks[$0.id] != nil }
        guard anyActive else { return nil }
        let sum = tracks.reduce(0.0) { partial, track in
            if isDownloaded(track) { return partial + 1 }
            if let p = progress[track.id] { return partial + max(0, min(1, p)) }
            return partial
        }
        return sum / Double(tracks.count)
    }

    func allDownloaded(_ tracks: [Track]) -> Bool {
        !tracks.isEmpty && tracks.allSatisfy { isDownloaded($0) }
    }

    // MARK: - Public API

    func download(_ track: Track) async {
        if isDownloaded(track) {
            remember(track)
            return
        }
        if workTasks[track.id] != nil { return }

        activeTracks[track.id] = track
        setProgress(track.id, 0)
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.workTasks[track.id] = nil
                self.activeTracks[track.id] = nil
            }
            do {
                try Task.checkCancellation()
                let stream = try await MusicService.shared.resolveStream(
                    for: track,
                    quality: PlaybackQuality.downloadStored
                )
                try Task.checkCancellation()
                try await self.persist(stream.url, for: track)
                var saved = track
                saved.offlineProvider = stream.provider
                saved.offlineQuality = stream.quality
                saved.offlineQualityDetail = stream.qualityDetail
                self.remember(saved)
                self.setProgress(track.id, nil)
            } catch is CancellationError {
                self.setProgress(track.id, nil)
            } catch {
                self.setProgress(track.id, nil)
            }
        }
        workTasks[track.id] = work
        await work.value
    }

    func downloadAll(_ tracks: [Track]) async {
        let generation = bulkGeneration
        for track in tracks {
            guard generation == bulkGeneration else { return }
            if isDownloaded(track) {
                remember(track)
                continue
            }
            await download(track)
            guard generation == bulkGeneration else { return }
        }
    }

    func cancel(_ track: Track) {
        workTasks[track.id]?.cancel()
        workTasks[track.id] = nil
        activeTracks[track.id] = nil
        if let taskID = trackByTaskID.first(where: { $0.value.id == track.id })?.key {
            session.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskID })?.cancel()
            }
            trackByTaskID[taskID] = nil
            if let finisher = finishers.removeValue(forKey: taskID) {
                finisher.resume(throwing: CancellationError())
            }
        }
        setProgress(track.id, nil)
    }

    func cancelAll(in tracks: [Track]) {
        bulkGeneration += 1
        for track in tracks { cancel(track) }
    }

    func removeDownload(_ track: Track) {
        cancel(track)
        for ext in ["flac", "m4a", "mp3", "mp4", "wav", "audio"] {
            let url = downloadsDirectory
                .appendingPathComponent(safeFileName(for: track.id))
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: url)
        }
        offlineTracks.removeAll { $0.id == track.id || $0.playbackID == track.playbackID }
        persistCatalog()
    }

    func prefetchArtwork(for track: Track) async throws {
        guard let url = track.artworkURL else { return }
        if ArtworkImageCache.shared.image(for: url) != nil { return }
        let (data, _) = try await URLSession.shared.data(from: url)
        if let image = UIImage(data: data) { ArtworkImageCache.shared.insert(image, for: url) }
    }

    // MARK: - Persist bytes

    private func persist(_ source: URL, for track: Track) async throws {
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        // Drop any prior extension variants for this track id.
        for ext in ["flac", "m4a", "mp3", "mp4", "wav", "audio"] {
            let stale = downloadsDirectory
                .appendingPathComponent(safeFileName(for: track.id))
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: stale.path) {
                try? FileManager.default.removeItem(at: stale)
            }
        }

        let staged: URL
        if source.isFileURL {
            // Local clear file (e.g. Amazon CENC) — animate ring instead of jumping to done.
            setProgress(track.id, 0.15)
            try await Task.yield()
            staged = source
        } else {
            staged = try await downloadRemote(source, track: track)
            try Task.checkCancellation()
        }

        let sniffed = Self.sniffAudioExtension(at: staged)
        let fallbackExt = source.pathExtension.lowercased()
        let ext = sniffed
            ?? (["flac", "m4a", "mp3", "mp4", "wav"].contains(fallbackExt) ? fallbackExt : nil)
            ?? "audio"
        let target = downloadsDirectory
            .appendingPathComponent(safeFileName(for: track.id))
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        if source.isFileURL {
            try FileManager.default.copyItem(at: staged, to: target)
            for step in [0.45, 0.7, 0.9, 1.0] {
                try Task.checkCancellation()
                setProgress(track.id, step)
                try await Task.sleep(nanoseconds: 45_000_000)
            }
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
            setProgress(track.id, 1)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    /// Map file magic bytes → AVPlayer-friendly extension. `.audio` stubs force a
    /// slow/uncertain probe that made offline play feel like a network start.
    private static func sniffAudioExtension(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 12)
        guard data.count >= 4 else { return nil }
        if data.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return "flac" } // fLaC
        if data.starts(with: [0x49, 0x44, 0x33]) { return "mp3" } // ID3
        if data.count >= 2, data[0] == 0xFF, (data[1] & 0xE0) == 0xE0 { return "mp3" }
        if data.count >= 8 {
            let brand = data.subdata(in: 4..<8)
            if brand == Data("ftyp".utf8) { return "m4a" }
        }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "wav" } // RIFF
        return nil
    }

    private func downloadRemote(_ url: URL, track: Track) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: url)
            trackByTaskID[task.taskIdentifier] = track
            finishers[task.taskIdentifier] = cont
            setProgress(track.id, max(progress[track.id] ?? 0, 0.01))
            task.resume()
        }
    }

    /// Reassign dict so `@Published` always notifies (in-place subscript may not).
    private func setProgress(_ trackID: String, _ value: Double?) {
        var next = progress
        if let value {
            next[trackID] = value
        } else {
            next.removeValue(forKey: trackID)
        }
        progress = next
    }

    private func remember(_ track: Track) {
        offlineTracks.removeAll { $0.id == track.id }
        offlineTracks.insert(track, at: 0)
        persistCatalog()
    }

    private func loadCatalog() {
        guard let data = UserDefaults.standard.data(forKey: catalogKey),
              let decoded = try? decoder.decode([Track].self, from: data) else { return }
        offlineTracks = decoded
    }

    private func persistCatalog() {
        if let data = try? encoder.encode(offlineTracks) {
            UserDefaults.standard.set(data, forKey: catalogKey)
        }
    }

    private func pruneMissingFiles() {
        offlineTracks.removeAll { localPlayURL(for: $0) == nil }
        persistCatalog()
        // Migrate legacy `.audio` files to sniffed extensions so next play is instant.
        for track in offlineTracks {
            guard let url = playableFileURL(forID: track.id), url.pathExtension == "audio" else { continue }
            guard let ext = Self.sniffAudioExtension(at: url), ext != "audio" else { continue }
            let renamed = url.deletingPathExtension().appendingPathExtension(ext)
            try? FileManager.default.moveItem(at: url, to: renamed)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    /// Copy off the ephemeral download location *before* returning — Apple deletes
    /// that file as soon as this method returns.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in
                self.trackByTaskID[taskID] = nil
                if let cont = self.finishers.removeValue(forKey: taskID) {
                    cont.resume(throwing: URLError(.badServerResponse))
                }
            }
            return
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("monochrome-dl-\(taskID)-\(UUID().uuidString)")
            .appendingPathExtension("audio")
        do {
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.copyItem(at: location, to: staging)
            Task { @MainActor in
                self.trackByTaskID[taskID] = nil
                if let cont = self.finishers.removeValue(forKey: taskID) {
                    cont.resume(returning: staging)
                }
            }
        } catch {
            Task { @MainActor in
                self.trackByTaskID[taskID] = nil
                if let cont = self.finishers.removeValue(forKey: taskID) {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        let fraction: Double?
        if totalBytesExpectedToWrite > 0 {
            fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            fraction = nil
        }
        Task { @MainActor in
            guard let track = self.trackByTaskID[taskID] else { return }
            if let fraction {
                self.setProgress(track.id, max(0.01, min(0.99, fraction)))
            } else {
                // Unknown length — keep a soft pulse so the ring visibly advances.
                let current = self.progress[track.id] ?? 0.01
                self.setProgress(track.id, min(0.9, current + 0.02))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            self.trackByTaskID[taskID] = nil
            if let cont = self.finishers.removeValue(forKey: taskID) {
                cont.resume(throwing: error)
            }
        }
    }
}

@MainActor
final class ScrobblingCoordinator: ObservableObject {
    static let shared = ScrobblingCoordinator()
    @Published var enabledServices = Set<String>()
    func nowPlaying(_ track: Track) { Task.detached(priority: .utility) { /* Native service adapters fan out here. */ } }
    func completed(_ track: Track, listened: Double) {
        guard listened >= min(240, max(30, track.duration / 2)) else { return }
        Task.detached(priority: .utility) { /* Never delays queue advancement. */ }
    }
}

@MainActor
final class PartyService: ObservableObject {
    static let shared = PartyService()
    @Published var parties: [Party] = []
    @Published var connectedParty: Party?
    @Published var chat: [String] = []
    private var socket: URLSessionWebSocketTask?
    func connect(id: String) {
        guard let url = URL(string: "wss://api.monochrome.tf/parties/\(id)") else { return }
        socket = URLSession.shared.webSocketTask(with: url); socket?.resume(); receive()
    }
    func disconnect() { socket?.cancel(with: .goingAway, reason: nil); socket = nil; connectedParty = nil }
    func send(message: String) { socket?.send(.string(message)) { _ in } }
    private func receive() { socket?.receive { [weak self] result in if case .success(let message) = result, case .string(let value) = message { Task { @MainActor in self?.chat.append(value) } }; Task { @MainActor in self?.receive() } } }
}
