import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case tidal, amazon, qobuz, deezer, podcast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .podcast: return "Podcast"
        default: return rawValue.capitalized
        }
    }

    /// Catalog/provider picker — exclude podcasts (not a music catalog source).
    static var musicCases: [Provider] { allCases.filter { $0 != .podcast } }
}

/// Mirrors web `playback-quality` tokens (mapped to Amazon UHD/HD/SD and Deezer formats).
enum PlaybackQuality: String, CaseIterable, Identifiable, Codable {
    case low = "LOW"
    case high = "HIGH"
    case lossless = "LOSSLESS"
    case hiResLossless = "HI_RES_LOSSLESS"

    var id: String { rawValue }

    /// Stream responses echo the *provider's* token, not our raw value: Amazon
    /// returns `HD`/`UHD`/`SD_*`, Deezer returns `FLAC`/`MP3_*`, only TIDAL
    /// returns our own. Catalog payloads add a third vocabulary again
    /// (`HIRES_LOSSLESS`, `HIFI_PLUS`, `MQA`, …) via `audioQuality` and
    /// `mediaMetadata.tags` — web normalises all of them in `QUALITY_TOKENS`
    /// (js/utils.js), so mirror that table here or the badge silently vanishes.
    init?(providerToken raw: String) {
        // Amazon reports its tier as `HD_44_1_16` / `UHD_96_24`, so match on the
        // leading token rather than the whole string.
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let head = token.split(separator: "_").first.map(String.init) ?? token

        switch token {
        case "LOW", "LOW_QUALITY", "SD_LOW", "MP3_64", "MP3_128", "MP3_MISC", "HEAACV1", "AAC_LOW":
            self = .low
        case "HIGH", "HIGH_QUALITY", "NORMAL", "SD", "SD_HIGH", "MP3_320", "AACLC", "AAC", "MP4A":
            self = .high
        case "LOSSLESS", "HIFI", "CD", "FLAC", "MP4_RA_FLAC":
            self = .lossless
        case "HI_RES_LOSSLESS", "HIRES_LOSSLESS", "HIRESLOSSLESS", "HIFI_PLUS", "HI_RES_FLAC",
             "HI_RES", "HIRES", "MASTER", "MASTER_QUALITY", "MQA", "FLAC_HIRES", "UHD":
            self = .hiResLossless
        default:
            // Fall back to the Amazon tier prefix (`HD_…`, `UHD_…`, `SD_…`).
            switch head {
            case "UHD": self = .hiResLossless
            case "HD": self = .lossless
            case "SD": self = .high
            default: return nil
            }
        }
    }

    /// Descending audio fidelity, mirroring web `QUALITY_PRIORITY`.
    var rank: Int {
        switch self {
        case .hiResLossless: return 3
        case .lossless: return 2
        case .high: return 1
        case .low: return 0
        }
    }

    /// Best of the given provider tokens, ignoring the ones we cannot map.
    static func best(ofTokens tokens: [String]) -> PlaybackQuality? {
        tokens
            .compactMap(PlaybackQuality.init(providerToken:))
            .max { $0.rank < $1.rank }
    }

    var title: String {
        switch self {
        case .low: return "Low"
        case .high: return "High"
        case .lossless: return "Lossless (HiFi)"
        case .hiResLossless: return "Hi-Res Lossless"
        }
    }

    var amazonQuality: String {
        switch self {
        case .low: return "SD_LOW"
        case .high: return "SD_HIGH"
        case .lossless: return "HD"
        case .hiResLossless: return "UHD"
        }
    }

    var deezerFormat: String {
        switch self {
        case .low: return "MP3_128"
        case .high: return "MP3_320"
        case .lossless, .hiResLossless: return "FLAC"
        }
    }

    /// Original codec behind Amazon's `enca` (encrypted) sample entry. HD/UHD are
    /// FLAC; SD tiers are AAC. Drives the CENC decryptor's sample-entry rewrite.
    var amazonTargetCodec: String {
        switch self {
        case .low, .high: return "mp4a"
        case .lossless, .hiResLossless: return "flac"
        }
    }

