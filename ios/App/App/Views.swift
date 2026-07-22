import SwiftUI
import AVKit

struct RootView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var selection = 0
    @State private var showPlayer = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                TabView(selection: $selection) {
                    HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
                    LibraryView().tabItem { Label("Library", systemImage: "music.note.list") }.tag(1)
                    SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(2)
                    SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
                }.accentColor(.pink)
                if playback.currentTrack != nil {
                    MiniPlayer(showPlayer: $showPlayer)
                        .padding(.horizontal, 8)
                        .padding(.bottom, geometry.safeAreaInsets.bottom + (geometry.size.width > geometry.size.height ? 36 : 50))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }.ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .sheet(isPresented: $showPlayer) { NowPlayingView() }
        .animation(.easeOut(duration: 0.22), value: playback.currentTrack?.id)
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryRepository
    @State private var picks: [Album] = []
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !library.history.isEmpty { MediaSection(title: "Jump Back In") { HorizontalTrackShelf(tracks: Array(library.history.prefix(12))) } }
                    MediaSection(title: "Editor’s Picks") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(picks) { album in
                                    NavigationLink(destination: AlbumDetailView(albumID: album.id, initial: album)) { AlbumCard(album: album) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal)
                        }
                    }
                    MediaSection(title: "Made for listening") {
                        FeatureCard(icon: "waveform", title: "Lossless, without the wait", subtitle: "Playback starts as soon as a provider resolves. Everything else loads in the background.")
                    }
                }.padding(.vertical, 18).padding(.bottom, 100)
            }
            .navigationTitle("Monochrome")
            .refreshable { await load() }
            .overlay { if isLoading && picks.isEmpty { ProgressView("Loading music…") } }
            .alert("Couldn’t refresh", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK", role: .cancel) {} } message: { Text(message ?? "") }
            .task { if picks.isEmpty { await load() } }
        }.navigationViewStyle(.stack)
    }

    private func load() async {
        isLoading = true
        do { picks = try await MusicService.shared.editorPicks() } catch { message = error.localizedDescription }
        isLoading = false
    }
}

