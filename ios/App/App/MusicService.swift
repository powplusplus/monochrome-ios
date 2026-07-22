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
        "https://arran.monochrome.tf", "https://triton.squid.wtf", "https://wolf.qqdl.site",
        "https://maus.qqdl.site", "https://vogel.qqdl.site", "https://hund.qqdl.site", "https://hifi.p1nkhamster.com"
    ]
    private let cache = NSCache<NSString, NSData>()

    init(session: URLSession = .shared) { self.session = session }

    func search(_ query: String) async throws -> SearchResults {
        let object = try await json(path: "/search/?q=\(query.urlQueryEncoded)")
        let root = ModelMapper.unwrap(object)
        let dict = root as? [String: Any] ?? [:]
        var results = SearchResults()
        results.tracks = ModelMapper.array(dict["tracks"] as Any, keys: ["items"]).compactMap(ModelMapper.track)
        results.albums = ModelMapper.array(dict["albums"] as Any, keys: ["items"]).compactMap(ModelMapper.album)
        results.artists = ModelMapper.array(dict["artists"] as Any, keys: ["items"]).map { ModelMapper.artist($0) }
        results.playlists = ModelMapper.array(dict["playlists"] as Any, keys: ["items"]).compactMap { item in
            guard let id = ModelMapper.string(item, ["id", "uuid"]), let title = ModelMapper.string(item, ["title", "name"]) else { return nil }
            return Playlist(id: id, title: title, description: ModelMapper.string(item, ["description"]), cover: ModelMapper.string(item, ["squareImage", "cover", "image"]), creator: nil, tracks: [])
        }
        if results.tracks.isEmpty && results.albums.isEmpty {
            results.tracks = ModelMapper.array(root, keys: ["items"]).compactMap(ModelMapper.track)
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

    func album(id: String) async throws -> Album {
        let object = try await json(path: "/album/?id=\(id.urlQueryEncoded)")
        let root = ModelMapper.unwrap(object)
        if let dict = root as? [String: Any], let album = ModelMapper.album(dict) { return album }
        if let dict = ModelMapper.array(root).first, let album = ModelMapper.album(dict) { return album }
        throw ServiceError.malformed("album")
    }

    func recommendations(for trackID: String) async throws -> [Track] {
        let object = try await json(path: "/recommendations/?id=\(trackID.urlQueryEncoded)")
        return ModelMapper.array(object, keys: ["tracks", "items"]).compactMap(ModelMapper.track)
    }

    func resolveStream(for track: Track, quality: String = "LOSSLESS") async throws -> StreamResponse {
        if let url = track.streamURL { return StreamResponse(url: url, provider: track.provider, quality: quality, replayGain: nil, peak: nil) }
        let formats = quality == "HI_RES_LOSSLESS" ? ["FLAC", "MQA", "AACLC"] : ["FLAC", "AACLC"]
        var query = "id=\(track.playbackID.urlQueryEncoded)&quality=\(quality)&adaptive=false"
        formats.forEach { query += "&formats=\($0)" }
        let object = try await json(path: "/trackManifests/?\(query)", streaming: true, cacheable: false)
        guard let manifest = findValue(named: "manifest", in: object) as? String,
              let url = extractURL(fromManifest: manifest) else {
            throw ServiceError.unavailable("No playable stream was returned by the configured providers.")
        }
        let gain = (findValue(named: "replayGain", in: object) as? NSNumber)?.doubleValue
        let peak = (findValue(named: "peakAmplitude", in: object) as? NSNumber)?.doubleValue
        return StreamResponse(url: url, provider: track.provider, quality: quality, replayGain: gain, peak: peak)
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
}

private extension String {
    var urlQueryEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self }
}