    /// TIDAL OpenAPI `formats` preference order when falling back to HiFi manifests.
    var tidalFormats: [String] {
        switch self {
        case .low: return ["HEAACV1", "AACLC"]
        case .high: return ["AACLC"]
        case .lossless: return ["FLAC", "AACLC"]
        case .hiResLossless: return ["FLAC_HIRES", "FLAC", "AACLC"]
        }
    }

    static var stored: PlaybackQuality {
        let raw = UserDefaults.standard.string(forKey: "native.playbackQuality")
        if let raw, let value = PlaybackQuality(rawValue: raw) { return value }
        // Migrate legacy lossless toggle.
        if UserDefaults.standard.object(forKey: "native.highQuality") as? Bool == false {
            return .high
        }
        return .lossless
    }

    static func store(_ quality: PlaybackQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: "native.playbackQuality")
    }
}

enum PlaybackSourceSettings {
    static var amazonEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "native.amazonEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "native.amazonEnabled") }
    }

    static var amazonApiBaseURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: "native.amazonApiBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value! : "https://amz.geeked.wtf"
        }
        set { UserDefaults.standard.set(newValue, forKey: "native.amazonApiBaseURL") }
    }

    static var amazonBypassToken: String {
        get { UserDefaults.standard.string(forKey: "native.amazonBypassToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "native.amazonBypassToken") }
    }

    static var amazonTurnstileSiteKey: String {
        get {
            let value = UserDefaults.standard.string(forKey: "native.amazonTurnstileSiteKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value! : "0x4AAAAAADgxqF6QVMm0GLHH"
        }
        set { UserDefaults.standard.set(newValue, forKey: "native.amazonTurnstileSiteKey") }
    }

    static var deezerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "native.deezerEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "native.deezerEnabled") }
    }

    static var deezerApiBaseURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: "native.deezerApiBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value! : "https://dzr.tabs-vs-spaces.wtf"
        }
        set { UserDefaults.standard.set(newValue, forKey: "native.deezerApiBaseURL") }
    }

    /// Qobuz-via-Lucida fallback. ON by default — same as web `lucidaQobuzSettings`.
    static var lucidaEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "native.lucidaEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "native.lucidaEnabled") }
    }

    static var lucidaBaseURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: "native.lucidaBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value! : "https://monochrome.tf"
        }
        set { UserDefaults.standard.set(newValue, forKey: "native.lucidaBaseURL") }
    }
}

struct Artist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var picture: String?
}

struct Album: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: Artist
    var cover: String?
    var releaseDate: String?
    var numberOfTracks: Int?
    var explicit: Bool = false
    var audioQuality: String?
    var tracks: [Track] = []

    var artworkURL: URL? { Artwork.url(cover, size: 640) }
}

struct Track: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: Artist
    var album: AlbumSummary?
    var duration: Double
    var explicit: Bool
    var audioQuality: String?
    /// TIDAL `mediaMetadata.tags` (`LOSSLESS`, `HIRES_LOSSLESS`, `DOLBY_ATMOS`, …).
    /// Optional so tracks persisted before this field decode unchanged.
    var mediaTags: [String]?
    var isrc: String?
    var provider: Provider
    var streamURL: URL?

    init(id: String, title: String, artist: Artist, album: AlbumSummary? = nil, duration: Double = 0,
         explicit: Bool = false, audioQuality: String? = nil, mediaTags: [String]? = nil, isrc: String? = nil,
         provider: Provider = .tidal, streamURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.explicit = explicit
        self.audioQuality = audioQuality
        self.mediaTags = mediaTags
        self.isrc = isrc
        self.provider = provider
        self.streamURL = streamURL
    }

    var artworkURL: URL? { Artwork.url(album?.cover, size: 640) }
    var playbackID: String { id.split(separator: ":").last.map(String.init) ?? id }

    /// Podcast episodes use `podcast_{id}` (web/iOS) and play via `streamURL` enclosure.
    var isPodcast: Bool {
        provider == .podcast || id.hasPrefix("podcast_") || id.hasPrefix("podcast:")
    }

    /// Highest tier the *catalog* claims for this track. Used as the badge's
    /// fallback while the stream is still resolving, like web's
    /// `deriveTrackQuality`.
    var catalogQuality: PlaybackQuality? {
        var tokens: [String] = mediaTags ?? []
        if let audioQuality { tokens.append(audioQuality) }
        return PlaybackQuality.best(ofTokens: tokens)
    }
}