struct SearchView: View {
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        NavigationView {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 42)).foregroundColor(.secondary)
                        Text("Search Monochrome").font(.title2.bold())
                        Text("Find tracks, albums, artists, and playlists.").foregroundColor(.secondary)
                    }.multilineTextAlignment(.center).padding()
                } else if searching { ProgressView("Searching…") }
                else {
                    List {
                        if !results.tracks.isEmpty { Section("Songs") { ForEach(results.tracks) { TrackRow(track: $0, context: results.tracks) } } }
                        if !results.albums.isEmpty { Section("Albums") { ForEach(results.albums) { album in NavigationLink(destination: AlbumDetailView(albumID: album.id, initial: album)) { AlbumListRow(album: album) } } } }
                        if !results.artists.isEmpty { Section("Artists") { ForEach(results.artists) { artist in Label(artist.name, systemImage: "person.crop.circle") } } }
                    }.listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, albums, songs")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { value in if value.isEmpty { results = SearchResults() } }
            .alert("Search failed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK", role: .cancel) {} } message: { Text(message ?? "") }
        }.navigationViewStyle(.stack)
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        do { results = try await MusicService.shared.search(query) } catch { message = error.localizedDescription }
        searching = false
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryRepository
    @State private var name = ""
    @State private var showCreate = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink(destination: TrackCollectionView(title: "Liked Songs", tracks: library.favorites)) { LibraryDestination(icon: "heart.fill", color: .pink, title: "Liked Songs", count: library.favorites.count) }
                    NavigationLink(destination: TrackCollectionView(title: "Recently Played", tracks: library.history)) { LibraryDestination(icon: "clock.fill", color: .purple, title: "Recently Played", count: library.history.count) }
                    NavigationLink(destination: DownloadsView()) { LibraryDestination(icon: "arrow.down.circle.fill", color: .blue, title: "Downloads", count: nil) }
                }
                Section("Playlists") {
                    ForEach(library.playlists) { playlist in NavigationLink(destination: TrackCollectionView(title: playlist.title, tracks: playlist.tracks)) { Label(playlist.title, systemImage: "music.note.list") } }
                    if library.playlists.isEmpty { Text("Your playlists will appear here.").foregroundColor(.secondary) }
                }
            }
            .listStyle(.insetGrouped).navigationTitle("Library").padding(.bottom, 82)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create playlist") } }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Playlist name", text: $name)
                Button("Create") { let value = name.trimmingCharacters(in: .whitespaces); if !value.isEmpty { library.createPlaylist(named: value) }; name = "" }
                Button("Cancel", role: .cancel) { name = "" }
            }
        }.navigationViewStyle(.stack)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var library: LibraryRepository
    @EnvironmentObject private var auth: AuthSession
    @AppStorage("native.darkAppearance") private var darkAppearance = true
    @AppStorage("native.highQuality") private var highQuality = true
    @AppStorage("native.gapless") private var gapless = true

    var body: some View {
        NavigationView {
            Form {
                Section("Account") {
                    if auth.isSignedIn { Label("Signed in", systemImage: "checkmark.circle.fill").foregroundColor(.green); Button("Sign Out", role: .destructive) { auth.signOut() } }
                    else { NavigationLink("Sign in to Monochrome", destination: SignInView()) }
                }
                Section("Appearance") { Toggle("Dark appearance", isOn: $darkAppearance); Label("Uses your system text size", systemImage: "textformat.size") }
                Section("Audio") {
                    Toggle("Prefer lossless", isOn: $highQuality)
                    Toggle("Gapless transitions", isOn: $gapless)
                    Picker("Playback speed", selection: $playback.playbackRate) { Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2)) }
                }
                Section("Services") { NavigationLink("Scrobbling", destination: ScrobblingSettingsView()); NavigationLink("Provider order", destination: ProviderSettingsView()) }
                Section("Data") {
                    HStack { Text("Legacy migration"); Spacer(); migrationLabel }
                    Button("Retry legacy migration") { library.migrateLegacyIfNeeded(force: true) }.disabled(library.migrationState == .running)
                }
                Section { Text("Native SwiftUI · iOS 15+").foregroundColor(.secondary) } footer: { Text("Application screens never load monochrome.tf in a WebView. WebKit is used only for the one-time legacy import and isolated authentication challenges.") }
            }.navigationTitle("Settings")
        }.navigationViewStyle(.stack).preferredColorScheme(darkAppearance ? .dark : nil)
    }

    @ViewBuilder private var migrationLabel: some View {
        switch library.migrationState { case .notStarted: Text("Pending").foregroundColor(.secondary); case .running: ProgressView(); case .complete: Text("Complete").foregroundColor(.green); case .failed: Text("Needs attention").foregroundColor(.orange) }
    }
}

struct AlbumDetailView: View {
    let albumID: String
    let initial: Album
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var album: Album
    @State private var loading = false

    init(albumID: String, initial: Album) { self.albumID = albumID; self.initial = initial; _album = State(initialValue: initial) }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if geometry.size.width > geometry.size.height {
                    HStack(alignment: .top, spacing: 32) { AlbumHero(album: album).frame(width: min(geometry.size.width * 0.38, 320)); trackList }.padding()
                } else { VStack(spacing: 22) { AlbumHero(album: album).padding(.horizontal, 36); trackList }.padding(.vertical) }
            }.padding(.bottom, 90)
        }
        .navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
        .task { guard album.tracks.isEmpty else { return }; loading = true; if let loaded = try? await MusicService.shared.album(id: albumID) { album = loaded }; loading = false }
    }
    private var trackList: some View {
        LazyVStack(spacing: 0) {
            HStack {
                Button { if let first = album.tracks.first { playback.play(first, in: album.tracks) } } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.pink)
                Button { playback.shuffleEnabled = true; if let first = album.tracks.randomElement() { playback.play(first, in: album.tracks) } } label: { Image(systemName: "shuffle") }.buttonStyle(.bordered)
            }.padding()
            if loading { ProgressView().padding() }
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in TrackRow(track: track, context: album.tracks, index: index + 1); Divider().padding(.leading, 48) }
        }
    }
}

