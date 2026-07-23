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
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleEnabled = false
    @Published var errorMessage: String?

    let player = AVQueuePlayer()
    private let musicService: MusicService
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    private var pendingAutoplay = false

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    init(musicService: MusicService = .shared) {
        self.musicService = musicService
        // We advance the catalog queue ourselves. Leaving AVQueuePlayer on .advance
        // races removeAllItems/insert and can fire stale end notifications.
        player.actionAtItemEnd = .none
        restoreQueue()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
                let value = self.player.currentItem?.duration.seconds ?? 0
                let nextDuration = value.isFinite ? max(0, value) : (self.currentTrack?.duration ?? 0)
                // Avoid thrashing SwiftUI (AsyncImage / pill art) on every tick.
                if abs(self.elapsed - seconds) >= 0.25 { self.elapsed = seconds }
                if abs(self.duration - nextDuration) >= 0.25 { self.duration = nextDuration }
                self.updateNowPlaying()
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
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ track: Track, in context: [Track]? = nil) {
        let tracks = context ?? [track]
        queue = tracks
        currentIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        persistQueue()
        loadCurrent(autoplay: true)
    }

    func playPause() {
        if isPlaying { pause() } else if player.currentItem != nil { resume() } else { loadCurrent(autoplay: true) }
    }

    func pause() { player.pause(); isPlaying = false; updateNowPlaying() }

    func resume() {
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { errorMessage = error.localizedDescription }
        player.playImmediately(atRate: playbackRate); isPlaying = true; updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one { seek(to: 0); resume(); return }
        if shuffleEnabled, queue.count > 1 {
            var next = Int.random(in: queue.indices)
            while next == currentIndex { next = Int.random(in: queue.indices) }
            currentIndex = next
        } else if let index = currentIndex, index + 1 < queue.count { currentIndex = index + 1 }
        else if repeatMode == .all { currentIndex = 0 }
        else { pause(); return }
        persistQueue(); loadCurrent(autoplay: true)
    }

    func previous() {
        if elapsed > 4 { seek(to: 0); return }
        guard !queue.isEmpty else { return }
        if let index = currentIndex, index > 0 { currentIndex = index - 1 }
        else if repeatMode == .all { currentIndex = queue.count - 1 }
        else { seek(to: 0); return }
        persistQueue(); loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }

    func remove(at offsets: IndexSet) {
        guard let currentIndex else { queue.remove(atOffsets: offsets); persistQueue(); return }
        if offsets.contains(currentIndex) { next() }
        let removedBefore = offsets.filter { $0 < currentIndex }.count
        queue.remove(atOffsets: offsets)
        self.currentIndex = queue.isEmpty ? nil : min(max(0, currentIndex - removedBefore), queue.count - 1)
        persistQueue()
    }

    func move(from offsets: IndexSet, to destination: Int) { queue.move(fromOffsets: offsets, toOffset: destination); persistQueue() }

    func append(_ track: Track) { queue.append(track); persistQueue() }
    func playNext(_ track: Track) { queue.insert(track, at: min((currentIndex ?? -1) + 1, queue.count)); persistQueue() }

    func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began { isPlaying = false }
        else if let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) { resume() }
    }

    func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        pause()
    }

    private func loadCurrent(autoplay: Bool) {
        guard let track = currentTrack else { return }
        loadTask?.cancel()
        pendingAutoplay = false
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let stream = try await musicService.resolveStream(for: track, quality: PlaybackQuality.stored)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(url: stream.url)
                item.audioTimePitchAlgorithm = .timeDomain
                pendingAutoplay = autoplay
                itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        switch item.status {
                        case .readyToPlay:
                            self.isLoading = false
                            if self.pendingAutoplay {
                                self.pendingAutoplay = false
                                self.resume()
                            }
                            self.updateNowPlaying()
                        case .failed:
                            self.pendingAutoplay = false
                            self.player.pause()
                            self.isLoading = false
                            self.isPlaying = false
                            self.errorMessage = item.error?.localizedDescription ?? "This song could not be played."
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
                    if pendingAutoplay {
                        pendingAutoplay = false
                        resume()
                    }
                }
                LibraryRepository.shared.recordPlayback(track)
                ScrobblingCoordinator.shared.nowPlaying(track)
                Task { try? await DownloadManager.shared.prefetchArtwork(for: track) }
                Task { _ = try? await musicService.recommendations(for: track.playbackID) }
                updateNowPlaying()
            } catch {
                guard !Task.isCancelled else { return }
                pendingAutoplay = false
                isLoading = false; isPlaying = false; errorMessage = error.localizedDescription
            }
        }
    }

    private func itemDidFinish() {
        // Ignore end events that arrive while a replacement item is mid-load.
        guard !isLoading else { return }
        if let track = currentTrack { ScrobblingCoordinator.shared.completed(track, listened: max(elapsed, duration)) }
        next()
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

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var offlineTracks: [Track] = []
    private var tasks: [Int: Track] = [:]
    private lazy var session = URLSession(configuration: .background(withIdentifier: "tf.monochrome.downloads"), delegate: self, delegateQueue: nil)

    func download(_ track: Track) async {
        do {
            let stream = try await MusicService.shared.resolveStream(for: track, quality: PlaybackQuality.stored)
            let task = session.downloadTask(with: stream.url); tasks[task.taskIdentifier] = track; progress[track.id] = 0; task.resume()
        } catch { progress[track.id] = nil }
    }
    func cancel(_ track: Track) {
        guard let taskID = tasks.first(where: { $0.value.id == track.id })?.key else { return }
        session.getAllTasks { tasks in tasks.first(where: { $0.taskIdentifier == taskID })?.cancel() }
        tasks[taskID] = nil
        progress[track.id] = nil
    }
    func prefetchArtwork(for track: Track) async throws {
        guard let url = track.artworkURL else { return }
        if ArtworkImageCache.shared.image(for: url) != nil { return }
        let (data, _) = try await URLSession.shared.data(from: url)
        if let image = UIImage(data: data) { ArtworkImageCache.shared.insert(image, for: url) }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            guard let track = tasks.removeValue(forKey: downloadTask.taskIdentifier) else { return }
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(track.id.replacingOccurrences(of: ":", with: "_")).appendingPathExtension("audio")
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: location, to: target)
                offlineTracks.removeAll { $0.id == track.id }; offlineTracks.append(track); progress[track.id] = nil
            } catch { progress[track.id] = nil }
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in guard let track = tasks[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else { return }; progress[track.id] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) }
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