struct AlbumSummary: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var cover: String?
}

/// Editor's Picks mixes albums and standalone songs in one feed; each case
/// keeps its native model so a song opens playback instead of an album page.
enum EditorPick: Identifiable, Hashable {
    case album(Album)
    case track(Track)

    var id: String {
        switch self {
        case .album(let album): return "album:\(album.id)"
        case .track(let track): return "track:\(track.id)"
        }
    }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var description: String?
    var cover: String?
    var creator: String?
    var tracks: [Track]
}

struct Mix: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var cover: String?
    var tracks: [Track]
}

struct Podcast: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var publisher: String?
    var cover: String?
    var description: String?
    var episodeCount: Int?

    var artworkURL: URL? { Artwork.url(cover, size: 640) }
}

struct Profile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var username: String?
    var picture: String?
}

struct Party: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var host: Profile?
    var listenerCount: Int
    var nowPlaying: Track?
}

struct SearchResults {
    var tracks: [Track] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var podcasts: [Podcast] = []
}

struct StreamResponse: Codable {
    var url: URL
    var provider: Provider
    var quality: String
    var replayGain: Double?
    var peak: Double?
    /// TIDAL OpenAPI can return a ~30s `PREVIEW` when full playback needs a subscription.
    var isPreview: Bool = false
    var previewReason: String? = nil
    /// Actual playable media length when known (e.g. from DASH `mediaPresentationDuration`).
    var mediaDuration: Double? = nil
    /// Bit depth / sample rate of the selected tier when the provider reports it
    /// (Amazon `available_qualities`), e.g. `24/96`. Web shows the same next to
    /// the badge, and it is the only way to tell HD from UHD at a glance.
    var qualityDetail: String? = nil
}

struct LyricLine: Identifiable, Hashable {
    var id: Int
    var time: Double
    var text: String
}

struct SyncedLyrics: Hashable {
    var lines: [LyricLine]
    var plainText: String?
    var provider: String

    var isSynced: Bool { !lines.isEmpty }
    var isEmpty: Bool { lines.isEmpty && (plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    func activeIndex(at time: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var match = 0
        for (index, line) in lines.enumerated() {
            if line.time <= time { match = index } else { break }
        }
        return match
    }
}

enum ServiceError: LocalizedError, Equatable {
    case invalidResponse
    case http(Int)
    case malformed(String)
    case unavailable(String)
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an invalid response."
        case .http(let status): return "The server returned HTTP \(status)."
        case .malformed(let detail): return "The response could not be read: \(detail)"
        case .unavailable(let detail): return detail
        case .authenticationRequired: return "Sign in is required."
        }
    }
}

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one
}

enum Artwork {
    static func url(_ value: String?, size: Int = 320) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return URL(string: value) }
        let path = value.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(path)/\(size)x\(size).jpg")
    }
}

enum ModelMapper {
    static func unwrap(_ object: Any) -> Any {
        guard let dict = object as? [String: Any] else { return object }
        if let data = dict["data"] { return unwrap(data) }
        if let items = dict["items"] { return unwrap(items) }
        return object
    }

    static func array(_ object: Any, keys: [String] = []) -> [[String: Any]] {
        let value = unwrap(object)
        if let values = value as? [[String: Any]] { return values }
        if let dict = value as? [String: Any] {
            for key in keys where dict[key] != nil {
                let nested = unwrap(dict[key] as Any)
                if let values = nested as? [[String: Any]] { return values }
                if let nestedDict = nested as? [String: Any], let values = nestedDict["items"] as? [[String: Any]] { return values }
            }
        }
        return []
    }