struct AlbumHero: View {
    let album: Album
    var body: some View { VStack(spacing: 14) { ArtworkView(url: album.artworkURL).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).shadow(radius: 16, y: 8); Text(album.title).font(.title2.bold()).multilineTextAlignment(.center); Text(album.artist.name).foregroundColor(.pink); if let date = album.releaseDate { Text(date).font(.caption).foregroundColor(.secondary) } } }
}

struct TrackRow: View {
    let track: Track
    var context: [Track]? = nil
    var index: Int? = nil
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var library: LibraryRepository
    var body: some View {
        Button { playback.play(track, in: context) } label: {
            HStack(spacing: 12) {
                if let index { Text("\(index)").font(.callout.monospacedDigit()).foregroundColor(.secondary).frame(width: 26) }
                else { ArtworkView(url: track.artworkURL).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 6)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).lineLimit(1).foregroundColor(.primary)
                    HStack(spacing: 4) { if track.explicit { Text("E").font(.caption2.bold()).padding(.horizontal, 3).background(Color.secondary.opacity(0.25)).cornerRadius(2) }; Text(track.artist.name).lineLimit(1) }.font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if playback.currentTrack?.id == track.id { Image(systemName: playback.isPlaying ? "waveform" : "pause.fill").foregroundColor(.pink) } else { Image(systemName: "ellipsis").foregroundColor(.secondary) }
            }.contentShape(Rectangle()).padding(.vertical, 4)
        }.buttonStyle(.plain)
        .contextMenu {
            Button { playback.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { playback.append(track) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
            Button { library.toggleFavorite(track) } label: { Label(library.isFavorite(track) ? "Unlike" : "Like", systemImage: library.isFavorite(track) ? "heart.slash" : "heart") }
            Button { Task { await DownloadManager.shared.download(track) } } label: { Label("Download", systemImage: "arrow.down.circle") }
        }.accessibilityLabel("\(track.title), by \(track.artist.name)")
    }
}

struct MiniPlayer: View {
    @Binding var showPlayer: Bool
    @EnvironmentObject private var playback: PlaybackEngine
    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 11) {
                ArtworkView(url: playback.currentTrack?.artworkURL).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) { Text(playback.currentTrack?.title ?? "").lineLimit(1).font(.subheadline.weight(.semibold)); Text(playback.currentTrack?.artist.name ?? "").lineLimit(1).font(.caption).foregroundColor(.secondary) }
                Spacer()
                if playback.isLoading { ProgressView().frame(width: 38, height: 38) }
                else { Button { playback.playPause() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 38, height: 38) }.buttonStyle(.plain).accessibilityLabel(playback.isPlaying ? "Pause" : "Play") }
                Button { playback.next() } label: { Image(systemName: "forward.fill").frame(width: 34, height: 38) }.buttonStyle(.plain).accessibilityLabel("Next track")
            }.padding(7).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12))).shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }.buttonStyle(.plain)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var library: LibraryRepository
    @State private var showQueue = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ArtworkView(url: playback.currentTrack?.artworkURL).scaledToFill().blur(radius: 55).opacity(0.28).ignoresSafeArea()
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 42) { artwork.frame(maxWidth: 360); controls }.padding(.horizontal, max(28, geometry.safeAreaInsets.leading + 12)).padding(.vertical, 20)
                } else {
                    VStack(spacing: 0) { Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 38, height: 5).padding(.top, 10); artwork.padding(.horizontal, 36).padding(.top, 28); Spacer(minLength: 20); controls.padding(.horizontal, 28).padding(.bottom, max(18, geometry.safeAreaInsets.bottom)) }
                }
            }
        }.sheet(isPresented: $showQueue) { QueueView() }
    }
    private var artwork: some View { ArtworkView(url: playback.currentTrack?.artworkURL).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).shadow(color: .black.opacity(0.38), radius: 28, y: 14) }
    private var controls: some View {
        VStack(spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(playback.currentTrack?.title ?? "Not Playing").font(.title3.bold()).lineLimit(1); Text(playback.currentTrack?.artist.name ?? "").foregroundColor(.secondary).lineLimit(1) }; Spacer(); Button { if let track = playback.currentTrack { library.toggleFavorite(track) } } label: { Image(systemName: playback.currentTrack.map(library.isFavorite) == true ? "heart.fill" : "heart").font(.title2).foregroundColor(.pink) } }
            VStack(spacing: 7) { Slider(value: Binding(get: { playback.elapsed }, set: { playback.seek(to: $0) }), in: 0...max(playback.duration, 1)); HStack { Text(time(playback.elapsed)); Spacer(); Text("−\(time(max(0, playback.duration - playback.elapsed)))") }.font(.caption2.monospacedDigit()).foregroundColor(.secondary) }
            HStack { Button { playback.shuffleEnabled.toggle() } label: { Image(systemName: "shuffle").foregroundColor(playback.shuffleEnabled ? .pink : .primary) }; Spacer(); Button { playback.previous() } label: { Image(systemName: "backward.fill").font(.title) }; Spacer(); Button { playback.playPause() } label: { ZStack { Circle().fill(Color.primary); Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title).foregroundColor(Color(UIColor.systemBackground)) }.frame(width: 68, height: 68) }; Spacer(); Button { playback.next() } label: { Image(systemName: "forward.fill").font(.title) }; Spacer(); Button { playback.repeatMode = playback.repeatMode == .off ? .all : playback.repeatMode == .all ? .one : .off } label: { Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat").foregroundColor(playback.repeatMode == .off ? .primary : .pink) } }.buttonStyle(.plain)
            HStack { RoutePickerView().frame(width: 42, height: 32); Spacer(); Menu { ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted(.number.precision(.fractionLength(0...2))))×") { playback.playbackRate = rate } } } label: { Label("\(playback.playbackRate.formatted(.number.precision(.fractionLength(0...2))))×", systemImage: "speedometer") }; Spacer(); Button { showQueue = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Queue") }
            if let message = playback.errorMessage { Text(message).font(.footnote).foregroundColor(.red).multilineTextAlignment(.center) }
        }
    }
    private func time(_ seconds: Double) -> String { let value = Int(seconds.isFinite ? seconds : 0); return String(format: "%d:%02d", value / 60, value % 60) }
}

