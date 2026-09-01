import CoreData
import Foundation

@MainActor
final class LibraryRepository: ObservableObject {
    static let shared = LibraryRepository()

    @Published private(set) var favorites: [Track] = []
    @Published private(set) var history: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var cloudSyncState: CloudSyncState = .idle
    @Published var playlistToast: PlaylistAddToast?

    enum CloudSyncState: Equatable { case idle, syncing, complete, failed(String) }

    private let container: NSPersistentContainer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lastPlaylistKey = "native.lastPlaylistID"
    private var toastDismissTask: Task<Void, Never>?

    init(inMemory: Bool = false) {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "LibraryRecord"
        entity.managedObjectClassName = "NSManagedObject"
        let key = NSAttributeDescription(); key.name = "key"; key.attributeType = .stringAttributeType; key.isOptional = false
        let kind = NSAttributeDescription(); kind.name = "kind"; kind.attributeType = .stringAttributeType; kind.isOptional = false
        let payload = NSAttributeDescription(); payload.name = "payload"; payload.attributeType = .binaryDataAttributeType; payload.isOptional = false
        let date = NSAttributeDescription(); date.name = "updatedAt"; date.attributeType = .dateAttributeType; date.isOptional = false
        entity.properties = [key, kind, payload, date]
        model.entities = [entity]

        container = NSPersistentContainer(name: "Monochrome", managedObjectModel: model)
        if inMemory { container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null") }
        container.loadPersistentStores { _, error in
            if let error { print("[CoreData] \(error.localizedDescription)") }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        load()
    }

    func toggleFavorite(_ track: Track) {
        guard !track.isPodcast else { return }
        if favorites.contains(where: { $0.id == track.id }) {
            favorites.removeAll { $0.id == track.id }; delete(key: track.id, kind: "favorite")
        } else {
            favorites.insert(track, at: 0); upsert(track, key: track.id, kind: "favorite")
        }
        save()
    }

    func isFavorite(_ track: Track) -> Bool { favorites.contains { $0.id == track.id } }

    func recordPlayback(_ track: Track) {
        history.removeAll { $0.id == track.id }
        history.insert(track, at: 0)
        if history.count > 250 { history.removeLast(history.count - 250) }
        upsert(track, key: track.id, kind: "history")
        save()
    }

    func createPlaylist(named name: String, tracks: [Track] = []) {
        let filtered = tracks.filter { !$0.isPodcast }
        let playlist = Playlist(id: UUID().uuidString, title: name, description: nil, cover: filtered.first?.album?.cover, creator: "You", tracks: filtered)
        playlists.insert(playlist, at: 0)
        upsert(playlist, key: playlist.id, kind: "playlist")
        save()
        scheduleCloudUpload()
    }

    func add(_ track: Track, to playlistID: String) {
        guard !track.isPodcast else { return }
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[index].tracks.contains(where: { $0.id == track.id }) { playlists[index].tracks.append(track) }
        upsert(playlists[index], key: playlistID, kind: "playlist")
        save()
        scheduleCloudUpload()
    }

    func remove(_ track: Track, from playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].tracks.removeAll { $0.id == track.id }
        upsert(playlists[index], key: playlistID, kind: "playlist")
        save()
        scheduleCloudUpload()
    }

    /// Preferred playlist for one-tap add: last chosen, else first.
    var preferredPlaylist: Playlist? {
        if let last = UserDefaults.standard.string(forKey: lastPlaylistKey),
           let match = playlists.first(where: { $0.id == last }) {
            return match
        }
        return playlists.first
    }

    /// One-tap add → toast with Change. Returns false when no playlists exist.
    @discardableResult
    func quickAddToPlaylist(_ track: Track) -> Bool {
        guard !track.isPodcast else { return false }
        guard let playlist = preferredPlaylist else { return false }
        add(track, to: playlist.id)
        rememberPlaylist(playlist.id)
        presentToast(track: track, playlist: playlist)
        return true
    }

    /// Show toast + remember without re-adding (e.g. after create-with-track).
    func announceAdded(_ track: Track, to playlistID: String) {
        guard let playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        rememberPlaylist(playlistID)
        presentToast(track: track, playlist: playlist)
    }

    /// Change destination from toast: move track, remember choice, refresh toast.
    func changeToastPlaylist(to playlistID: String) {
        guard let toast = playlistToast,
              let playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        if toast.playlistID != playlistID {
            remove(toast.track, from: toast.playlistID)
            add(toast.track, to: playlistID)
        }
        rememberPlaylist(playlistID)
        presentToast(track: toast.track, playlist: playlist)
    }

    func dismissPlaylistToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        playlistToast = nil
    }

