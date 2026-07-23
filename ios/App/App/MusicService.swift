import Foundation

final class MusicService {
    static let shared = MusicService()

    private let session: URLSession
    private let apiInstances = [
        "https://eu-central.monochrome.tf", "https://us-west.monochrome.tf",
        "https://arran.monochrome.tf", "https://api.monochrome.tf",
        "https://monochrome-api.samidy.com", "https://triton.squid.wtf",
        "https://wolf.qqdl.site", "https://maus.qqdl.site", "https://vogel.qqdl.site", "https://hund.qqdl.site"
    ]
    private let streamInstances = [
        "https://eu-central.monochrome.tf", "https://us-west.monochrome.tf",
        "https://arran.monochrome.tf", "https://triton.squid.wtf", "https://wolf.qqdl.site",
        "https://maus.qqdl.site", "https://vogel.qqdl.site", "https://hund.qqdl.site", "https://hifi.p1nkhamster.com"
    ]
    private let cache = NSCache<NSString, NSData>()

    init(session: URLSession = .shared) { self.session = session }

    func search(_ query: String) async throws -> SearchResults {
        // The combined `?q=` route is not supported by every HiFi instance. The
        // web client already treats the scoped routes as the compatibility
        // contract, so native search does the same.
        async let trackObject = scopedSearch(path: "/search/?s=\(query.urlQueryEncoded)")
        async let albumObject = scopedSearch(path: "/search/?al=\(query.urlQueryEncoded)")
        async let artistObject = scopedSearch(path: "/search/?a=\(query.urlQueryEncoded)")
        async let playlistObject = scopedSearch(path: "/search/?p=\(query.urlQueryEncoded)")
        let objects = await (trackObject, albumObject, artistObject, playlistObject)
        var results = SearchResults()
        results.tracks = sectionItems(in: objects.0, named: "tracks").compactMap(ModelMapper.track)
        results.albums = sectionItems(in: objects.1, named: "albums").compactMap(ModelMapper.album)
        results.artists = sectionItems(in: objects.2, named: "artists").map { ModelMapper.artist($0) }
        results.playlists = sectionItems(in: objects.3, named: "playlists").compactMap { item in
            guard let id = ModelMapper.string(item, ["id", "uuid"]), let title = ModelMapper.string(item, ["title", "name"]) else { return nil }
            return Playlist(id: id, title: title, description: ModelMapper.string(item, ["description"]), cover: ModelMapper.string(item, ["squareImage", "cover", "image"]), creator: nil, tracks: [])
        }
        guard !results.tracks.isEmpty || !results.albums.isEmpty || !results.artists.isEmpty || !results.playlists.isEmpty else {
            throw ServiceError.unavailable("No search provider returned results. Please try again.")
        }
        return results
    }

    func editorPicks() async throws -> [Album] {
        guard let url = URL(string: "https://monochrome.tf/editors-picks.json") else { throw ServiceError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: data)
        return ModelMapper.array(object, keys: ["albums", "items"]).compactMap(ModelMapper.album)
    }

    func album(id: String, fallback: Album? = nil) async throws -> Album {
        let encodedID = id.urlQueryEncoded
        for path in ["/album/?id=\(encodedID)", "/album/?id=\(encodedID)&offset=0&limit=500"] {
            if let object = try? await json(path: path, cacheable: false), let album = mappedAlbum(from: object) { return album }
        }

        // Curated entries can outlive a provider catalog ID. Resolve the same
        // title/artist to its current ID instead of opening a dead album page.
        if let fallback {
            let object = await scopedSearch(path: "/search/?al=\(fallback.title.urlQueryEncoded)")
            let candidates = sectionItems(in: object, named: "albums").compactMap(ModelMapper.album)
            let match = candidates.first {
                $0.title.caseInsensitiveCompare(fallback.title) == .orderedSame &&
                $0.artist.name.caseInsensitiveCompare(fallback.artist.name) == .orderedSame
            } ?? candidates.first { $0.title.caseInsensitiveCompare(fallback.title) == .orderedSame }
            if let match, match.id != id { return try await album(id: match.id) }
        }
        throw ServiceError.unavailable("This album is no longer available from the configured providers.")
    }

