import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case tidal, amazon, qobuz, deezer, podcast, rythm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .podcast: return "Podcast"
        default: return rawValue.capitalized
        }
    }

    /// Catalog/provider picker — exclude podcasts and Rythm. Neither is a music
    /// catalog: Rythm only resolves a stream for a name/artist pair, it has no
    /// search, album or artist routes to browse.
    static var musicCases: [Provider] { allCases.filter { $0 != .podcast && $0 != .rythm } }
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
        case "HIGH", "HIGH_QUALITY", "NORMAL", "SD", "SD_HIGH", "MP3_320", "AACLC", "AAC", "MP4A",
             "MP3", "MPEG", "M4A", "OPUS", "OGG", "PODCAST", "VIDEO":
            // Lossy containers (incl. podcast enclosures). Tier = high so we never
            // paint the lossless wave mark; badgeLabel shows the real codec/format.
            self = .high
        case "LOSSLESS", "HIFI", "CD", "FLAC", "MP4_RA_FLAC", "WAV", "WAVE", "AIFF":
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

    /// Format-accurate badge text when the token is a container/codec, not a tier.
    /// Keeps MP3 podcasts from reading as generic "High" / never as "Lossless".
    static func badgeLabel(forToken raw: String) -> String? {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch token {
        case "MP3", "MPEG", "AUDIO_MPEG": return "MP3"
        case "AAC", "M4A", "MP4A", "AACLC": return "AAC"
        case "OPUS", "OGG": return "OPUS"
        case "WAV", "WAVE", "AIFF": return "WAV"
        case "FLAC": return "FLAC"
        case "VIDEO", "MP4", "M4V": return "VIDEO"
        case "PODCAST": return "PODCAST"
        default: return nil
        }
    }

    /// Infer a container/codec token from MIME + URL path. `nil` when unknown —
    /// callers must not invent a tier (esp. not the user's quality preference).
    static func mediaFormatToken(mimeType: String?, url: URL?) -> String? {
        let mime = (mimeType ?? "").lowercased()
        let path = (url?.path ?? "").lowercased()
        if mime.hasPrefix("video/")
            || mime == "application/mp4" || mime == "application/x-mp4"
            || path.hasSuffix(".mp4") || path.hasSuffix(".m4v")
            || path.hasSuffix(".webm") || path.hasSuffix(".mov") {
            return "VIDEO"
        }
        if mime.contains("flac") || path.hasSuffix(".flac") { return "FLAC" }
        if mime.contains("wav") || path.hasSuffix(".wav")
            || mime.contains("aiff") || path.hasSuffix(".aiff") {
            return "WAV"
        }
        if mime.contains("opus") || path.hasSuffix(".opus") { return "OPUS" }
        if mime.contains("ogg") || path.hasSuffix(".ogg") { return "OPUS" }
        if mime.contains("mpeg") || mime.contains("mp3") || path.hasSuffix(".mp3") {
            return "MP3"
        }
        if mime.contains("aac") || mime.contains("m4a") || mime == "audio/mp4"
            || path.hasSuffix(".m4a") || path.hasSuffix(".aac") {
            return "AAC"
        }
        return nil
    }

    /// Podcast enclosure → honest stream token. Unknown container stays `PODCAST`
    /// (lossy/unknown) rather than blanking the badge or borrowing the user pref.
    static func enclosureToken(mimeType: String?, url: URL?) -> String {
        mediaFormatToken(mimeType: mimeType, url: url) ?? "PODCAST"
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

    /// Offline download quality — separate from streaming. Defaults to hi-res lossless
    /// (web `download-quality` / `HI_RES_LOSSLESS`).
    static var downloadStored: PlaybackQuality {
        let raw = UserDefaults.standard.string(forKey: "native.downloadQuality")
        if let raw, let value = PlaybackQuality(rawValue: raw) { return value }
        return .hiResLossless
    }

    static func storeDownload(_ quality: PlaybackQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: "native.downloadQuality")
    }
}

