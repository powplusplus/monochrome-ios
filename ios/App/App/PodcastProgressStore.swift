import Foundation

/// Per-episode resume positions (integer seconds). Mirrors web IndexedDB `podcast_progress`.
@MainActor
final class PodcastProgressStore: ObservableObject {
    static let shared = PodcastProgressStore()

    private let defaultsKey = "native.podcastProgress"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    struct Entry: Codable, Hashable {
        var position: Int
        var duration: Int
        var updatedAt: TimeInterval
        var title: String?
        var podcastTitle: String?
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private init() {
        load()
    }

    func progress(for episodeID: String) -> Entry? {
        entries[episodeID]
    }

    /// Resume start time, or 0 if none / finished / too early.
    func resumePosition(for episodeID: String, duration fallbackDuration: Double = 0) -> Double {
        guard let entry = entries[episodeID], entry.position >= 5 else { return 0 }
        let duration = entry.duration > 0 ? Double(entry.duration) : fallbackDuration
        if duration > 0, Double(entry.position) / duration >= 0.95 || duration - Double(entry.position) < 15 {
            clear(episodeID)
            return 0
        }
        return Double(entry.position)
    }

    func save(episodeID: String, position: Double, duration: Double, title: String? = nil, podcastTitle: String? = nil) {
        let pos = max(0, Int(position.rounded(.down)))
        let dur = max(0, Int(duration.rounded(.down)))
        if pos >= 5, dur > 0, Double(pos) / Double(dur) >= 0.95 || dur - pos < 15 {
            clear(episodeID)
            return
        }
        guard pos >= 5 else { return }
        entries[episodeID] = Entry(
            position: pos,
            duration: dur,
            updatedAt: Date().timeIntervalSince1970,
            title: title,
            podcastTitle: podcastTitle
        )
        persist()
    }

    func clear(_ episodeID: String) {
        guard entries.removeValue(forKey: episodeID) != nil else { return }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? decoder.decode([String: Entry].self, from: data) else {
            entries = [:]
            return
        }
        entries = decoded
    }

    private func persist() {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        objectWillChange.send()
    }
}