    func recommendations(for trackID: String) async throws -> [Track] {
        let object = try await json(path: "/recommendations/?id=\(trackID.urlQueryEncoded)")
        return ModelMapper.array(object, keys: ["tracks", "items"]).compactMap(ModelMapper.track)
    }

    func resolveStream(for track: Track, quality: String = "HIGH") async throws -> StreamResponse {
        // Catalog payloads often include a webpage `url` (e.g. tidal.com/track/…) that
        // was historically mapped into streamURL. Only short-circuit for real media.
        if let url = track.streamURL, Self.isDirectMediaURL(url) {
            return StreamResponse(url: url, provider: track.provider, quality: quality, replayGain: nil, peak: nil)
        }
        // AVFoundation does not reliably play TIDAL's fragmented-MP4 FLAC
        // representation when it is exposed through a local HLS wrapper. Ask
        // for AAC-LC explicitly; this is iOS's native hardware-decoded path.
        let formats = ["AACLC"]
        var query = "id=\(track.playbackID.urlQueryEncoded)&quality=\(quality)&adaptive=false"
        formats.forEach { query += "&formats=\($0)" }
        let object = try await json(path: "/trackManifests/?\(query)", streaming: true, cacheable: false)
        let url: URL
        if let manifest = findValue(named: "manifest", in: object) as? String,
           let extracted = extractURL(fromManifest: manifest) { url = extracted }
        else if let uri = findValue(named: "uri", in: object) as? String,
                let manifestURL = URL(string: uri) { url = try await playableURL(from: manifestURL) }
        else { throw ServiceError.unavailable("No playable stream was returned by the configured providers.") }
        let gain = (findValue(named: "replayGain", in: object) as? NSNumber)?.doubleValue
        let peak = (findValue(named: "peakAmplitude", in: object) as? NSNumber)?.doubleValue
        return StreamResponse(url: url, provider: track.provider, quality: quality, replayGain: gain, peak: peak)
    }

    private static func isDirectMediaURL(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        let ext = url.pathExtension.lowercased()
        return ["m4a", "mp3", "aac", "flac", "ogg", "wav", "mp4", "m3u8", "mpd"].contains(ext)
    }