struct QueueView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playback: PlaybackEngine
    var body: some View { NavigationView { List { ForEach(playback.queue) { TrackRow(track: $0, context: playback.queue) }.onDelete(perform: playback.remove).onMove(perform: playback.move) }.navigationTitle("Queue").toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Done") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { EditButton() } } }.navigationViewStyle(.stack) }
}

struct TrackCollectionView: View {
    let title: String; let tracks: [Track]
    @EnvironmentObject private var playback: PlaybackEngine
    var body: some View { List { if let first = tracks.first { Button { playback.play(first, in: tracks) } label: { Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.pink).listRowBackground(Color.clear) }; ForEach(tracks) { TrackRow(track: $0, context: tracks) } }.navigationTitle(title).overlay { if tracks.isEmpty { Text("Nothing here yet.").foregroundColor(.secondary) } }.padding(.bottom, 75) }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    var body: some View { List { ForEach(downloads.offlineTracks) { TrackRow(track: $0) }; ForEach(Array(downloads.progress.keys), id: \.self) { id in VStack(alignment: .leading) { Text(id); ProgressView(value: downloads.progress[id] ?? 0) } } }.navigationTitle("Downloads").overlay { if downloads.offlineTracks.isEmpty && downloads.progress.isEmpty { Text("Downloaded music is available offline.").foregroundColor(.secondary).multilineTextAlignment(.center).padding() } } }
}

struct SignInView: View {
    @EnvironmentObject private var auth: AuthSession
    @State private var email = ""; @State private var password = ""
    var body: some View { Form { Section("Email") { TextField("Email", text: $email).textContentType(.emailAddress).textInputAutocapitalization(.never).keyboardType(.emailAddress); SecureField("Password", text: $password); Button("Sign In") { Task { await auth.signIn(email: email, password: password) } }.disabled(email.isEmpty || password.isEmpty) }; Section("Or continue with") { Button("Google") { auth.social(provider: "google") }; Button("GitHub") { auth.social(provider: "github") }; Button("Discord") { auth.social(provider: "discord") } }; if let error = auth.errorMessage { Section { Text(error).foregroundColor(.red) } } }.navigationTitle("Sign In") }
}

struct ScrobblingSettingsView: View {
    @StateObject private var coordinator = ScrobblingCoordinator.shared
    var body: some View { Form { ForEach(["Last.fm", "Libre.fm", "ListenBrainz", "Maloja"], id: \.self) { service in Toggle(service, isOn: Binding(get: { coordinator.enabledServices.contains(service) }, set: { if $0 { coordinator.enabledServices.insert(service) } else { coordinator.enabledServices.remove(service) } })) } }.navigationTitle("Scrobbling") }
}

struct ProviderSettingsView: View {
    @AppStorage("native.provider") private var provider = Provider.tidal.rawValue
    var body: some View { Form { Picker("Preferred provider", selection: $provider) { ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) } }; Text("Monochrome fails over to another healthy API instance automatically. Protected streams bypass unsupported processing instead of delaying playback.").font(.footnote).foregroundColor(.secondary) }.navigationTitle("Providers") }
}

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = .label; view.activeTintColor = .systemPink; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct MediaSection<Content: View>: View {
    let title: String; let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.title2.bold()).padding(.horizontal); content } }
}

