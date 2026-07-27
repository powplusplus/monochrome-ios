import Foundation

// MARK: - Pure math

/// Scoring and ranking primitives for autoplay. Every function here is a plain
/// transform over plain values - no networking, no shared state - so the
/// ranking behaviour can be unit-tested directly.
///
/// Mirrors `js/recommendation-vectors.js` in the web client.
enum RecommendationMath {

    // MARK: Weights

    /// Positive scoring weights. These sum to 1; terms that are unavailable for a
    /// given candidate are dropped and the rest renormalized (see `combine`).
    static let weights: [(name: String, value: Double)] = [
        ("tagSimilarity", 0.26),
        ("bpmProximity", 0.14),
        ("harmonicFit", 0.08),
        ("artistProximity", 0.15),
        ("taste", 0.13),
        ("eraProximity", 0.07),
        ("popProximity", 0.06),
        ("sourcePrior", 0.06),
        ("energyProximity", 0.03),
        ("durProximity", 0.02),
    ]

    static let dislikeWeight = 0.25
    static let artistPenaltyWeight = 0.10

    struct DiversityPreset {
        var lambda: Double
        var exploreRatio: Double
    }

    static let presets: [String: DiversityPreset] = [
        "low": DiversityPreset(lambda: 0.85, exploreRatio: 0.10),
        "balanced": DiversityPreset(lambda: 0.72, exploreRatio: 0.20),
        "high": DiversityPreset(lambda: 0.58, exploreRatio: 0.32),
    ]

    // MARK: Tag vocabulary

    /// Tags describing the listener's relationship to a track rather than the music.
    static let stopwordTags: Set<String> = [
        "seenlive", "favorites", "favourites", "favoritesongs", "favouritesongs",
        "awesome", "mymusic", "beautiful", "love", "lovedtracks", "checkout",
        "albumsiown", "under2000listeners", "spotify", "goodstuff", "amazing",
        "best", "bestsongsever", "epic", "masterpiece", "coolstuff", "music",
        "song", "songs", "iown",
    ]

    /// Rough energy proxy, used only when TIDAL reports no BPM for a track.
    static let energyTags: [String: Double] = [
        "ambient": 0.05, "drone": 0.05, "newage": 0.10, "meditation": 0.10,
        "classical": 0.20, "lullaby": 0.10, "chillout": 0.15, "chill": 0.20,
        "downtempo": 0.25, "lofi": 0.20, "slowcore": 0.15, "sadcore": 0.15,
        "acoustic": 0.25, "folk": 0.30, "singersongwriter": 0.30, "ballad": 0.20,
        "jazz": 0.30, "bossanova": 0.25, "soul": 0.40, "rnb": 0.40,
        "dreampop": 0.30, "shoegaze": 0.45, "triphop": 0.30, "blues": 0.40,
        "country": 0.40, "reggae": 0.40, "dub": 0.35, "pop": 0.55,
        "synthpop": 0.55, "indie": 0.50, "indiepop": 0.50, "indierock": 0.55,
        "alternative": 0.55, "rock": 0.60, "classicrock": 0.60, "britpop": 0.55,
        "funk": 0.60, "disco": 0.65, "house": 0.70, "deephouse": 0.60,
        "hiphop": 0.60, "rap": 0.62, "trap": 0.65, "grime": 0.75, "drill": 0.65,
        "electronic": 0.60, "edm": 0.80, "trance": 0.80, "techno": 0.80,
        "dubstep": 0.82, "breakbeat": 0.78, "jungle": 0.88, "drumandbass": 0.90,
        "hardstyle": 0.95, "gabber": 0.98, "punk": 0.85, "postpunk": 0.65,
        "hardcore": 0.95, "metal": 0.85, "heavymetal": 0.85, "deathmetal": 0.95,
        "blackmetal": 0.92, "metalcore": 0.90, "thrashmetal": 0.95,
        "grindcore": 0.98, "screamo": 0.90,
    ]

    // MARK: Sparse vectors

    static func l2Normalize(_ vector: [String: Double]) -> [String: Double] {
        let sumSquares = vector.values.reduce(0) { $0 + $1 * $1 }
        guard sumSquares > 0 else { return [:] }
        let magnitude = sumSquares.squareRoot()
        var out: [String: Double] = [:]
        for (key, value) in vector where value != 0 { out[key] = value / magnitude }
        return out
    }