    private func json(path: String, streaming: Bool = false, cacheable: Bool = true) async throws -> Any {
        let cacheKey = path as NSString
        if cacheable, let data = cache.object(forKey: cacheKey) { return try JSONSerialization.jsonObject(with: data as Data) }
        let bases = streaming ? streamInstances : apiInstances
        var latestError: Error = ServiceError.invalidResponse
        for base in bases {
            guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { continue }
            do {
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: streaming ? 8 : 12)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                try validate(response)
                let object = try JSONSerialization.jsonObject(with: data)
                if cacheable { cache.setObject(data as NSData, forKey: cacheKey) }
                return object
            } catch { latestError = error }
        }
        throw latestError
    }

    private func scopedSearch(path: String) async -> Any? { try? await json(path: path, cacheable: false) }

    private func sectionItems(in object: Any?, named section: String) -> [[String: Any]] {
        guard let object else { return [] }
        let root = (object as? [String: Any])?["data"] ?? object
        if let dict = root as? [String: Any] {
            if let value = dict[section] { return itemArray(value) }
            if dict["items"] != nil { return itemArray(dict) }
            for value in dict.values {
                let nested = sectionItems(in: value, named: section)
                if !nested.isEmpty { return nested }
            }
        }
        return itemArray(root)
    }

    private func itemArray(_ value: Any) -> [[String: Any]] {
        let unwrapped = (value as? [String: Any])?["items"] ?? value
        guard let values = unwrapped as? [Any] else { return [] }
        return values.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            return (dict["item"] ?? dict["track"] ?? dict["value"]) as? [String: Any] ?? dict
        }
    }

    private func mappedAlbum(from object: Any) -> Album? {
        let root = (object as? [String: Any])?["data"] ?? object
        guard let dict = root as? [String: Any], var album = ModelMapper.album(dict) else { return nil }
        let tracks = itemArray(dict).compactMap(ModelMapper.track)
        if !tracks.isEmpty { album.tracks = tracks }
        return album
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
    }

    private func findValue(named key: String, in value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if let found = dict[key] { return found }
            for nested in dict.values { if let found = findValue(named: key, in: nested) { return found } }
        } else if let array = value as? [Any] {
            for nested in array { if let found = findValue(named: key, in: nested) { return found } }
        }
        return nil
    }

    private func extractURL(fromManifest manifest: String) -> URL? {
        let decodedData = Data(base64Encoded: manifest, options: .ignoreUnknownCharacters)
        let decoded = decodedData.flatMap { String(data: $0, encoding: .utf8) } ?? manifest
        if let data = decoded.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urls = json["urls"] as? [String] {
            return urls.compactMap(URL.init(string:)).first
        }
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\\\"'<>]+"),
              let match = regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
              let range = Range(match.range, in: decoded) else { return nil }
        return URL(string: String(decoded[range]))
    }

    /// AVPlayer doesn't accept MPEG-DASH directly. HiFi's fixed manifests are
    /// static fragmented-MP4 timelines, so join the initialization fragment and
    /// media fragments into one local fragmented MP4 that AVFoundation can open
    /// without waiting on a synthetic local HLS playlist.
    private func playableURL(from manifestURL: URL) async throws -> URL {
        let (data, response) = try await session.data(from: manifestURL)
        try validate(response)
        guard let xml = String(data: data, encoding: .utf8) else { throw ServiceError.malformed("stream manifest") }
        if xml.contains("#EXTM3U") { return manifestURL }
        guard let initialization = attribute("initialization", in: xml),
              let media = attribute("media", in: xml),
              attribute("timescale", in: xml) != nil else {
            throw ServiceError.malformed("DASH audio timeline")
        }
        let startNumber = Int(attribute("startNumber", in: xml) ?? "1") ?? 1
        let segmentPattern = #"<S\s+([^>]+)/?>"#
        let regex = try NSRegularExpression(pattern: segmentPattern)
        let nsRange = NSRange(xml.startIndex..., in: xml)
        var segmentCount = 0
        for match in regex.matches(in: xml, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let attributes = String(xml[range])
            guard attribute("d", in: attributes) != nil else { continue }
            let repeats = max(0, Int(attribute("r", in: attributes) ?? "0") ?? 0)
            segmentCount += repeats + 1
        }
        guard segmentCount > 0 else { throw ServiceError.malformed("DASH segment timeline") }
        guard let initURL = URL(string: xmlDecoded(initialization), relativeTo: manifestURL)?.absoluteURL else {
            throw ServiceError.malformed("DASH initialization URL")
        }
        let mediaTemplate = xmlDecoded(media)
        var combined = try await fragmentData(from: initURL)
        for offset in 0..<segmentCount {
            let segment = mediaTemplate.replacingOccurrences(of: "$Number$", with: String(startNumber + offset))
            guard let segmentURL = URL(string: segment, relativeTo: manifestURL)?.absoluteURL else {
                throw ServiceError.malformed("DASH media URL")
            }
            combined.append(try await fragmentData(from: segmentURL))
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("monochrome-\(UUID().uuidString).m4a")
        try combined.write(to: target, options: .atomic)
        return target
    }

    private func fragmentData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("audio/mp4", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard !data.isEmpty else { throw ServiceError.malformed("empty audio fragment") }
        return data
    }

    private func attribute(_ name: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))=['\\\"]([^'\\\"]+)['\\\"]"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func xmlDecoded(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

private extension String {
    var urlQueryEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self }
}