struct HorizontalTrackShelf: View {
    let tracks: [Track]
    var body: some View { ScrollView(.horizontal, showsIndicators: false) { LazyHStack(spacing: 16) { ForEach(tracks) { track in VStack(alignment: .leading, spacing: 7) { ArtworkView(url: track.artworkURL).frame(width: 142, height: 142).clipShape(RoundedRectangle(cornerRadius: 10)); Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1); Text(track.artist.name).font(.caption).foregroundColor(.secondary).lineLimit(1) }.frame(width: 142).contextMenu { TrackContextMenu(track: track) } } }.padding(.horizontal) } }
}

struct TrackContextMenu: View {
    let track: Track
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var library: LibraryRepository
    var body: some View { Button { playback.play(track) } label: { Label("Play", systemImage: "play.fill") }; Button { playback.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }; Button { library.toggleFavorite(track) } label: { Label("Like", systemImage: "heart") } }
}

struct AlbumCard: View {
    let album: Album
    var body: some View { VStack(alignment: .leading, spacing: 7) { ArtworkView(url: album.artworkURL).frame(width: 168, height: 168).clipShape(RoundedRectangle(cornerRadius: 11)); Text(album.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(1); Text(album.artist.name).font(.caption).foregroundColor(.secondary).lineLimit(1) }.frame(width: 168, alignment: .leading) }
}

struct AlbumListRow: View {
    let album: Album
    var body: some View { HStack { ArtworkView(url: album.artworkURL).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading) { Text(album.title); Text(album.artist.name).font(.caption).foregroundColor(.secondary) } } }
}

struct ArtworkView: View {
    let url: URL?
    var body: some View { AsyncImage(url: url) { phase in switch phase { case .success(let image): image.resizable().scaledToFill(); case .failure: placeholder; case .empty: ZStack { placeholder; ProgressView() }; @unknown default: placeholder } }.clipped() }
    private var placeholder: some View { ZStack { LinearGradient(colors: [.gray.opacity(0.5), .black.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.largeTitle).foregroundColor(.white.opacity(0.65)) } }
}

struct FeatureCard: View {
    let icon: String; let title: String; let subtitle: String
    var body: some View { HStack(spacing: 16) { Image(systemName: icon).font(.title).foregroundColor(.pink).frame(width: 48, height: 48).background(Color.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundColor(.secondary) } }.padding().background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal) }
}

struct LibraryDestination: View {
    let icon: String; let color: Color; let title: String; let count: Int?
    var body: some View { HStack { Image(systemName: icon).foregroundColor(.white).frame(width: 34, height: 34).background(color, in: RoundedRectangle(cornerRadius: 7)); Text(title); Spacer(); if let count { Text("\(count)").foregroundColor(.secondary) } } }
}