    /// Cosine similarity of two sparse maps. Returns 0 - never NaN - when either
    /// side is empty, which is the common case for tracks Last.fm has no tags for.
    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var dot = 0.0
        for (key, value) in small { if let other = large[key] { dot += value * other } }
        guard dot != 0 else { return 0 }
        let magA = a.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let magB = b.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA * magB)
    }

    static func addScaled(_ target: inout [String: Double], _ vector: [String: Double], _ scale: Double) {
        for (key, value) in vector { target[key, default: 0] += value * scale }
    }

    static func topKeys(_ vector: [String: Double], _ limit: Int) -> [String] {
        vector.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: Tags

    static func normalizeTagName(_ name: String) -> String {
        var text = name.lowercased().replacingOccurrences(of: "&", with: " and ")
        text = text.filter { $0.isLetter || $0.isNumber }
        return text
    }

    /// Builds an L2-normalized tag vector. Track tags dominate; artist tags fill
    /// in so an album cut with no tags of its own still lands near its artist.
    static func buildTagVector(trackTags: [(name: String, count: Int)],
                               artistTags: [(name: String, count: Int)]) -> [String: Double] {
        func usable(_ tags: [(name: String, count: Int)]) -> [(name: String, count: Int)] {
            tags.map { (normalizeTagName($0.name), $0.count) }
                .filter { !$0.0.isEmpty && !stopwordTags.contains($0.0) && $0.1 >= 10 }
                .sorted { $0.1 > $1.1 }
        }

        let track = usable(trackTags)
        let artist = usable(artistTags)

        var vector: [String: Double] = [:]
        for tag in track.prefix(10) {
            vector[tag.name] = max(vector[tag.name] ?? 0, Double(tag.count) / 100)
        }

        // Thin track tagging means leaning harder on the artist's profile.
        let artistWeight = track.count < 3 ? 0.55 : 0.35
        for tag in artist.prefix(6) where vector[tag.name] == nil {
            vector[tag.name] = Double(tag.count) / 100 * artistWeight
        }

        var trimmed: [String: Double] = [:]
        for key in topKeys(vector, 12) { trimmed[key] = vector[key] }
        return l2Normalize(trimmed)
    }

    /// Energy in [0,1] plus a confidence of 0 when no tag matched, so callers can
    /// drop the term instead of scoring everything as average.
    static func energy(from tagVector: [String: Double]) -> (energy: Double, confidence: Double) {
        var weighted = 0.0
        var total = 0.0
        for (name, weight) in tagVector {
            guard let value = energyTags[name] else { continue }
            weighted += value * weight
            total += weight
        }
        guard total > 0 else { return (0.5, 0) }
        return (weighted / total, min(1, total))
    }

    // MARK: Musical key

    private static let minorWheel = ["A": 8, "A#": 3, "B": 10, "C": 5, "C#": 12, "D": 7,
                                     "D#": 2, "E": 9, "F": 4, "F#": 11, "G": 6, "G#": 1]
    private static let majorWheel = ["A": 11, "A#": 6, "B": 1, "C": 8, "C#": 3, "D": 10,
                                     "D#": 5, "E": 12, "F": 7, "F#": 2, "G": 9, "G#": 4]
    private static let flatToSharp = ["Ab": "G#", "Bb": "A#", "Cb": "B", "Db": "C#",
                                      "Eb": "D#", "Fb": "E", "Gb": "F#"]

    static func camelot(key: String?, scale: String?) -> String? {
        guard var pitch = key?.trimmingCharacters(in: .whitespaces), !pitch.isEmpty else { return nil }
        pitch = pitch.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        pitch = pitch.prefix(1).uppercased() + pitch.dropFirst()
        if let sharp = flatToSharp[pitch] { pitch = sharp }

        let isMinor = (scale ?? "").uppercased() == "MINOR"
        guard let number = isMinor ? minorWheel[pitch] : majorWheel[pitch] else { return nil }
        return "\(number)\(isMinor ? "A" : "B")"
    }

    /// Harmonic compatibility in [0,1] using standard DJ mixing rules. Returns nil
    /// when either key is unknown, so the term drops out of the weighted sum.
    static func harmonicFit(_ candidate: String?, _ reference: String?) -> Double? {
        guard let a = parseCamelot(candidate), let b = parseCamelot(reference) else { return nil }
        if a.number == b.number && a.letter == b.letter { return 1 }
        if a.number == b.number { return 0.8 } // relative major/minor
        let distance = abs(a.number - b.number)
        if min(distance, 12 - distance) == 1 && a.letter == b.letter { return 0.8 }
        return 0.3
    }

    private static func parseCamelot(_ code: String?) -> (number: Int, letter: Character)? {
        guard let code, let letter = code.last, letter == "A" || letter == "B",
              let number = Int(code.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }

    // MARK: Scalar proximities

    /// Tempo similarity with half/double-time credit - 87 and 174 BPM are the same
    /// groove and should not read as opposites.
    static func bpmProximity(_ candidate: Double?, _ reference: Double?) -> Double? {
        guard let candidate, let reference, candidate > 0, reference > 0 else { return nil }
        return [reference, reference / 2, reference * 2]
            .map { 1 - min(1, abs(candidate - $0) / 30) }
            .max()
    }

    static func popBand(_ popularity: Int?) -> Int? {
        guard let popularity else { return nil }
        switch popularity {
        case ..<20: return 0
        case ..<40: return 1
        case ..<60: return 2
        case ..<80: return 3
        default: return 4
        }
    }

    /// Duration band index 0-3 from a duration in seconds.
    static func durBandIndex(_ seconds: Double?) -> Int? {
        guard let seconds, seconds > 0 else { return nil }
        switch seconds {
        case ..<120: return 0
        case ..<300: return 1
        case ..<420: return 2
        default: return 3
        }
    }

    private static func linear(_ candidate: Double, _ reference: Double, span: Double) -> Double {
        1 - min(1, abs(candidate - reference) / span)
    }

    /// Unknown release dates score neutral - missing data should not bury a track.
    static func eraProximity(_ year: Int?, _ meanYear: Double?) -> Double {
        guard let year, let meanYear else { return 0.5 }
        return linear(Double(year), meanYear, span: 20)
    }

    static func popProximity(_ band: Int?, _ meanBand: Double?) -> Double {
        guard let band, let meanBand else { return 0.5 }
        return linear(Double(band), meanBand, span: 4)
    }

    static func durProximity(_ index: Int?, _ meanIndex: Double?) -> Double {
        guard let index, let meanIndex else { return 0.5 }
        return linear(Double(index), meanIndex, span: 3)
    }

    static func energyProximity(_ energy: Double?, confidence: Double, _ meanEnergy: Double?) -> Double {
        guard let energy, let meanEnergy, confidence > 0 else { return 0.5 }
        return 1 - min(1, abs(energy - meanEnergy))
    }

    static func affinitySigmoid(_ affinity: Double) -> Double {
        1 / (1 + exp(-affinity / 2))
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }

    // MARK: Combined score

    /// Weighted sum over the available terms.
    ///
    /// Terms passed as nil (no BPM, no key, no tags on either side) are dropped and
    /// the surviving weights renormalized to sum to 1. Without that, a Last.fm
    /// outage or a BPM-less catalog would flatten every score to zero instead of
    /// degrading to metadata-only ranking.
    static func combine(terms: [String: Double?], penalties: [String: Double] = [:]) -> Double {
        var available: [(Double, Double)] = []
        var weightSum = 0.0

        for (name, weight) in weights {
            guard let value = terms[name] ?? nil, !value.isNaN else { continue }
            available.append((weight, value))
            weightSum += weight
        }

        var score = 0.0
        if weightSum > 0 {
            for (weight, value) in available { score += (weight / weightSum) * value }
        }

        score -= dislikeWeight * (penalties["dislikeSimilarity"] ?? 0)
        score -= artistPenaltyWeight * (penalties["artistPenalty"] ?? 0)

        return clamp(score, -1, 1.5)
    }

    // MARK: Diversity

    /// A scored candidate, reduced to just what re-ranking needs.
    struct Candidate {
        var id: String
        var score: Double
        var tags: [String: Double]
        var bpm: Double?
        var artistID: String
        var albumID: String?
        var isExplore: Bool
    }

    static func similarity(_ a: Candidate, _ b: Candidate) -> Double {
        let tagPart = cosine(a.tags, b.tags)
        let bpmPart = bpmProximity(a.bpm, b.bpm) ?? 0
        let artistPart = a.artistID == b.artistID ? 1.0 : 0.0
        return 0.55 * tagPart + 0.30 * artistPart + 0.15 * bpmPart
    }

    /// Greedy MMR selection with per-artist and per-album caps plus an exploration
    /// quota, so a batch can never collapse into one artist on repeat.
    ///
    /// Caps are measured against a sliding window that includes tracks already
    /// queued; otherwise three consecutive batches could each legally add two
    /// tracks by the same artist.
    static func selectDiverse(_ candidates: [Candidate],
                              count: Int,
                              queueTail: [Candidate] = [],
                              lambda: Double = 0.72,
                              exploreRatio: Double = 0.20,
                              maxPerArtist: Int = 2,
                              maxPerAlbum: Int = 2) -> [Candidate] {
        var pool = candidates
        var selected: [Candidate] = []
        let exploreQuota = Int((exploreRatio * Double(count)).rounded(.up))
        var exploreFilled = 0

        while selected.count < count && !pool.isEmpty {
            let remaining = count - selected.count
            let forceExplore = (exploreQuota - exploreFilled) >= remaining
            let window = Array((queueTail + selected).suffix(10))

            func artistCount(_ candidate: Candidate) -> Int {
                window.filter { $0.artistID == candidate.artistID }.count
            }
            func albumCount(_ candidate: Candidate) -> Int {
                guard let album = candidate.albumID else { return 0 }
                return window.filter { $0.albumID == album }.count
            }

            // Relax constraints in tiers so a homogeneous pool can never deadlock.
            var eligible = pool.filter {
                artistCount($0) < maxPerArtist && albumCount($0) < maxPerAlbum
                    && (!forceExplore || $0.isExplore)
            }
            if eligible.isEmpty { eligible = pool.filter { artistCount($0) < maxPerArtist } }
            if eligible.isEmpty { eligible = pool }

            let compareAgainst = Array(queueTail.suffix(5)) + selected

            var best: Candidate?
            var bestValue = -Double.infinity
            for candidate in eligible {
                let maxSim = compareAgainst.map { similarity(candidate, $0) }.max() ?? 0
                let value = lambda * candidate.score - (1 - lambda) * maxSim
                if value > bestValue {
                    bestValue = value
                    best = candidate
                }
            }

            guard let pick = best else { break }
            selected.append(pick)
            if pick.isExplore { exploreFilled += 1 }
            pool.removeAll { $0.id == pick.id }
        }

        return selected
    }

    // MARK: Resolution keys

    /// Collapses the cosmetic differences between how Last.fm and TIDAL spell the
    /// same recording, so "Paranoid Android - 2009 Remaster" matches "Paranoid
    /// Android".
    static func normalizeForResolution(_ value: String) -> String {
        var text = value.lowercased()

        // Drop a trailing edition suffix: " - 2009 Remaster", " - Live", ...
        let editions = ["remastered", "remaster", "remix", "radio edit", "single version",
                        "album version", "mono", "stereo", "live", "deluxe", "anniversary", "edit"]
        if let dashRange = text.range(of: " - ", options: .backwards) {
            let tail = String(text[dashRange.upperBound...])
            if editions.contains(where: { tail.contains($0) }) {
                text = String(text[..<dashRange.lowerBound])
            }
        }

        // Drop a parenthesised featured-artist clause.
        for open in ["(", "["] {
            while let openRange = text.range(of: open) {
                let closing = open == "(" ? ")" : "]"
                guard let closeRange = text.range(of: closing, range: openRange.upperBound..<text.endIndex)
                else { break }
                let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
                guard inner.hasPrefix("feat") || inner.hasPrefix("ft") || inner.hasPrefix("with") else { break }
                text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            }
        }

        let folded = text.folding(options: [.diacriticInsensitive], locale: .current)
        return folded.filter { $0.isLetter || $0.isNumber }
    }

    static func resolveKey(artist: String, title: String) -> String {
        "\(normalizeForResolution(artist))|\(normalizeForResolution(title))"
    }
}

// MARK: - Last.fm read client

/// Read-only Last.fm client for genre and mood metadata.
///
/// Deliberately separate from scrobbling: these endpoints need only an api_key, so
/// this client never touches a shared secret and never signs a request.
actor LastFmRead {
    static let shared = LastFmRead()

    private let apiKey = "85214f5abbc730e78770f27784b9bdf7"
    private let endpoint = "https://ws.audioscrobbler.com/2.0/"
    private let session: URLSession

    private let minSpacing: TimeInterval = 0.25
    private var lastRequestAt: Date = .distantPast

    private let failuresBeforeTrip = 3
    private let backoffLadder: [TimeInterval] = [60, 300, 1800]
    private var consecutiveFailures = 0
    private var backoffStep = 0
    private var disabledUntil: Date = .distantPast

    init(session: URLSession = .shared) { self.session = session }

    var isAvailable: Bool { Date() >= disabledUntil }

    func trackTopTags(artist: String, title: String) async -> [(name: String, count: Int)] {
        let json = await request("track.getTopTags", ["artist": artist, "track": title, "autocorrect": "1"])
        return tags(from: (json?["toptags"] as? [String: Any])?["tag"])
    }

    func artistTopTags(artist: String) async -> [(name: String, count: Int)] {
        let json = await request("artist.getTopTags", ["artist": artist, "autocorrect": "1"])
        return tags(from: (json?["toptags"] as? [String: Any])?["tag"])
    }

    func similarTracks(artist: String, title: String, limit: Int = 30) async -> [(artist: String, title: String, match: Double)] {
        let json = await request("track.getSimilar",
                                 ["artist": artist, "track": title, "limit": String(limit), "autocorrect": "1"])
        return similar(from: (json?["similartracks"] as? [String: Any])?["track"])
    }

    func tagTopTracks(tag: String, limit: Int = 30) async -> [(artist: String, title: String, match: Double)] {
        let json = await request("tag.getTopTracks", ["tag": tag, "limit": String(limit)])
        return similar(from: (json?["tracks"] as? [String: Any])?["track"])
    }

    private func tags(from value: Any?) -> [(name: String, count: Int)] {
        objects(from: value).compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return (name, (item["count"] as? NSNumber)?.intValue ?? 0)
        }
    }

    private func similar(from value: Any?) -> [(artist: String, title: String, match: Double)] {
        objects(from: value).compactMap { item in
            guard let title = item["name"] as? String, !title.isEmpty else { return nil }
            let artistName = (item["artist"] as? [String: Any])?["name"] as? String
                ?? item["artist"] as? String
            guard let artist = artistName, !artist.isEmpty else { return nil }
            return (artist, title, (item["match"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    private func objects(from value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    /// Issues a throttled GET, returning nil rather than throwing: "no Last.fm
    /// data" is an ordinary, expected outcome for much of the catalog.
    private func request(_ method: String, _ parameters: [String: String]) async -> [String: Any]? {
        guard isAvailable else { return nil }

        var components = URLComponents(string: endpoint)
        components?.queryItems = ([
            "method": method, "api_key": apiKey, "format": "json",
        ].merging(parameters) { current, _ in current }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return nil }

        await pace()

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                recordFailure()
                return nil
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let code = (json?["error"] as? NSNumber)?.intValue {
                // 6 = "no such track" - a legitimate empty answer, not a fault.
                if code == 6 { recordSuccess(); return nil }
                recordFailure()
                return nil
            }

            recordSuccess()
            return json
        } catch {
            recordFailure()
            return nil
        }
    }

    private func pace() async {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < minSpacing {
            try? await Task.sleep(nanoseconds: UInt64((minSpacing - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    private func recordSuccess() {
        consecutiveFailures = 0
        backoffStep = 0
        disabledUntil = .distantPast
    }

    private func recordFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= failuresBeforeTrip else { return }
        let backoff = backoffLadder[min(backoffStep, backoffLadder.count - 1)]
        disabledUntil = Date().addingTimeInterval(backoff)
        backoffStep += 1
        consecutiveFailures = 0
    }
}

// MARK: - Feature cache

/// Everything the ranker knows about one track.
struct TrackFeature: Codable {
    var id: String
    var tags: [String: Double] = [:]
    var energy: Double = 0.5
    var energyConfidence: Double = 0
    var bpm: Double?
    var camelot: String?
    var artistID: String = ""
    var albumID: String?
    var releaseYear: Int?
    var popBand: Int?
    var durBandIndex: Int?
    var hasTags = false
    var hasAudio = false
    var fetchedAt: TimeInterval = Date().timeIntervalSince1970

    /// Tag lookups that came back empty are retried the next day; a complete
    /// vector is kept for months, since BPM and key never change.
    var isStale: Bool {
        let ttl: TimeInterval = (hasTags && hasAudio) ? 90 * 86_400 : 86_400
        return Date().timeIntervalSince1970 - fetchedAt > ttl
    }
}

/// Disk-backed store of feature vectors, so the catalog knowledge a listener
/// builds up survives relaunches and costs nothing to reuse.
actor FeatureStore {
    static let shared = FeatureStore()

    private var entries: [String: TrackFeature] = [:]
    private var loaded = false
    private var dirty = false
    private let maxEntries = 5000

    private var fileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("autoplay-features.json")
    }

    func feature(_ id: String) -> TrackFeature? {
        load()
        guard let entry = entries[id], !entry.isStale else { return nil }
        return entry
    }

    func store(_ feature: TrackFeature) {
        load()
        entries[feature.id] = feature
        dirty = true
    }

    func flush() {
        guard dirty, let fileURL else { return }
        prune()
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
        dirty = false
    }

    private func prune() {
        entries = entries.filter { !$0.value.isStale }
        guard entries.count > maxEntries else { return }
        let keep = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(maxEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: TrackFeature].self, from: data) else { return }
        entries = decoded
    }
}

// MARK: - Engine

/// Autoplay recommender for the native player.
///
/// Recall unions TIDAL track radio, similar artists' top tracks, Last.fm similar
/// tracks and Last.fm tag radio. Ranking blends content similarity (tags, tempo,
/// musical key, era, popularity) with the listener's own skip and completion
/// history, then a diversity pass caps per-artist repetition and reserves slots
/// for unfamiliar artists.
///
/// Mirrors `js/recommendation-engine.js`.
actor RecommendationEngine {
    static let shared = RecommendationEngine()

    private let service: MusicService
    private let lastFm: LastFmRead
    private let store: FeatureStore

    private let maxTagLookups = 20
    private let maxResolutions = 12
    private let maxEnrichments = 20

    /// Recall provenance, used as a weak prior and as agreement evidence.
    private enum Source: String {
        case tidalRadio, lastfmSimilar, similarArtist, lastfmTag

        var prior: Double {
            switch self {
            case .tidalRadio: return 1.00
            case .lastfmSimilar: return 0.90
            case .similarArtist: return 0.70
            case .lastfmTag: return 0.50
            }
        }
    }

    private struct PoolEntry {
        var track: Track
        var sources: Set<Source>
    }

    /// Rolling taste picture, rebuilt lazily as tracks finish or get skipped.
    private var positive: [TrackFeature] = []
    private var negative: [TrackFeature] = []
    private var skippedArtists: [String: Int] = [:]
    private var skippedTags: Set<String> = []
    private var knownArtists: Set<String> = []
    /// Keys Last.fm knows but the catalog does not. Caching only the misses is what
    /// stops the long tail costing a search on every single batch.
    private var unresolvable: Set<String> = []

    init(service: MusicService = .shared,
         lastFm: LastFmRead = .shared,
         store: FeatureStore = .shared) {
        self.service = service
        self.lastFm = lastFm
        self.store = store
    }

    // MARK: Feedback

    /// Records that the listener rejected a track. A skip on autoplay's own pick
    /// is a much stronger signal than one on something they chose themselves.
    func recordSkip(_ track: Track, completion: Double) {
        guard completion <= 0.5 else { return }

        if let feature = cachedFeature(track) {
            negative.insert(feature, at: 0)
            negative = Array(negative.prefix(12))
            for tag in RecommendationMath.topKeys(feature.tags, 3) { skippedTags.insert(tag) }
        }

        if track.recSource != nil {
            skippedArtists[track.artist.id, default: 0] += 1
        }
    }

    func recordFinish(_ track: Track, completion: Double) {
        knownArtists.insert(track.artist.id)
        guard completion > 0.8 else { return }

        if let feature = cachedFeature(track) {
            positive.insert(feature, at: 0)
            positive = Array(positive.prefix(20))
        }
        skippedArtists[track.artist.id] = nil
    }

    private func cachedFeature(_ track: Track) -> TrackFeature? {
        var feature = baseFeature(for: track)
        if let stored = memoryFeatures[track.id] {
            feature = stored
        }
        return feature
    }

    /// In-process mirror of the disk store, so feedback on the playback path never
    /// waits on file I/O.
    private var memoryFeatures: [String: TrackFeature] = [:]

    // MARK: Recommend

    /// Produces the next batch of tracks to append to the queue.
    ///
    /// - Parameters:
    ///   - seeds: tracks to expand from, most relevant first.
    ///   - queueTail: tracks already scheduled, so diversity caps span batches.
    ///   - exclude: track ids the listener already has or just heard.
    ///   - count: how many tracks to return.
    func recommend(seeds: [Track],
                   queueTail: [Track],
                   exclude: Set<String>,
                   count: Int,
                   diversity: String = "balanced") async -> [Track] {
        guard !seeds.isEmpty else { return [] }

        let centroid = await buildCentroid(seeds: seeds)
        var pool = await recall(seeds: seeds, centroid: centroid, exclude: exclude)
        guard !pool.isEmpty else { return [] }

        pool = dedupeVariants(pool)

        let seedArtistIDs = Set(seeds.map(\.artist.id))
        let similarArtistIDs = await similarArtistIDs(for: seeds)

        // Cheap pass first: tags and free metadata, no per-track network cost.
        var features = await tagFeatures(for: pool.map(\.track))
        var scored = pool.map {
            score($0, feature: features[$0.track.id], centroid: centroid,
                  seedArtistIDs: seedArtistIDs, similarArtistIDs: similarArtistIDs)
        }
        scored.sort { $0.score > $1.score }

        // Only the shortlist is worth an /info round-trip for BPM and key.
        let shortlist = Array(scored.prefix(maxEnrichments))
        let enriched = await enrichAudio(shortlist.map(\.entry), features: features)
        features.merge(enriched) { _, new in new }

        scored = shortlist.map { candidate in
            score(candidate.entry, feature: features[candidate.entry.track.id], centroid: centroid,
                  seedArtistIDs: seedArtistIDs, similarArtistIDs: similarArtistIDs)
        }
        scored.sort { $0.score > $1.score }

        let preset = RecommendationMath.presets[diversity] ?? RecommendationMath.presets["balanced"]!
        // Cold start: with no taste picture yet, lean harder on exploration.
        let exploreRatio = positive.count < 3 ? 0.35 : preset.exploreRatio

        let candidates = scored.map { candidate -> RecommendationMath.Candidate in
            let feature = features[candidate.entry.track.id]
            return RecommendationMath.Candidate(
                id: candidate.entry.track.id,
                score: candidate.score,
                tags: feature?.tags ?? [:],
                bpm: feature?.bpm,
                artistID: candidate.entry.track.artist.id,
                albumID: candidate.entry.track.album?.id,
                isExplore: !knownArtists.contains(candidate.entry.track.artist.id)
            )
        }

        let tail = queueTail.map { track in
            RecommendationMath.Candidate(
                id: track.id, score: 0, tags: memoryFeatures[track.id]?.tags ?? [:],
                bpm: track.bpm, artistID: track.artist.id, albumID: track.album?.id, isExplore: false)
        }

        let picked = RecommendationMath.selectDiverse(
            candidates, count: count, queueTail: tail,
            lambda: preset.lambda, exploreRatio: exploreRatio)

        await store.flush()

        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.track.id, $0.track) })
        return picked.compactMap { candidate in
            guard var track = byID[candidate.id] else { return nil }
            if let feature = features[candidate.id] {
                track.bpm = feature.bpm ?? track.bpm
            }
            return track
        }
    }

    // MARK: Recall

    private func recall(seeds: [Track],
                        centroid: Centroid,
                        exclude: Set<String>) async -> [PoolEntry] {
        var pool: [String: PoolEntry] = [:]

        func add(_ tracks: [Track], _ source: Source) {
            for track in tracks {
                guard !exclude.contains(track.id), !track.isPodcast else { continue }
                // Two skips of an artist's autoplay picks takes them out entirely.
                guard (skippedArtists[track.artist.id] ?? 0) < 2 else { continue }
                if var existing = pool[track.id] {
                    existing.sources.insert(source)
                    pool[track.id] = existing
                } else {
                    pool[track.id] = PoolEntry(track: track, sources: [source])
                }
            }
        }

        async let radio = tidalRadio(seeds: Array(seeds.prefix(3)))
        async let similar = similarArtistTracks(seeds: Array(seeds.prefix(2)))
        async let lastFmSimilar = lastFmSimilarTracks(seeds: Array(seeds.prefix(2)))

        add(await radio, .tidalRadio)
        add(await similar, .similarArtist)
        add(await lastFmSimilar, .lastfmSimilar)

        // Tag radio is expensive, so it only runs when the cheaper sources fell short.
        if pool.count < 40 {
            add(await lastFmTagTracks(centroid: centroid), .lastfmTag)
        }

        return Array(pool.values)
    }

    private func tidalRadio(seeds: [Track]) async -> [Track] {
        await withTaskGroup(of: [Track].self) { group in
            for seed in seeds {
                group.addTask { [service] in
                    (try? await service.recommendations(for: seed.playbackID)) ?? []
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }

    private func similarArtistTracks(seeds: [Track]) async -> [Track] {
        let artistIDs = Array(Set(seeds.map(\.artist.id))).prefix(2)
        var similarIDs: [String] = []
        for artistID in artistIDs {
            let artists = (try? await service.similarArtists(for: rawID(artistID))) ?? []
            similarIDs += artists.prefix(4).map(\.id)
        }
        guard !similarIDs.isEmpty else { return [] }

        return await withTaskGroup(of: [Track].self) { group in
            for artistID in Array(Set(similarIDs)).prefix(6) {
                group.addTask { [service] in
                    (try? await service.artistTopTracks(for: artistID, limit: 10)) ?? []
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }

    private func lastFmSimilarTracks(seeds: [Track]) async -> [Track] {
        guard await lastFm.isAvailable else { return [] }
        var wanted: [(artist: String, title: String, match: Double)] = []
        for seed in seeds {
            wanted += await lastFm.similarTracks(artist: seed.artist.name, title: seed.title)
        }
        wanted.sort { $0.match > $1.match }
        return await resolve(Array(wanted.prefix(maxResolutions)))
    }

    private func lastFmTagTracks(centroid: Centroid) async -> [Track] {
        guard await lastFm.isAvailable else { return [] }
        let tags = RecommendationMath.topKeys(centroid.tags, 2)
        guard !tags.isEmpty else { return [] }

        var wanted: [(artist: String, title: String, match: Double)] = []
        for tag in tags { wanted += await lastFm.tagTopTracks(tag: tag) }
        return await resolve(Array(wanted.prefix(maxResolutions)))
    }

    /// Turns Last.fm artist/title strings into catalog tracks, accepting only an
    /// exact normalized match - looser matching pulls in covers and karaoke.
    private func resolve(_ wanted: [(artist: String, title: String, match: Double)]) async -> [Track] {
        var resolved: [Track] = []

        for item in wanted {
            let key = RecommendationMath.resolveKey(artist: item.artist, title: item.title)
            guard !unresolvable.contains(key) else { continue }

            let results = await service.searchTrack(artist: item.artist, title: item.title)
            let wantArtist = RecommendationMath.normalizeForResolution(item.artist)
            let wantTitle = RecommendationMath.normalizeForResolution(item.title)

            let match = results.prefix(5).first {
                RecommendationMath.normalizeForResolution($0.title) == wantTitle
                    && RecommendationMath.normalizeForResolution($0.artist.name) == wantArtist
            }

            if let match {
                resolved.append(match)
            } else {
                unresolvable.insert(key)
            }
        }

        return resolved
    }

    /// Collapses album/single/remaster variants of one recording, keeping the most
    /// popular instance and merging its recall sources.
    private func dedupeVariants(_ pool: [PoolEntry]) -> [PoolEntry] {
        var byRecording: [String: PoolEntry] = [:]
        for entry in pool {
            let key = RecommendationMath.resolveKey(artist: entry.track.artist.name, title: entry.track.title)
            guard var existing = byRecording[key] else {
                byRecording[key] = entry
                continue
            }
            existing.sources.formUnion(entry.sources)
            if (entry.track.popularity ?? 0) > (existing.track.popularity ?? 0) {
                existing.track = entry.track
            }
            byRecording[key] = existing
        }
        return Array(byRecording.values)
    }

    private func similarArtistIDs(for seeds: [Track]) async -> Set<String> {
        var ids: Set<String> = []
        for artistID in Set(seeds.map(\.artist.id)).prefix(2) {
            let artists = (try? await service.similarArtists(for: rawID(artistID))) ?? []
            ids.formUnion(artists.map(\.id))
        }
        return ids
    }

    private func rawID(_ id: String) -> String {
        id.split(separator: ":").last.map(String.init) ?? id
    }

    // MARK: Features

    private func baseFeature(for track: Track) -> TrackFeature {
        TrackFeature(
            id: track.id,
            bpm: track.bpm,
            camelot: track.camelot,
            artistID: track.artist.id,
            albumID: track.album?.id,
            releaseYear: track.releaseYear,
            popBand: RecommendationMath.popBand(track.popularity),
            durBandIndex: RecommendationMath.durBandIndex(track.duration),
            hasAudio: track.bpm != nil || track.camelot != nil
        )
    }

    private func tagFeatures(for tracks: [Track]) async -> [String: TrackFeature] {
        var out: [String: TrackFeature] = [:]
        var needsLookup: [Track] = []

        for track in tracks {
            if let cached = memoryFeatures[track.id] ?? (await store.feature(track.id)) {
                out[track.id] = cached
                memoryFeatures[track.id] = cached
            } else {
                out[track.id] = baseFeature(for: track)
                needsLookup.append(track)
            }
        }

        guard await lastFm.isAvailable else { return out }

        var artistTagCache: [String: [(name: String, count: Int)]] = [:]

        for track in needsLookup.prefix(maxTagLookups) {
            let trackTags = await lastFm.trackTopTags(artist: track.artist.name, title: track.title)

            let artistKey = RecommendationMath.normalizeForResolution(track.artist.name)
            let artistTags: [(name: String, count: Int)]
            if let cached = artistTagCache[artistKey] {
                artistTags = cached
            } else {
                artistTags = await lastFm.artistTopTags(artist: track.artist.name)
                artistTagCache[artistKey] = artistTags
            }

            var feature = out[track.id] ?? baseFeature(for: track)
            feature.tags = RecommendationMath.buildTagVector(trackTags: trackTags, artistTags: artistTags)
            let energy = RecommendationMath.energy(from: feature.tags)
            feature.energy = energy.energy
            feature.energyConfidence = energy.confidence
            feature.hasTags = !feature.tags.isEmpty
            feature.fetchedAt = Date().timeIntervalSince1970

            out[track.id] = feature
            memoryFeatures[track.id] = feature
            await store.store(feature)
        }

        return out
    }

    /// Fills in real BPM and musical key for the shortlist only. Candidates that
    /// already carry them - album and mix payloads embed the full track - cost
    /// nothing.
    private func enrichAudio(_ entries: [PoolEntry], features: [String: TrackFeature]) async -> [String: TrackFeature] {
        var out: [String: TrackFeature] = [:]

        for entry in entries {
            var feature = features[entry.track.id] ?? baseFeature(for: entry.track)
            guard !feature.hasAudio else { continue }

            guard let full = try? await service.trackInfo(id: entry.track.playbackID) else {
                continue
            }

            feature.bpm = full.bpm
            feature.camelot = full.camelot
            feature.popBand = RecommendationMath.popBand(full.popularity) ?? feature.popBand
            feature.releaseYear = full.releaseYear ?? feature.releaseYear
            feature.hasAudio = full.bpm != nil || full.camelot != nil
            feature.fetchedAt = Date().timeIntervalSince1970

            out[entry.track.id] = feature
            memoryFeatures[entry.track.id] = feature
            await store.store(feature)
        }

        return out
    }

    // MARK: Centroid

    private struct Centroid {
        var tags: [String: Double] = [:]
        var negativeTags: [String: Double] = [:]
        var camelot: String?
        var meanBpm: Double?
        var meanYear: Double?
        var meanPopBand: Double?
        var meanEnergy: Double?
        var meanDurBandIndex: Double?
    }

    private func buildCentroid(seeds: [Track]) async -> Centroid {
        // Cold start: nothing played yet, so the queue itself defines the mood.
        var entries = positive
        if entries.isEmpty {
            entries = seeds.map { memoryFeatures[$0.id] ?? baseFeature(for: $0) }
        }

        var centroid = Centroid()
        var bpm = (0.0, 0.0), year = (0.0, 0.0), pop = (0.0, 0.0)
        var energy = (0.0, 0.0), duration = (0.0, 0.0)

        for (index, entry) in entries.enumerated() {
            let weight = pow(0.93, Double(index))
            RecommendationMath.addScaled(&centroid.tags, entry.tags, weight)

            func accumulate(_ bucket: inout (Double, Double), _ value: Double?) {
                guard let value else { return }
                bucket.0 += value * weight
                bucket.1 += weight
            }
            accumulate(&bpm, entry.bpm)
            accumulate(&year, entry.releaseYear.map(Double.init))
            accumulate(&pop, entry.popBand.map(Double.init))
            accumulate(&energy, entry.energyConfidence > 0 ? entry.energy : nil)
            accumulate(&duration, entry.durBandIndex.map(Double.init))
        }

        for (index, entry) in negative.enumerated() {
            RecommendationMath.addScaled(&centroid.negativeTags, entry.tags, pow(0.93, Double(index)))
        }

        func mean(_ bucket: (Double, Double)) -> Double? { bucket.1 > 0 ? bucket.0 / bucket.1 : nil }

        centroid.tags = RecommendationMath.l2Normalize(centroid.tags)
        centroid.negativeTags = RecommendationMath.l2Normalize(centroid.negativeTags)
        centroid.camelot = entries.first(where: { $0.camelot != nil })?.camelot
        centroid.meanBpm = mean(bpm)
        centroid.meanYear = mean(year)
        centroid.meanPopBand = mean(pop)
        centroid.meanEnergy = mean(energy)
        centroid.meanDurBandIndex = mean(duration)
        return centroid
    }

    // MARK: Scoring

    private struct ScoredEntry {
        var entry: PoolEntry
        var score: Double
    }

    private func score(_ entry: PoolEntry,
                       feature: TrackFeature?,
                       centroid: Centroid,
                       seedArtistIDs: Set<String>,
                       similarArtistIDs: Set<String>) -> ScoredEntry {
        let feature = feature ?? baseFeature(for: entry.track)
        let artistID = entry.track.artist.id

        let tagSimilarity: Double? = (feature.tags.isEmpty || centroid.tags.isEmpty)
            ? nil
            : RecommendationMath.cosine(feature.tags, centroid.tags)

        var artistProximity = 0.0
        if similarArtistIDs.contains(rawID(artistID)) || similarArtistIDs.contains(artistID) {
            artistProximity = max(artistProximity, 0.55)
        }
        if seedArtistIDs.contains(artistID) { artistProximity = max(artistProximity, 0.35) }
        if knownArtists.contains(artistID) { artistProximity = max(artistProximity, 0.6) }

        // Agreement between independent recall sources is genuine signal.
        let maxPrior = entry.sources.map(\.prior).max() ?? 0.5
        let sourcePrior = min(1, maxPrior + 0.15 * Double(entry.sources.count - 1))

        let terms: [String: Double?] = [
            "tagSimilarity": tagSimilarity,
            "bpmProximity": RecommendationMath.bpmProximity(feature.bpm, centroid.meanBpm),
            "harmonicFit": RecommendationMath.harmonicFit(feature.camelot, centroid.camelot),
            "artistProximity": artistProximity,
            "taste": knownArtists.contains(artistID) ? 0.7 : 0.5,
            "eraProximity": RecommendationMath.eraProximity(feature.releaseYear, centroid.meanYear),
            "popProximity": RecommendationMath.popProximity(feature.popBand, centroid.meanPopBand),
            "sourcePrior": sourcePrior,
            "energyProximity": RecommendationMath.energyProximity(
                feature.energy, confidence: feature.energyConfidence, centroid.meanEnergy),
            "durProximity": RecommendationMath.durProximity(feature.durBandIndex, centroid.meanDurBandIndex),
        ]

        let penalties: [String: Double] = [
            "dislikeSimilarity": feature.tags.isEmpty
                ? 0 : RecommendationMath.cosine(feature.tags, centroid.negativeTags),
            "artistPenalty": min(1, Double(skippedArtists[artistID] ?? 0) / 2),
        ]

        var value = RecommendationMath.combine(terms: terms, penalties: penalties)

        // Tags of just-skipped tracks are damped harder than the smoothed negative
        // centroid manages on its own.
        let skippedMatches = feature.tags.keys.filter { skippedTags.contains($0) }.count
        value -= 0.08 * Double(skippedMatches)

        return ScoredEntry(entry: entry, score: max(-1, value))
    }
}