    static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    static func artist(_ value: Any?) -> Artist {
        if let dict = value as? [String: Any] {
            return Artist(id: string(dict, ["id", "uuid"]) ?? "unknown", name: string(dict, ["name", "title"]) ?? "Unknown Artist", picture: string(dict, ["picture", "image", "cover"]))
        }
        if let list = value as? [[String: Any]], let first = list.first { return artist(first) }
        if let name = value as? String { return Artist(id: name, name: name, picture: nil) }
        return Artist(id: "unknown", name: "Unknown Artist", picture: nil)
    }

    /// `mediaMetadata.tags` on the track, falling back to the flat `mediaTags`
    /// key and then to the album the track came in (TIDAL tags albums, not
    /// always every track).
    static func mediaTags(_ dict: [String: Any]) -> [String]? {
        func tags(_ value: Any?) -> [String]? {
            if let list = value as? [String], !list.isEmpty { return list }
            if let nested = value as? [String: Any] { return nested["tags"] as? [String] }
            return nil
        }
        let candidates: [Any?] = [
            dict["mediaMetadata"], dict["media_metadata"], dict["mediaTags"],
            (dict["album"] as? [String: Any])?["mediaMetadata"],
            (dict["album"] as? [String: Any])?["mediaTags"],
        ]
        let collected = candidates.compactMap(tags).flatMap { $0 }
        return collected.isEmpty ? nil : collected
    }

    static func track(_ dict: [String: Any]) -> Track? {
        if let nested = (dict["item"] ?? dict["track"] ?? dict["value"]) as? [String: Any] { return track(nested) }
        guard let id = string(dict, ["id", "trackId", "uuid"]), let title = string(dict, ["title", "name"]) else { return nil }
        let artistValue = dict["artist"] ?? dict["artists"] ?? dict["artistName"]
        var album: AlbumSummary?
        if let a = dict["album"] as? [String: Any] {
            album = AlbumSummary(id: string(a, ["id", "uuid"]) ?? "", title: string(a, ["title", "name"]) ?? "", cover: string(a, ["cover", "image", "artwork"]))
        } else if let cover = string(dict, ["cover", "artwork"]) {
            album = AlbumSummary(id: "", title: string(dict, ["albumTitle"]) ?? "", cover: cover)
        }
        let seconds = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        let prefixed = id.contains(":") ? id : "tidal:\(id)"
        let directURL = string(dict, ["streamUrl", "streamURL"]).flatMap(URL.init(string:))
        return Track(id: prefixed, title: title, artist: artist(artistValue), album: album, duration: seconds,
                     explicit: (dict["explicit"] as? Bool) ?? false,
                     audioQuality: string(dict, ["audioQuality", "quality"]),
                     mediaTags: mediaTags(dict), isrc: string(dict, ["isrc", "ISRC"]),
                     provider: Provider(rawValue: prefixed.split(separator: ":").first.map(String.init) ?? "tidal") ?? .tidal,
                     streamURL: directURL)
    }

    static func album(_ dict: [String: Any]) -> Album? {
        if let nested = (dict["item"] ?? dict["album"] ?? dict["value"]) as? [String: Any] { return album(nested) }
        guard let id = string(dict, ["id", "uuid"]), let title = string(dict, ["title", "name"]) else { return nil }
        let tracks = array(dict["tracks"] as Any, keys: ["items"]).compactMap(track)
        return Album(id: id, title: title, artist: artist(dict["artist"] ?? dict["artists"]),
                     cover: string(dict, ["cover", "image", "artwork"]), releaseDate: string(dict, ["releaseDate", "release_date"]),
                     numberOfTracks: (dict["numberOfTracks"] as? NSNumber)?.intValue ?? tracks.count,
                     explicit: (dict["explicit"] as? Bool) ?? false, audioQuality: string(dict, ["audioQuality", "quality"]), tracks: tracks)
    }
}
