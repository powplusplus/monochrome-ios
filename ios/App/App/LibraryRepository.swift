import CoreData
import Foundation
import WebKit

@MainActor
final class LibraryRepository: ObservableObject {
    static let shared = LibraryRepository()

    @Published private(set) var favorites: [Track] = []
    @Published private(set) var history: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var migrationState: MigrationState = .notStarted
    @Published private(set) var cloudSyncState: CloudSyncState = .idle

    enum MigrationState: Equatable { case notStarted, running, complete, failed(String) }
    enum CloudSyncState: Equatable { case idle, syncing, complete, failed(String) }

    private let container: NSPersistentContainer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var migrationBridge: LegacyMigrationBridge?

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
        let playlist = Playlist(id: UUID().uuidString, title: name, description: nil, cover: tracks.first?.album?.cover, creator: "You", tracks: tracks)
        playlists.insert(playlist, at: 0)
        upsert(playlist, key: playlist.id, kind: "playlist")
        save()
        scheduleCloudUpload()
    }

    func add(_ track: Track, to playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[index].tracks.contains(where: { $0.id == track.id }) { playlists[index].tracks.append(track) }
        upsert(playlists[index], key: playlistID, kind: "playlist")
        save()
        scheduleCloudUpload()
    }

    func removeFavorite(at offsets: IndexSet) {
        for index in offsets { if favorites.indices.contains(index) { delete(key: favorites[index].id, kind: "favorite") } }
        favorites.remove(atOffsets: offsets); save()
    }

    func migrateLegacyIfNeeded(force: Bool = false) {
        guard force || !UserDefaults.standard.bool(forKey: "nativeLegacyMigrationComplete") else { migrationState = .complete; return }
        guard migrationState != .running else { return }
        migrationState = .running
        let bridge = LegacyMigrationBridge()
        migrationBridge = bridge
        bridge.export { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.migrationBridge = nil
                switch result {
                case .success(let snapshot):
                    do {
                        try self.importSnapshot(snapshot)
                        try self.container.viewContext.save()
                        UserDefaults.standard.set(true, forKey: "nativeLegacyMigrationComplete")
                        self.load(); self.migrationState = .complete
                    } catch {
                        self.container.viewContext.rollback()
                        self.migrationState = .failed(error.localizedDescription)
                    }
                case .failure(let error):
                    self.migrationState = .failed(error.localizedDescription)
                }
            }
        }
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
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ServiceError.authenticationRequired
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let remote = recordMap(root["userPlaylists"] ?? root["user_playlists"])
            for (key, value) in remote {
                guard let title = ModelMapper.string(value, ["name", "title"]) else { continue }
                let id = ModelMapper.string(value, ["id", "uuid"]) ?? key
                let tracks = ModelMapper.array(value["tracks"] as Any, keys: ["items"]).compactMap(ModelMapper.track)
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

    private func importSnapshot(_ snapshot: LegacySnapshot) throws {
        for object in snapshot.favorites {
            if let track = ModelMapper.track(object) { upsert(track, key: track.id, kind: "favorite") }
        }
        for object in snapshot.history {
            if let track = ModelMapper.track(object) { upsert(track, key: track.id, kind: "history") }
        }
        for object in snapshot.playlists {
            guard let id = ModelMapper.string(object, ["id", "uuid"]), let title = ModelMapper.string(object, ["title", "name"]) else { continue }
            let tracks = ModelMapper.array(object["tracks"] as Any, keys: ["items"]).compactMap(ModelMapper.track)
            upsert(Playlist(id: id, title: title, description: ModelMapper.string(object, ["description"]), cover: ModelMapper.string(object, ["cover"]), creator: "You", tracks: tracks), key: id, kind: "playlist")
        }
        for (key, value) in snapshot.settings { UserDefaults.standard.set(value, forKey: "legacy.\(key)") }
    }
}

struct LegacySnapshot {
    var favorites: [[String: Any]] = []
    var history: [[String: Any]] = []
    var playlists: [[String: Any]] = []
    var settings: [String: Any] = [:]
}

final class LegacyMigrationBridge: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: ((Result<LegacySnapshot, Error>) -> Void)?

    func export(completion: @escaping (Result<LegacySnapshot, Error>) -> Void) {
        self.completion = completion
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; webView = view
        guard let url = URL(string: "https://monochrome.tf/") else { completion(.failure(ServiceError.invalidResponse)); return }
        view.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = """
        const out={favorites:[],history:[],playlists:[],settings:{}};
        try{for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i),v=localStorage.getItem(k);try{out.settings[k]=JSON.parse(v)}catch{out.settings[k]=v}}}catch{}
        try{const db=await new Promise((ok,no)=>{const r=indexedDB.open('MonochromeDB');r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error)});
        const read=(n)=>new Promise(ok=>{if(!db.objectStoreNames.contains(n))return ok([]);const r=db.transaction(n).objectStore(n).getAll();r.onsuccess=()=>ok(r.result||[]);r.onerror=()=>ok([])});
        out.favorites=await read('favorites_tracks');out.history=await read('history_tracks');out.playlists=await read('user_playlists')}catch{}
        return JSON.stringify(out)
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) { [weak self] result in
            guard let self else { return }
            defer { self.webView = nil; self.completion = nil }
            let value: Any
            switch result {
            case .success(let output): value = output
            case .failure(let error): self.completion?(.failure(error)); return
            }
            guard let string = value as? String, let data = string.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.completion?(.failure(ServiceError.malformed("legacy store"))); return
            }
            self.completion?(.success(LegacySnapshot(favorites: dict["favorites"] as? [[String: Any]] ?? [], history: dict["history"] as? [[String: Any]] ?? [], playlists: dict["playlists"] as? [[String: Any]] ?? [], settings: dict["settings"] as? [String: Any] ?? [:])))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completion?(.failure(error)); self.webView = nil; completion = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completion?(.failure(error)); self.webView = nil; completion = nil }
}