    /// Keep toast up while Change sheet is open.
    func holdPlaylistToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
    }

    private func rememberPlaylist(_ id: String) {
        UserDefaults.standard.set(id, forKey: lastPlaylistKey)
    }

    private func presentToast(track: Track, playlist: Playlist) {
        playlistToast = PlaylistAddToast(track: track, playlistID: playlist.id, playlistTitle: playlist.title)
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.playlistToast = nil }
        }
    }

    func removeFavorite(at offsets: IndexSet) {
        for index in offsets { if favorites.indices.contains(index) { delete(key: favorites[index].id, kind: "favorite") } }
        favorites.remove(atOffsets: offsets); save()
    }

    func syncWithCloud() async {
        guard let token = Keychain.read("bearer") else { cloudSyncState = .idle; return }
        guard cloudSyncState != .syncing else { return }
        cloudSyncState = .syncing
        do {
            var request = URLRequest(url: URL(string: "https://auth.monochrome.tf/api/sync")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            // A bare "sign in required" hid which half failed. 401/403 is the
            // stored bearer being rejected; anything else is the sync endpoint
            // itself, and the difference decides whether signing in again helps.
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw ServiceError.authenticationRequired
                }
                throw ServiceError.unavailable("Playlist sync failed: HTTP \(http.statusCode)")
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            // The server has answered under three names across revisions, and a
            // record can arrive as a map, a list, or a JSON string. Reading only
            // one of those shapes is indistinguishable, on screen, from having
            // no playlists at all.
            let payload = root["userPlaylists"] ?? root["user_playlists"] ?? root["playlists"]
                ?? (root["profile"] as? [String: Any])?["userPlaylists"]
            let remote = recordMap(payload)
            for (key, value) in remote {
                guard let title = ModelMapper.string(value, ["name", "title"]) else { continue }
                let id = ModelMapper.string(value, ["uuid", "id"]) ?? key
                // Web minifies a playlist's tracks into `tracks`; older records
                // nested them under `items`.
                let trackPayload = value["tracks"] ?? value["items"] ?? value["trackList"] ?? []
                let tracks = ModelMapper.array(trackPayload, keys: ["items", "tracks"]).compactMap(ModelMapper.track)
                let playlist = Playlist(id: id, title: title, description: ModelMapper.string(value, ["description"]),
                                        cover: ModelMapper.string(value, ["cover", "image"]), creator: "You", tracks: tracks)
                upsert(playlist, key: id, kind: "playlist")
            }
            try container.viewContext.save()
            load()
            try await uploadPlaylists(token: token)
            cloudSyncState = .complete
        } catch {
            cloudSyncState = .failed(error.localizedDescription)
        }
    }

    private func load() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        guard let records = try? container.viewContext.fetch(request) else { return }
        favorites = records.filter { $0.value(forKey: "kind") as? String == "favorite" }.compactMap { decode(Track.self, from: $0) }
        history = records.filter { $0.value(forKey: "kind") as? String == "history" }.compactMap { decode(Track.self, from: $0) }
        playlists = records.filter { $0.value(forKey: "kind") as? String == "playlist" }.compactMap { decode(Playlist.self, from: $0) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: NSManagedObject) -> T? {
        guard let data = record.value(forKey: "payload") as? Data else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func upsert<T: Encodable>(_ value: T, key: String, kind: String) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryRecord")
        request.predicate = NSPredicate(format: "key == %@ AND kind == %@", key, kind)
        let record = (try? container.viewContext.fetch(request).first) ?? NSEntityDescription.insertNewObject(forEntityName: "LibraryRecord", into: container.viewContext)
        record.setValue(key, forKey: "key"); record.setValue(kind, forKey: "kind")
        record.setValue(try? encoder.encode(value), forKey: "payload"); record.setValue(Date(), forKey: "updatedAt")
    }

    private func delete(key: String, kind: String) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryRecord")
        request.predicate = NSPredicate(format: "key == %@ AND kind == %@", key, kind)
        (try? container.viewContext.fetch(request))?.forEach(container.viewContext.delete)
    }

    private func save() { try? container.viewContext.save() }

    private func scheduleCloudUpload() {
        guard Keychain.read("bearer") != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, let token = Keychain.read("bearer") else { return }
            do { try await self.uploadPlaylists(token: token); self.cloudSyncState = .complete }
            catch { self.cloudSyncState = .failed(error.localizedDescription) }
        }
    }

    private func uploadPlaylists(token: String) async throws {
        var records: [String: Any] = [:]
        for playlist in playlists {
            let trackData = try encoder.encode(playlist.tracks)
            let tracks = try JSONSerialization.jsonObject(with: trackData)
            records[playlist.id] = [
                "id": playlist.id, "name": playlist.title, "title": playlist.title,
                "description": playlist.description ?? "", "cover": (playlist.cover as Any?) ?? NSNull(),
                "tracks": tracks, "numberOfTracks": playlist.tracks.count,
                "updatedAt": Int(Date().timeIntervalSince1970 * 1000)
            ]
        }
        var request = URLRequest(url: URL(string: "https://auth.monochrome.tf/api/sync")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userPlaylists": records])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.authenticationRequired
        }
    }

    private func recordMap(_ value: Any?) -> [String: [String: Any]] {
        var decoded = value
        if let text = value as? String, let data = text.data(using: .utf8) {
            decoded = try? JSONSerialization.jsonObject(with: data)
        }
        if let map = decoded as? [String: [String: Any]] { return map }
        if let list = decoded as? [[String: Any]] {
            return Dictionary(uniqueKeysWithValues: list.compactMap { item in
                guard let id = ModelMapper.string(item, ["id", "uuid"]) else { return nil }
                return (id, item)
            })
        }
        return [:]
    }

}

struct PlaylistAddToast: Equatable {
    let track: Track
    let playlistID: String
    let playlistTitle: String
}
