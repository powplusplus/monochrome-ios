import CryptoKit
import Foundation

/// PodcastIndex.org client — same endpoints/auth as web `js/podcasts-api.js`.
actor PodcastsService {
    static let shared = PodcastsService()

    private let base = "https://api.podcastindex.org/api/1.0"
    private let apiKey = "YU5HMSDYBQQVYDF6QN4P"
    private let apiSecret = "8hCvpjSL7T$S7^5ftnf5MhqQwYUYVjM^fmUL3Ld$"
    private let session: URLSession
    private var cache: [String: (date: Date, data: Data)] = [:]
    private let cacheTTL: TimeInterval = 5 * 60

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, max: Int = 20) async throws -> [Podcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let path = "/search/byterm?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)&max=\(max)&pretty"
        let root = try await fetchJSON(path: path)
        return feeds(from: root).compactMap(Self.mapPodcast)
    }

    func trending(max: Int = 24) async throws -> [Podcast] {
        let root = try await fetchJSON(path: "/podcasts/trending?max=\(max)&pretty")
        return feeds(from: root).compactMap(Self.mapPodcast)
    }

    func podcast(id: String) async throws -> Podcast? {
        let root = try await fetchJSON(path: "/podcasts/byfeedid?id=\(id)&pretty")
        guard let feed = root["feed"] as? [String: Any] else { return nil }
        return Self.mapPodcast(feed)
    }

    func episodes(podcastID: String, max: Int = 200) async throws -> [Track] {
        let root = try await fetchJSON(path: "/episodes/byfeedid?id=\(podcastID)&max=\(max)&pretty")
        let items = (root["items"] as? [[String: Any]]) ?? []
        let podcastTitle = (root["feed"] as? [String: Any]).flatMap { Self.string($0, ["title"]) }
        return items.compactMap { Self.mapEpisode($0, podcastTitle: podcastTitle) }
    }

    // MARK: - HTTP

    private func fetchJSON(path: String) async throws -> [String: Any] {
        if let hit = cache[path], Date().timeIntervalSince(hit.date) < cacheTTL,
           let object = try? JSONSerialization.jsonObject(with: hit.data) as? [String: Any] {
            return object
        }
        guard let url = URL(string: base + path) else { throw ServiceError.malformed(path) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        for (key, value) in authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.malformed("podcasts json")
        }
        cache[path] = (Date(), data)
        return object
    }

    private func authHeaders() -> [String: String] {
        let time = String(Int(Date().timeIntervalSince1970))
        let combined = apiKey + apiSecret + time
        let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return [
            "User-Agent": "MonochromeMusic/1.0",
            "X-Auth-Key": apiKey,
            "X-Auth-Date": time,
            "Authorization": hex,
        ]
    }

    private func feeds(from root: [String: Any]) -> [[String: Any]] {
        if let feeds = root["feeds"] as? [[String: Any]] { return feeds }
        if let feed = root["feed"] as? [String: Any] { return [feed] }
        return []
    }

    // MARK: - Mapping

    nonisolated static func mapPodcast(_ dict: [String: Any]) -> Podcast? {
        guard let id = string(dict, ["id"]), let title = string(dict, ["title"]) else { return nil }
        return Podcast(
            id: id,
            title: title,
            publisher: string(dict, ["author", "ownerName"]),
            cover: string(dict, ["image", "artwork"]),
            description: string(dict, ["description"]),
            episodeCount: int(dict, ["episodeCount"])
        )
    }

    nonisolated static func mapEpisode(_ dict: [String: Any], podcastTitle: String?) -> Track? {
        guard let rawID = string(dict, ["id"]),
              let title = string(dict, ["title"]),
              let enclosure = string(dict, ["enclosureUrl"]),
              let url = URL(string: enclosure) else { return nil }
        let feedTitle = string(dict, ["feedTitle"]) ?? podcastTitle ?? "Podcast"
        let cover = string(dict, ["image", "feedImage"])
        let duration = double(dict, ["duration"]) ?? 0
        let explicit: Bool = {
            if let b = dict["explicit"] as? Bool { return b }
            if let n = dict["explicit"] as? NSNumber { return n.intValue != 0 }
            return false
        }()
        let enclosureType = string(dict, ["enclosureType"])
        let qualityToken = PlaybackQuality.enclosureToken(mimeType: enclosureType, url: url)
        return Track(
            id: "podcast_\(rawID)",
            title: title,
            artist: Artist(id: "podcast", name: feedTitle, picture: cover),
            album: AlbumSummary(id: string(dict, ["feedId"]) ?? "", title: feedTitle, cover: cover),
            duration: duration,
            explicit: explicit,
            audioQuality: qualityToken,
            mediaTags: nil,
            isrc: nil,
            provider: .podcast,
            streamURL: url,
            enclosureType: enclosureType
        )
    }

    nonisolated private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    nonisolated private static func int(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    nonisolated private static func double(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? NSNumber { return value.doubleValue }
        }
        return nil
    }
}