enum PlaybackSourceSettings {
    /// Rythm (`track-api.monochrome.tf`) is the resolver the web client reaches
    /// for first. It aggregates server-side, so it keeps resolving while the
    /// HiFi pool answers `Upstream API error` for `/track/` and while the Deezer
    /// account pool is dead. ON by default; the legacy chain stays behind it.
    static var rythmEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "native.rythmEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "native.rythmEnabled") }
    }

    static var rythmBaseURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: "native.rythmBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value! : "https://track-api.monochrome.tf"
        }
        set { UserDefaults.standard.set(newValue, forKey: "native.rythmBaseURL") }
    }

    static var rythmBypassToken: String {
        get { UserDefaults.standard.string(forKey: "native.rythmBypassToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "native.rythmBypassToken") }
    }

    /// Rythm publishes its own key at `GET /config`; it is currently the same one
    /// Amazon uses, so the stored default is shared and the fetch is skipped.
    static var rythmTurnstileSiteKey: String {
        get {
            let value = UserDefaults.standard.string(forKey: "native.rythmTurnstileSiteKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value! : "0x4AAAAAADgxqF6QVMm0GLHH"
        }
        set { UserDefaults.standard.set(newValue, forKey: "native.rythmTurnstileSiteKey") }
    }

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
    /// PodcastIndex `enclosureType` (e.g. `video/mp4`) — video episodes play visually.
    var enclosureType: String?
    /// Provider that filled the offline file (Amazon/Qobuz/Deezer). Drives Lucida badge on local play.
    var offlineProvider: Provider? = nil
    /// Quality token written with the offline file.
    var offlineQuality: String? = nil
    var offlineQualityDetail: String? = nil
    /// Beats per minute reported by TIDAL. Absent for much of the long tail, so
    /// autoplay treats `nil` as "unknown" rather than folding it into a default.
    var bpm: Double? = nil
    /// Musical key (e.g. `Bb`) and scale (`MAJOR`/`MINOR`) — drive harmonic mixing.
    var musicalKey: String? = nil
    var keyScale: String? = nil
    /// TIDAL popularity, 0-100.
    var popularity: Int? = nil
    /// Release year, taken from the album or stream start date when present.
    var releaseYear: Int? = nil
    /// Set when autoplay queued this track, so the UI can label it and the
    /// engine can weight a skip on its own pick more heavily than a manual one.
    var recSource: String? = nil

    init(id: String, title: String, artist: Artist, album: AlbumSummary? = nil, duration: Double = 0,
         explicit: Bool = false, audioQuality: String? = nil, mediaTags: [String]? = nil, isrc: String? = nil,
         provider: Provider = .tidal, streamURL: URL? = nil, enclosureType: String? = nil,
         offlineProvider: Provider? = nil, offlineQuality: String? = nil, offlineQualityDetail: String? = nil,
         bpm: Double? = nil, musicalKey: String? = nil, keyScale: String? = nil,
         popularity: Int? = nil, releaseYear: Int? = nil, recSource: String? = nil) {
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
        self.enclosureType = enclosureType
        self.offlineProvider = offlineProvider
        self.offlineQuality = offlineQuality
        self.offlineQualityDetail = offlineQualityDetail
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.keyScale = keyScale
        self.popularity = popularity
        self.releaseYear = releaseYear
        self.recSource = recSource
    }

    /// Camelot wheel code (e.g. `3A`) when TIDAL reported a key, else nil.
    var camelot: String? { RecommendationMath.camelot(key: musicalKey, scale: keyScale) }

    var artworkURL: URL? { Artwork.url(album?.cover, size: 640) }
    var playbackID: String { id.split(separator: ":").last.map(String.init) ?? id }

    /// Podcast episodes use `podcast_{id}` (web/iOS) and play via `streamURL` enclosure.
    var isPodcast: Bool {
        provider == .podcast || id.hasPrefix("podcast_") || id.hasPrefix("podcast:")
    }

    /// Video podcast episode — enclosure is a video media file.
    var isVideoPodcast: Bool {
        guard isPodcast else { return false }
        let mime = (enclosureType ?? "").lowercased()
        if mime.hasPrefix("video/") { return true }
        if mime == "application/mp4" || mime == "application/x-mp4" { return true }
        guard let path = streamURL?.absoluteString.lowercased()
            .split(separator: "?").first
            .map(String.init) else { return false }
        return path.hasSuffix(".mp4") || path.hasSuffix(".m4v")
            || path.hasSuffix(".webm") || path.hasSuffix(".mov")
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
    /// Headers required by provider endpoints that only serve the Monochrome web origin.
    var requestHeaders: [String: String] = [:]
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
    /// TIDAL v1 payloads use numeric seconds while OpenAPI search results use
    /// ISO-8601 durations such as `PT3M11S`. Normalize both at the model edge so
    /// selecting a search result does not look like a zero-duration track and
    /// trigger an unnecessary metadata request before playback can start.
    static func durationSeconds(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let raw = value as? String else { return 0 }
        if let seconds = Double(raw) { return seconds }

        let expression = #"^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$"#
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.range.location != NSNotFound else { return 0 }

        func component(_ index: Int) -> Double {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: raw) else { return 0 }
            return Double(String(raw[range])) ?? 0
        }
        return component(1) * 3_600 + component(2) * 60 + component(3)
    }

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
        let seconds = durationSeconds(dict["duration"])
        let prefixed = id.contains(":") ? id : "tidal:\(id)"
        let directURL = string(dict, ["streamUrl", "streamURL"]).flatMap(URL.init(string:))

        // Album, playlist and mix payloads embed the full TIDAL track object, so
        // BPM and key often arrive free here and need no extra /info lookup.
        let albumDict = dict["album"] as? [String: Any]
        let releaseDate = string(dict, ["streamStartDate", "releaseDate"])
            ?? albumDict.flatMap { string($0, ["releaseDate", "release_date"]) }

        return Track(id: prefixed, title: title, artist: artist(artistValue), album: album, duration: seconds,
                     explicit: (dict["explicit"] as? Bool) ?? false,
                     audioQuality: string(dict, ["audioQuality", "quality"]),
                     mediaTags: mediaTags(dict), isrc: string(dict, ["isrc", "ISRC"]),
                     provider: Provider(rawValue: prefixed.split(separator: ":").first.map(String.init) ?? "tidal") ?? .tidal,
                     streamURL: directURL,
                     bpm: (dict["bpm"] as? NSNumber)?.doubleValue,
                     musicalKey: string(dict, ["key"]),
                     keyScale: string(dict, ["keyScale"]),
                     popularity: (dict["popularity"] as? NSNumber)?.intValue,
                     releaseYear: releaseDate.flatMap(year(from:)))
    }

    /// Leading four digits of an ISO-8601 date, e.g. `1993-04-05` -> 1993.
    static func year(from date: String) -> Int? {
        Int(date.prefix(4))
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
