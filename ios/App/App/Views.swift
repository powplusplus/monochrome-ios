import SwiftUI
import AVKit
import UIKit

struct RootView: View {
    var body: some View {
        Group {
            if #available(iOS 26.1, *) { ModernRootShell() }
            else { CompatibleRootShell() }
        }
        .tint(.pink)
        .overlay(alignment: .bottom) { PlaylistToastOverlay() }
    }
}

@available(iOS 26.1, *)
private struct ModernRootShell: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var selection: AppTab = .home
    @State private var showPlayer = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: .home) { HomeView() }
            Tab("Library", systemImage: "music.note.list", value: .library) { LibraryView() }
            Tab("Search", systemImage: "magnifyingglass", value: .search) { SearchView() }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) { SettingsView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playback.currentTrack != nil) {
            MiniPlayer(showPlayer: $showPlayer, usesSystemBackground: true)
        }
        .overlay { NowPlayingOverlay(isPresented: $showPlayer) }
    }
}

/// The player rides in the view hierarchy instead of a `fullScreenCover` so the
/// dismiss drag uncovers the tab UI. A cover is an opaque modal — the presenting
/// screen is gone while it's up, so sliding its content down only ever exposed
/// the cover's own black backing.
private struct NowPlayingOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            if isPresented {
                NowPlayingView(isPresented: $isPresented)
                    .transition(.move(edge: .bottom))
            }
        }
    }
}

private struct CompatibleRootShell: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var selection: AppTab = .home
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(AppTab.home)
                LibraryView().tabItem { Label("Library", systemImage: "music.note.list") }.tag(AppTab.library)
                SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(AppTab.search)
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(AppTab.settings)
            }
            if playback.currentTrack != nil {
                MiniPlayer(showPlayer: $showPlayer)
                    .padding(.horizontal, 8).padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { NowPlayingOverlay(isPresented: $showPlayer) }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, library, search, settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "music.note.list"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MonochromeBackground: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                center: UnitPoint(x: 0.5, y: -0.1),
                startRadius: 0,
                endRadius: 430
            )
        }
        .ignoresSafeArea()
    }
}

struct LiquidGlassShape: ViewModifier {
    var cornerRadius: CGFloat = 24
    var strong = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(strong ? Color.white.opacity(0.08) : nil).interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(strong ? 0.42 : 0.26), radius: strong ? 24 : 14, y: 9)
        }
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 24, strong: Bool = false) -> some View {
        modifier(LiquidGlassShape(cornerRadius: cornerRadius, strong: strong))
    }
}

struct LiquidTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { selection = tab }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol).font(.system(size: 18, weight: .semibold))
                        Text(tab.title).font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(selection == tab ? .white : .white.opacity(0.53))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.13))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
                                .matchedGeometryEffect(id: "active-tab", in: selectionAnimation)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(6)
        .liquidGlass(cornerRadius: 25, strong: true)
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryRepository
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var picks: [EditorPick] = []
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !library.history.isEmpty { MediaSection(title: "Jump Back In") { HorizontalTrackShelf(tracks: Array(library.history.prefix(12))) } }
                    MediaSection(title: "Editor’s Picks") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(picks) { pick in
                                    switch pick {
                                    case .album(let album):
                                        NavigationLink(destination: AlbumDetailView(albumID: album.id, initial: album)) { AlbumCard(album: album) }.buttonStyle(.plain)
                                    case .track(let track):
                                        Button { playback.play(track) } label: { AlbumCard(track: track) }
                                            .buttonStyle(.plain)
                                            .contextMenu { TrackContextMenu(track: track) }
                                    }
                                }
                            }.padding(.horizontal)
                        }
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
    @State private var didSearch = false
    @State private var errorText: String?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasResults: Bool {
        !(results.tracks.isEmpty && results.albums.isEmpty && results.artists.isEmpty
            && results.playlists.isEmpty && results.podcasts.isEmpty)
    }

    var body: some View {
        NavigationView {
            Group {
                if trimmedQuery.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 42)).foregroundColor(.secondary)
                        Text("Search Monochrome").font(.title2.bold())
                        Text("Find tracks, albums, artists, playlists, and podcasts.").foregroundColor(.secondary)
                    }.multilineTextAlignment(.center).padding()
                } else if hasResults {
                    List {
                        if !results.tracks.isEmpty { Section("Songs") { ForEach(results.tracks) { TrackRow(track: $0, context: results.tracks) } } }
                        if !results.albums.isEmpty { Section("Albums") { ForEach(results.albums) { album in NavigationLink(destination: AlbumDetailView(albumID: album.id, initial: album)) { AlbumListRow(album: album) } } } }
                        if !results.artists.isEmpty { Section("Artists") { ForEach(results.artists) { artist in Label(artist.name, systemImage: "person.crop.circle") } } }
                        if !results.playlists.isEmpty { Section("Playlists") { ForEach(results.playlists) { playlist in Label(playlist.title, systemImage: "music.note.list") } } }
                        if !results.podcasts.isEmpty {
                            Section("Podcasts") {
                                ForEach(results.podcasts) { podcast in
                                    NavigationLink(destination: PodcastDetailView(podcastID: podcast.id, initial: podcast)) {
                                        PodcastListRow(podcast: podcast)
                                    }
                                }
                            }
                        }
                    }.listStyle(.insetGrouped)
                } else if searching || !didSearch {
                    ProgressView("Searching…")
                } else if let errorText {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(.title).foregroundColor(.secondary)
                        Text("Couldn’t search").font(.headline)
                        Text(errorText).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.vertical, 40)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title).foregroundColor(.secondary)
                        Text("No Results").font(.headline)
                        Text("Try a different artist, album, song, playlist, or podcast.").font(.subheadline).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, albums, songs, podcasts")
            .onChange(of: query) { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results = SearchResults()
                    didSearch = false
                    errorText = nil
                }
            }
            .task(id: query) {
                guard !trimmedQuery.isEmpty else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
        }.navigationViewStyle(.stack)
    }

    private func search() async {
        let requestedQuery = trimmedQuery
        guard !requestedQuery.isEmpty else { return }
        searching = true

        async let musicTask: Result<SearchResults, Error> = {
            do { return .success(try await MusicService.shared.search(requestedQuery)) }
            catch { return .failure(error) }
        }()
        async let podcastsTask: [Podcast] = {
            (try? await PodcastsService.shared.search(query: requestedQuery)) ?? []
        }()

        let music = await musicTask
        let podcasts = await podcastsTask
        guard requestedQuery == trimmedQuery else { return }

        var response = SearchResults()
        switch music {
        case .success(let value):
            response = value
            errorText = nil
        case .failure(let error):
            errorText = error.localizedDescription
        }
        response.podcasts = podcasts

        let empty = response.tracks.isEmpty && response.albums.isEmpty && response.artists.isEmpty
            && response.playlists.isEmpty && response.podcasts.isEmpty
        if !empty { errorText = nil }

        results = response
        didSearch = true
        if requestedQuery == trimmedQuery { searching = false }
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
                    NavigationLink(destination: TrackCollectionView(title: "Liked Songs", tracks: library.favorites, creator: "You", usesLikedArtwork: true)) { LibraryDestination(icon: "heart.fill", color: .pink, title: "Liked Songs", count: library.favorites.count) }
                    NavigationLink(destination: TrackCollectionView(title: "Recently Played", tracks: library.history, creator: "You")) { LibraryDestination(icon: "clock.fill", color: .purple, title: "Recently Played", count: library.history.count) }
                    NavigationLink(destination: PodcastsBrowseView()) { LibraryDestination(icon: "podcast", color: .orange, title: "Podcasts", count: nil) }
                }
                Section("Playlists") {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(destination: TrackCollectionView(title: playlist.title, tracks: playlist.tracks, cover: playlist.cover, creator: playlist.creator ?? "You")) {
                            Label(playlist.title, systemImage: "music.note.list")
                        }
                    }
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
    @AppStorage("native.playbackQuality") private var playbackQuality = PlaybackQuality.lossless.rawValue
    @AppStorage("native.downloadQuality") private var downloadQuality = PlaybackQuality.hiResLossless.rawValue
    @AppStorage("native.gapless") private var gapless = true
    @AppStorage("native.amazonEnabled") private var amazonEnabled = true
    @AppStorage("native.amazonApiBaseURL") private var amazonApiBaseURL = "https://amz.geeked.wtf"
    @AppStorage("native.amazonBypassToken") private var amazonBypassToken = ""
    @AppStorage("native.lucidaEnabled") private var lucidaEnabled = true
    @AppStorage("native.deezerEnabled") private var deezerEnabled = true
    @AppStorage("native.deezerApiBaseURL") private var deezerApiBaseURL = "https://dzr.tabs-vs-spaces.wtf"

    var body: some View {
        NavigationView {
            Form {
                Section("Account") {
                    if auth.isSignedIn { Label("Signed in", systemImage: "checkmark.circle.fill").foregroundColor(.green); Button("Sign Out", role: .destructive) { auth.signOut() } }
                    else { NavigationLink("Sign in to Monochrome", destination: SignInView()) }
                }
                Section("Appearance") { Label("Always dark", systemImage: "moon.fill"); Label("Uses your system text size", systemImage: "textformat.size") }
                Section("Audio") {
                    Picker("Streaming quality", selection: $playbackQuality) {
                        ForEach(PlaybackQuality.allCases) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    }
                    Picker("Download quality", selection: $downloadQuality) {
                        ForEach(PlaybackQuality.allCases) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    }
                    Toggle("Gapless transitions", isOn: $gapless)
                    Picker("Playback speed", selection: $playback.playbackRate) { Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2)) }
                }
                Section(header: Text("Sources"), footer: Text("Amazon Music first. If Amazon cannot resolve — or AVPlayer rejects its URL — Lucida (Qobuz) is tried next (ISRC or artist/title search), then Deezer. TIDAL is catalog only.")) {
                    Toggle("Amazon Music", isOn: $amazonEnabled)
                    if amazonEnabled {
                        TextField("Amazon API base URL", text: $amazonApiBaseURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .disableAutocorrection(true)
                        SecureField("Amazon bypass token (optional)", text: $amazonBypassToken)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                    Toggle("Lucida fallback", isOn: $lucidaEnabled)
                    Toggle("Deezer fallback", isOn: $deezerEnabled)
                    if deezerEnabled {
                        TextField("Deezer API base URL", text: $deezerApiBaseURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .disableAutocorrection(true)
                    }
                }
                Section("Services") { NavigationLink("Scrobbling", destination: ScrobblingSettingsView()); NavigationLink("Provider order", destination: ProviderSettingsView()) }
                Section("Data") {
                    HStack { Text("Cloud playlists"); Spacer(); cloudSyncLabel }
                    if auth.isSignedIn {
                        Button("Sync playlists now") { Task { await library.syncWithCloud() } }
                            .disabled(library.cloudSyncState == .syncing)
                    }
                }
            }.navigationTitle("Settings")
        }.navigationViewStyle(.stack).preferredColorScheme(.dark)
    }

    @ViewBuilder private var cloudSyncLabel: some View {
        switch library.cloudSyncState {
        case .idle: Text(auth.isSignedIn ? "Ready" : "Sign in").foregroundColor(.secondary)
        case .syncing: ProgressView()
        case .complete: Text("Synced").foregroundColor(.green)
        case .failed: Text("Retry").foregroundColor(.orange)
        }
    }
}

struct AlbumDetailView: View {
    let albumID: String
    let initial: Album
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var album: Album
    @State private var loading = false
    @State private var message: String?

    init(albumID: String, initial: Album) { self.albumID = albumID; self.initial = initial; _album = State(initialValue: initial) }
    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                if geometry.size.width > geometry.size.height {
                    HStack(alignment: .top, spacing: 32) { AlbumHero(album: album).frame(width: min(geometry.size.width * 0.38, 320)); trackList }.padding()
                } else { VStack(spacing: 22) { AlbumHero(album: album).padding(.horizontal, 36); trackList }.padding(.vertical) }
            }.padding(.bottom, 90)
        }
        .navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
        .alert("Album unavailable", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .task {
            guard album.tracks.isEmpty else { return }
            loading = true
            do { album = try await MusicService.shared.album(id: albumID, fallback: initial) }
            catch { message = error.localizedDescription }
            loading = false
        }
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
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var podcastProgress = PodcastProgressStore.shared
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""

    private var resumeEntry: PodcastProgressStore.Entry? {
        guard track.isPodcast else { return nil }
        return podcastProgress.progress(for: track.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.play(track, in: context) } label: {
                HStack(spacing: 12) {
                    if let index { Text("\(index)").font(.callout.monospacedDigit()).foregroundColor(.secondary).frame(width: 26) }
                    else { ArtworkView(url: track.artworkURL).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 6)) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).lineLimit(1).foregroundColor(.primary)
                        HStack(spacing: 4) {
                            if track.isVideoPodcast {
                                Image(systemName: "video.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Video episode")
                            }
                            if track.explicit { Text("E").font(.caption2.bold()).padding(.horizontal, 3).background(Color.secondary.opacity(0.25)).cornerRadius(2) }
                            Text(track.artist.name).lineLimit(1)
                        }.font(.caption).foregroundColor(.secondary)
                        if let entry = resumeEntry, entry.position >= 5 {
                            PodcastResumeBar(position: entry.position, duration: entry.duration > 0 ? entry.duration : Int(track.duration))
                        }
                    }
                    Spacer(minLength: 0)
                if playback.currentTrack?.id == track.id {
                    if playback.isPlaying {
                        AudioReactiveBars(meter: playback.audioMeter)
                            .foregroundStyle(.pink)
                            .accessibilityLabel("Now playing")
                    } else {
                        Image(systemName: "pause.fill").foregroundColor(.pink)
                    }
                } else {
                    Image(systemName: "ellipsis").foregroundColor(.secondary)
                }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if !track.isPodcast {
                Button {
                    if !library.quickAddToPlaylist(track) {
                        showCreatePlaylist = true
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add to playlist")

                AppStoreDownloadButton(
                    state: downloadState(for: track),
                    size: 28,
                    lineWidth: 2,
                    squareSize: 7
                ) {
                    handleDownloadTap(for: track)
                }
            }
        }
        .contextMenu {
            Button { playback.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { playback.append(track) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
            if !track.isPodcast {
                Button {
                    if !library.quickAddToPlaylist(track) {
                        showCreatePlaylist = true
                    }
                } label: { Label("Add to Playlist", systemImage: "music.note.list") }
                Button { library.toggleFavorite(track) } label: { Label(library.isFavorite(track) ? "Unlike" : "Like", systemImage: library.isFavorite(track) ? "heart.slash" : "heart") }
                if downloads.isDownloaded(track) {
                    Button(role: .destructive) { downloads.removeDownload(track) } label: { Label("Remove Download", systemImage: "trash") }
                } else if downloads.isDownloading(track) {
                    Button { downloads.cancel(track) } label: { Label("Cancel Download", systemImage: "xmark.circle") }
                } else {
                    Button { Task { await downloads.download(track) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                }
            }
        }
        .alert("New Playlist", isPresented: $showCreatePlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Create") {
                let value = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    library.createPlaylist(named: value, tracks: [track])
                    if let created = library.playlists.first {
                        library.announceAdded(track, to: created.id)
                    }
                }
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("Create a playlist to save this song.")
        }
        .accessibilityLabel("\(track.title), by \(track.artist.name)")
    }

    private func downloadState(for track: Track) -> AppStoreDownloadButton.State {
        if downloads.isDownloaded(track), downloads.progress[track.id] == nil {
            return .downloaded
        }
        if downloads.isPreparing(track) {
            return .preparing
        }
        if let fraction = downloads.progress[track.id] {
            return .downloading(max(0.02, min(1, fraction)))
        }
        if downloads.isDownloading(track) {
            return .preparing
        }
        return .idle
    }

    private func handleDownloadTap(for track: Track) {
        if downloads.isDownloading(track) {
            downloads.cancel(track)
        } else if downloads.isDownloaded(track) {
            return
        } else {
            Task { await downloads.download(track) }
        }
    }
}

struct PodcastResumeBar: View {
    let position: Int
    let duration: Int

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, Double(position) / Double(duration))
    }

    private var label: String {
        "Left off \(formatClock(position))"
    }

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(Color.pink).frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(width: 72, height: 3)
            Text(label).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
    }

    private func formatClock(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// App Store–style circular download control: ring + stop square while active.
struct AppStoreDownloadButton: View {
    enum State: Equatable {
        case idle
        case preparing
        case downloading(Double)
        case downloaded
    }

    let state: State
    var size: CGFloat = 48
    var lineWidth: CGFloat = 2.5
    var squareSize: CGFloat = 9
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .idle:
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: size * 0.85, weight: .regular))
                        .foregroundStyle(.primary)
                case .preparing:
                    Circle()
                        .stroke(Color.primary.opacity(0.22), lineWidth: lineWidth)
                    IndeterminateDownloadRing(lineWidth: lineWidth)
                    RoundedRectangle(cornerRadius: max(1.5, squareSize * 0.2), style: .continuous)
                        .fill(Color.primary)
                        .frame(width: squareSize, height: squareSize)
                case .downloading(let progress):
                    Circle()
                        .stroke(Color.primary.opacity(0.22), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, progress)))
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.12), value: progress)
                    RoundedRectangle(cornerRadius: max(1.5, squareSize * 0.2), style: .continuous)
                        .fill(Color.primary)
                        .frame(width: squareSize, height: squareSize)
                case .downloaded:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: size * 0.85, weight: .regular))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled({
            if case .downloaded = state { return true }
            return false
        }())
        .accessibilityLabel({
            switch state {
            case .idle: return "Download"
            case .preparing, .downloading: return "Cancel Download"
            case .downloaded: return "Downloaded"
            }
        }())
    }
}

private struct IndeterminateDownloadRing: View {
    var lineWidth: CGFloat = 2.5
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

struct PlaylistToastOverlay: View {
    @EnvironmentObject private var library: LibraryRepository
    @State private var showPicker = false

    var body: some View {
        VStack {
            Spacer()
            if let toast = library.playlistToast {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.pink)
                    Text("Added to \(toast.playlistTitle)")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Change") {
                        library.holdPlaylistToast()
                        showPicker = true
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.pink)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .sheet(isPresented: $showPicker, onDismiss: {
                    if let toast = library.playlistToast {
                        library.announceAdded(toast.track, to: toast.playlistID)
                    }
                }) {
                    PlaylistPickSheet(
                        selectedID: toast.playlistID,
                        onPick: { id in
                            library.changeToastPlaylist(to: id)
                            showPicker = false
                        },
                        onDismiss: { showPicker = false }
                    )
                    .environmentObject(library)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: library.playlistToast)
        .allowsHitTesting(library.playlistToast != nil)
    }
}

private struct PlaylistPickSheet: View {
    @EnvironmentObject private var library: LibraryRepository
    let selectedID: String
    let onPick: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(library.playlists) { playlist in
                    Button {
                        onPick(playlist.id)
                    } label: {
                        HStack {
                            Text(playlist.title).foregroundColor(.primary)
                            Spacer()
                            if playlist.id == selectedID {
                                Image(systemName: "checkmark").foregroundColor(.pink)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Five-bar equalizer driven by live playback loudness. Organic phase offsets keep
/// motion readable; meter level scales amplitude so quiet passages settle and peaks jump.
private struct AudioReactiveBars: View {
    @ObservedObject var meter: AudioMeterStore

    private let barCount = 5
    private let maxHeight: CGFloat = 16
    private let minHeight: CGFloat = 2.5
    private let barWidth: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Idle floor while the tap attaches; loudness still owns the amplitude.
            let energy = 0.08 + 0.92 * CGFloat(meter.level)
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = Double(index) * 0.85
                    let speed = 2.6 + Double(index) * 0.55
                    let wobble = 0.35 + 0.65 * abs(sin(t * speed + phase))
                    let height = minHeight + (maxHeight - minHeight) * energy * wobble
                    Capsule()
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(width: 18, height: maxHeight)
        }
        .accessibilityHidden(true)
    }
}

struct MiniPlayer: View {
    @Binding var showPlayer: Bool
    var usesSystemBackground = false
    @EnvironmentObject private var playback: PlaybackEngine
    var body: some View {
        HStack(spacing: 8) {
            Button {
                // Overlay presentation needs the animation supplied here; a
                // fullScreenCover used to bring its own slide-up.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showPlayer = true }
            } label: {
                HStack(spacing: 11) {
                    // 48pt art was taller than the pill's own capsule, so the
                    // corners clipped. Keep it inside the 38pt transport row.
                    ArtworkView(url: playback.currentTrack?.artworkURL)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .compositingGroup()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.currentTrack?.title ?? "").lineLimit(1).font(.subheadline.weight(.semibold))
                        Text(playback.currentTrack?.artist.name ?? "").lineLimit(1).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            SettledLoading(isLoading: playback.isLoading) { spinning in
                ZStack {
                    Button { playback.playPause() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 38, height: 38) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                        .opacity(spinning ? 0 : 1)
                        .allowsHitTesting(!spinning)
                        .accessibilityHidden(spinning)
                    ProgressView().tint(.white).opacity(spinning ? 1 : 0).accessibilityHidden(!spinning)
                }.frame(width: 38, height: 38)
            }
            SkipButton(direction: .forward, font: .body) { playback.next() }.frame(width: 34, height: 38)
        }
        .foregroundStyle(.primary)
        .padding(7)
        .modifier(MiniPlayerBackground(usesSystemBackground: usesSystemBackground))
    }
}

/// Gates a spinner so loads too short to read as anything but a flash never
/// show one: `settled` turns on after ~180ms of loading and holds ~320ms after.
struct SettledLoading<Content: View>: View {
    let isLoading: Bool
    @ViewBuilder var content: (Bool) -> Content

    @State private var settled = false

    var body: some View {
        content(settled)
            .animation(.easeInOut(duration: 0.18), value: settled)
            .task(id: isLoading) {
                if isLoading {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    settled = true
                } else if settled {
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    guard !Task.isCancelled else { return }
                    settled = false
                }
            }
    }
}

private struct MiniPlayerBackground: ViewModifier {
    let usesSystemBackground: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if usesSystemBackground {
            // tabViewBottomAccessory already supplies system glass. A nested
            // glassEffect is what creates the dark diagonal shading.
            content
        } else {
            content.liquidGlass(cornerRadius: 22, strong: true)
        }
    }
}

struct NowPlayingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var library: LibraryRepository
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var lyrics: SyncedLyrics?
    @State private var lyricsLoading = false
    /// Fetched words waiting for their track's audio to become the one actually playing.
    @State private var pendingLyrics: (trackID: String, value: SyncedLyrics?)?
    @State private var dismissOffset: CGFloat = 0
    @State private var artDragOffset: CGFloat = 0

    var body: some View {
        dismissDrivenBody
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showQueue) { QueueView() }
        .task(id: playback.currentTrack?.id) {
            await loadLyrics()
        }
        .onChange(of: playback.loadedTrackID) { _, _ in commitPendingLyrics() }
        .animation(.easeInOut(duration: 0.35), value: showLyrics)
    }

    private var dismissDrivenBody: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            // The keyWindow fallback only exists to cover status-bar expansion
            // lag, which is a portrait concern. In landscape the status bar is
            // hidden and its captured portrait-notch height would otherwise leak
            // in as a dead ~59pt gap above the header (and steal it from the art).
            let topInset = landscape
                ? geometry.safeAreaInsets.top
                : max(geometry.safeAreaInsets.top, Self.keyWindowTopInset)
            let bottomInset = landscape
                ? geometry.safeAreaInsets.bottom
                : max(geometry.safeAreaInsets.bottom, Self.keyWindowBottomInset)
            // The reader ignores the safe area, so these underreport in landscape
            // (where the notch is on the leading edge). Guard both against the
            // window's real insets; both are 0 in portrait so this is a no-op there.
            let leadingInset = max(geometry.safeAreaInsets.leading, Self.keyWindowLeadingInset)
            let trailingInset = max(geometry.safeAreaInsets.trailing, Self.keyWindowTrailingInset)
            let dismissProgress = min(max(dismissOffset / max(geometry.size.height * 0.42, 1), 0), 1)
            ZStack {
                backdrop
                    .ignoresSafeArea()
                // The reader spans the whole screen so the safe area is applied
                // exactly once, here. Letting the parent inset the reader *and*
                // padding by the status-bar height inside it stacked the notch
                // twice and dropped every row ~59pt down the screen.
                VStack(spacing: 0) {
                    header
                        .padding(.top, topInset)
                        // Landscape puts the notch/Dynamic Island on the leading
                        // edge; without this the close and lyrics buttons hide
                        // under it. Both insets are 0 in portrait.
                        .padding(.leading, leadingInset)
                        .padding(.trailing, trailingInset)
                        .contentShape(Rectangle())
                        .gesture(dismissDrag(screenHeight: geometry.size.height))
                    if landscape {
                        landscapeLayout(in: geometry, topInset: topInset, bottomInset: bottomInset, leadingInset: leadingInset, trailingInset: trailingInset)
                    } else {
                        portraitLayout(in: geometry, topInset: topInset, bottomInset: bottomInset)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
            .offset(y: dismissOffset)
            .scaleEffect(1 - dismissProgress * 0.06, anchor: .top)
            .opacity(1 - dismissProgress * 0.45)
            .simultaneousGesture(dismissDrag(screenHeight: geometry.size.height))
        }
        .ignoresSafeArea()
    }

    /// Ride the drag out to the bottom edge, then drop the view once it is
    /// already off screen so removal never flashes.
    private func finishDismiss(screenHeight: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) {
            dismissOffset = screenHeight
            artDragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isPresented = false
            dismissOffset = 0
        }
    }

    private func closeFromChrome() {
        artDragOffset = 0
        withAnimation(.easeInOut(duration: 0.28)) {
            isPresented = false
        }
    }

    private func snapDismissBack() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            dismissOffset = 0
        }
    }

    private func dismissDrag(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                let dy = value.translation.height
                let dx = abs(value.translation.width)
                guard dy > 0, dy > dx * 1.15 else { return }
                dismissOffset = dy
            }
            .onEnded { value in
                let dy = value.translation.height
                let dx = abs(value.translation.width)
                let predicted = value.predictedEndTranslation.height
                if dy > dx && (dy > 100 || predicted > 220) {
                    finishDismiss(screenHeight: screenHeight)
                } else {
                    snapDismissBack()
                }
            }
    }

    private var artworkSwipe: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if dy > 20, dy > abs(dx) * 1.1 {
                    artDragOffset = 0
                    dismissOffset = dy
                    return
                }
                guard abs(dx) > abs(dy) * 1.2 else {
                    artDragOffset = 0
                    return
                }
                artDragOffset = dx * 0.35
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let predictedY = value.predictedEndTranslation.height
                let predictedX = value.predictedEndTranslation.width

                if dy > abs(dx) * 1.1, dy > 100 || predictedY > 220 {
                    finishDismiss(screenHeight: UIScreen.main.bounds.height)
                    return
                }

                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    artDragOffset = 0
                }
                if dismissOffset > 0 {
                    snapDismissBack()
                }

                guard abs(dx) > abs(dy), abs(dx) > 56 || abs(predictedX) > 140 else { return }
                if dx < 0 || predictedX < -140 {
                    playback.next()
                } else {
                    playback.previous()
                }
            }
    }

    private var backdrop: some View {
        ZStack {
            Color.black
            // Overlay keeps blurred art from expanding the ZStack (was shifting UI).
            Color.clear
                .overlay {
                    ArtworkView(url: playback.currentTrack?.artworkURL)
                        .scaledToFill()
                        .blur(radius: 70)
                        .saturation(1.6)
                        .opacity(0.85)
                        .scaleEffect(1.35)
                }
                .clipped()
            LinearGradient(
                colors: [.black.opacity(0.25), .black.opacity(0.4), .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var header: some View {
        HStack {
            Button { closeFromChrome() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("Close player")
            Spacer()
            Text(showLyrics ? "LYRICS" : "NOW PLAYING")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.35)) { showLyrics.toggle() }
            } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.thinMaterial, in: Circle())
                    .foregroundStyle(showLyrics ? Color.pink : Color.primary)
            }
            .accessibilityLabel(showLyrics ? "Hide lyrics" : "Show lyrics")
            .disabled(lyrics == nil && !lyricsLoading)
            .opacity(lyrics == nil && !lyricsLoading ? 0.35 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    /// Header row: two 40pt controls plus the 4pt of padding above and below.
    private static let chromeHeight: CGFloat = 44

    private func portraitLayout(in geometry: GeometryProxy, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let sideInset: CGFloat = 24
        // The home indicator is the only thing that needs clearance down here;
        // on a button-era phone a token gap is enough.
        let bottomPad = max(12, bottomInset)
        let controlsBudget: CGFloat = 292 + bottomPad
        let availableWidth = max(0, geometry.size.width - (sideInset * 2))
        let availableHeight = max(0, geometry.size.height - topInset - Self.chromeHeight)
        // Shrink art to keep transport visible without scrolling on short phones.
        let artSide = min(availableWidth, min(max(168, availableHeight - controlsBudget), 420))
        let needsScroll = artSide + controlsBudget + 24 > availableHeight

        return Group {
            if showLyrics {
                VStack(spacing: 8) {
                    artwork
                        .frame(width: 64, height: 64)
                    lyricsPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls()
                        .padding(.horizontal, sideInset)
                        .padding(.bottom, bottomPad)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if needsScroll {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        artwork
                            .frame(width: min(artSide, 300), height: min(artSide, 300))
                            .padding(.top, 6)
                        controls()
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, sideInset)
                    .padding(.bottom, bottomPad)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    artwork
                        .frame(width: artSide, height: artSide)
                        .padding(.top, 6)
                    Spacer(minLength: 12)
                    controls()
                        .padding(.horizontal, sideInset)
                        .padding(.bottom, bottomPad)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func landscapeLayout(in geometry: GeometryProxy, topInset: CGFloat, bottomInset: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat) -> some View {
        let leadingPad = max(20, leadingInset + 10)
        let trailingPad = max(20, trailingInset + 10)
        let usableHeight = max(160, geometry.size.height - topInset - Self.chromeHeight - bottomInset)
        let artSide = min(usableHeight, min(geometry.size.width * 0.38, 320))

        return HStack(alignment: .center, spacing: 24) {
            if showLyrics {
                // Lyrics is the focus; the art column has no room next to a full
                // transport stack in landscape, so drop it and let the compact
                // controls sit flush — everything fits, no scroll.
                controls(compact: true)
                    .frame(maxWidth: min(geometry.size.width * 0.42, 420))
                lyricsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                artwork
                    .frame(width: artSide, height: artSide)
                // Compact transport fits the landscape height without scrolling,
                // so the dismiss/track-swipe gestures never fight a scroll view.
                controls(compact: true)
                    .frame(maxWidth: 460)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, trailingPad)
        .padding(.bottom, max(8, bottomInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var lyricsPane: some View {
        if lyricsLoading && lyrics == nil {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lyrics, !lyrics.isEmpty {
            SyncedLyricsView(
                lyrics: lyrics,
                activeIndex: lyrics.activeIndex(at: playback.elapsed),
                // Sampled per frame by the instrumental dots. Passed as a closure
                // over the engine rather than as a value so the list keeps
                // re-evaluating only when `activeIndex` moves.
                elapsed: { [playback] in playback.preciseElapsed },
                onSeek: { playback.seek(to: $0) }
            )
            .padding(.horizontal, 20)
        } else {
            Text("No lyrics for this track")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Fetches as soon as the queue index moves — LRCLIB is a separate host, so
    /// overlapping it with the stream resolve is free — but stages the result
    /// instead of showing it. `currentTrack` flips several network hops before the
    /// new audio is playable, and assigning there swapped the pane to the next
    /// song's words while the previous one was still the loaded track.
    private func loadLyrics() async {
        guard let track = playback.currentTrack else {
            pendingLyrics = nil
            lyrics = nil
            lyricsLoading = false
            showLyrics = false
            return
        }
        lyricsLoading = true
        lyrics = nil
        pendingLyrics = nil
        let fetched = await MusicService.shared.lyrics(for: track)
        guard playback.currentTrack?.id == track.id else { return }
        pendingLyrics = (track.id, fetched)
        commitPendingLyrics()
    }

    private func commitPendingLyrics() {
        guard let pending = pendingLyrics else { return }
        // Normally we wait for the engine to settle on this track. A restored queue
        // that has never been loaded would never settle, so release the staged words
        // once the engine is plainly idle rather than spinning forever.
        let settled = pending.trackID == playback.loadedTrackID
        let idle = playback.loadedTrackID == nil && !playback.isLoading && !playback.isPlaying
        guard settled || idle else { return }
        pendingLyrics = nil
        lyrics = pending.value
        lyricsLoading = false
        showLyrics = !(pending.value?.isEmpty ?? true)
    }

    private var artwork: some View {
        Group {
            if playback.currentTrack?.isVideoPodcast == true {
                PlayerVideoView(player: playback.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.42), radius: 28, y: 16)
            } else {
                ArtworkView(url: playback.currentTrack?.artworkURL)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.42), radius: 28, y: 16)
            }
        }
            .offset(x: artDragOffset)
            .opacity(1 - min(abs(artDragOffset) / 180, 0.35))
            .gesture(artworkSwipe)
            .accessibilityHint("Swipe down to close. Swipe sideways to change track.")
    }

    private func controls(compact: Bool = false) -> some View {
        VStack(spacing: compact ? 11 : 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.currentTrack?.title ?? "Not Playing")
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text(playback.currentTrack?.artist.name ?? "")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button {
                    if let track = playback.currentTrack { library.toggleFavorite(track) }
                } label: {
                    Image(systemName: playback.currentTrack.map(library.isFavorite) == true ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundColor(.pink)
                }
            }

            VStack(spacing: 7) {
                Slider(
                    value: Binding(get: { playback.elapsed }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 1)
                )
                HStack {
                    Text(time(playback.elapsed))
                    Spacer()
                    Text("−\(time(max(0, playback.duration - playback.elapsed)))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            }

            if playback.currentStreamProvider == .qobuz || qualityBadge != nil {
                VStack(spacing: 4) {
                    if playback.currentStreamProvider == .qobuz {
                        Text("Lucida")
                            .font(.caption2.weight(.semibold))
                            .kerning(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .accessibilityLabel("Streaming via Lucida")
                    }
                    if let badge = qualityBadge {
                        HStack(spacing: 5) {
                            if badge.tier == .lossless || badge.tier == .hiResLossless {
                                QualityWaveMark()
                                    .frame(width: 24, height: 13)
                            }
                            Text(badge.label)
                            if let detail = playback.currentStreamQualityDetail {
                                Text(detail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            playback.currentStreamQualityDetail.map { "\(badge.label), \($0) bit depth over kilohertz" }
                                ?? badge.label
                        )
                        .font(.caption2.weight(.semibold))
                        .kerning(1.0)
                        .foregroundStyle(badge.tier == .hiResLossless ? Color(red: 0.85, green: 0.68, blue: 0.24) : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                    }
                }
            }

            HStack {
                Button { playback.shuffleEnabled.toggle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundColor(playback.shuffleEnabled ? .pink : .primary)
                }
                Spacer()
                SkipButton(direction: .backward, font: .title) { playback.previous() }
                Spacer()
                // Mini player already spins while a stream resolves; the full
                // player showed a static play glyph, so a slow resolve read as
                // a dead button.
                SettledLoading(isLoading: playback.isLoading) { spinning in
                    Button { playback.playPause() } label: {
                        ZStack {
                            Circle().fill(Color.primary)
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .foregroundColor(Color(UIColor.systemBackground))
                                .opacity(spinning ? 0 : 1)
                            ProgressView()
                                .tint(Color(UIColor.systemBackground))
                                .opacity(spinning ? 1 : 0)
                        }
                        .frame(width: compact ? 54 : 68, height: compact ? 54 : 68)
                    }
                    .allowsHitTesting(!spinning)
                    .accessibilityLabel(spinning ? "Loading track" : (playback.isPlaying ? "Pause" : "Play"))
                }
                Spacer()
                SkipButton(direction: .forward, font: .title) { playback.next() }
                Spacer()
                Button {
                    playback.repeatMode = playback.repeatMode == .off ? .all : playback.repeatMode == .all ? .one : .off
                } label: {
                    Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundColor(playback.repeatMode == .off ? .primary : .pink)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button { playback.autoplayEnabled.toggle() } label: {
                    Image(systemName: "infinity")
                        .foregroundColor(playback.autoplayEnabled ? .pink : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.autoplayEnabled ? "Autoplay on" : "Autoplay off")

                if playback.isFindingMore {
                    ProgressView().controlSize(.mini)
                    Text("Finding more songs…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if playback.autoplayEnabled {
                    Text("Autoplay")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack {
                RoutePickerView().frame(width: 42, height: 32)
                Spacer()
                Menu {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                        Button("\(rate.formatted(.number.precision(.fractionLength(0...2))))×") {
                            playback.playbackRate = rate
                        }
                    }
                } label: {
                    Label(
                        "\(playback.playbackRate.formatted(.number.precision(.fractionLength(0...2))))×",
                        systemImage: "speedometer"
                    )
                }
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Queue")
            }

            if let message = playback.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(message.hasPrefix("Preview only") ? Color.white.opacity(0.7) : .red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Honest badge only: stream we got, else catalog claim. Never the user's
    /// quality preference — that used to paint "Lossless (HiFi)" on MP3 podcasts.
    private var qualityBadge: (tier: PlaybackQuality?, label: String)? {
        guard let track = playback.currentTrack else { return nil }
        if let raw = playback.currentStreamQuality, !raw.isEmpty {
            let tier = PlaybackQuality(providerToken: raw)
            let label = PlaybackQuality.badgeLabel(forToken: raw)
                ?? tier?.title.uppercased()
                ?? raw.uppercased()
            return (tier, label)
        }
        if let catalog = track.catalogQuality {
            let token = track.audioQuality ?? catalog.rawValue
            let label = PlaybackQuality.badgeLabel(forToken: token) ?? catalog.title.uppercased()
            return (catalog, label)
        }
        return nil
    }


    private func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? seconds : 0)
        let h = value / 3600
        let m = (value % 3600) / 60
        let s = value % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// GeometryReader can lag behind status-bar expansions (hotspot/call).
    private static var keyWindowTopInset: CGFloat { keyWindowInsets.top }

    private static var keyWindowBottomInset: CGFloat { keyWindowInsets.bottom }

    // Landscape puts the notch/Dynamic Island on the leading edge. The reader
    // ignores the safe area, so geometry.safeAreaInsets underreports these the
    // same way it does the top inset — fall back to the window's real insets so
    // the header controls and art column clear the notch.
    private static var keyWindowLeadingInset: CGFloat { keyWindowInsets.left }

    private static var keyWindowTrailingInset: CGFloat { keyWindowInsets.right }

    private static var keyWindowInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        return window?.safeAreaInsets ?? .zero
    }
}

/// Old-site karaoke: scale/dim past+upcoming, glow active line, auto-scroll.
///
/// Takes the resolved `activeIndex` rather than the raw clock: the body must
/// only re-evaluate when the highlighted line actually changes, not on every
/// playback tick, or the in-flight highlight animation restarts mid-flight.
struct SyncedLyricsView: View {
    let lyrics: SyncedLyrics
    let activeIndex: Int?
    /// Exact transport position, read on demand. Only the instrumental dots use it.
    var elapsed: () -> Double
    var onSeek: (Double) -> Void

    var body: some View {
        Group {
            if lyrics.isSynced {
                syncedBody
            } else if let plain = lyrics.plainText, !plain.isEmpty {
                ScrollView {
                    Text(plain)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
                .modifier(HiddenScrollIndicators())
            }
        }
    }

    private var syncedBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack, not Lazy: an animated scrollTo into a lazy
                // stack has to guess at the offsets of rows it never built,
                // which lands the target line in the wrong place and snaps.
                // Lyrics are a bounded list, so building them all is cheaper.
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        LyricLineView(
                            line: line,
                            // An instrumental gap runs until the next line starts.
                            // A trailing one has no next line, so give it a nominal
                            // window rather than a zero-length one.
                            lineEnd: index + 1 < lyrics.lines.count ? lyrics.lines[index + 1].time : line.time + 10,
                            role: lineRole(for: line.id),
                            elapsed: elapsed,
                            onSeek: onSeek
                        )
                        .equatable()
                        .id(line.id)
                    }
                }
                // Enough slack for the scroll anchor to place the first and last
                // lines, not enough to read as an empty band at t=0.
                .padding(.vertical, 18)
            }
            .modifier(HiddenScrollIndicators())
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.32))
                }
            }
            .onAppear {
                if let index = activeIndex {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.32))
                }
            }
        }
    }

    fileprivate func lineRole(for id: Int) -> LyricLineRole {
        guard let activeIndex else { return .far }
        if id == activeIndex { return .active }
        if id == activeIndex - 1 { return .recentPast }
        if id < activeIndex { return .past }
        if id == activeIndex + 1 { return .upcoming }
        return .far
    }
}

private enum LyricLineRole: Equatable { case recentPast, past, active, upcoming, far }

/// One lyric line. Equatable so a redraw of the pane only re-renders the two
/// or three rows whose role actually changed.
private struct LyricLineView: View, Equatable {
    let line: LyricLine
    /// Start of the following line — the end of this line's instrumental gap.
    let lineEnd: Double
    let role: LyricLineRole
    let elapsed: () -> Double
    let onSeek: (Double) -> Void

    static func == (lhs: LyricLineView, rhs: LyricLineView) -> Bool {
        lhs.line == rhs.line && lhs.lineEnd == rhs.lineEnd && lhs.role == rhs.role
    }

    private var isInstrumentalGap: Bool { line.text == "..." }

    var body: some View {
        Button {
            onSeek(line.time)
        } label: {
            Group {
                if isInstrumentalGap {
                    InstrumentalDotsView(
                        start: line.time,
                        end: lineEnd,
                        isActive: role == .active,
                        elapsed: elapsed
                    )
                } else {
                    Text(line.text)
                }
            }
            // Fixed size for every role. Swapping the font on the active
            // line re-wraps the text and changes the row height, which
            // shoves the whole column mid-scroll; scaleEffect is a GPU
            // transform that leaves layout untouched.
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .shadow(color: role == .active ? Color.white.opacity(0.28) : .clear, radius: 14)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(scale, anchor: .leading)
            .opacity(opacity)
            .animation(.easeInOut(duration: 0.45), value: role)
        }
        .buttonStyle(.plain)
    }

    private var opacity: Double {
        switch role {
        case .active: 1
        case .upcoming: 0.72
        case .recentPast, .past: 0.32
        case .far: 0.22
        }
    }

    // Active sits at 1 and the rest shrink, rather than the active line growing
    // past 1 — scaling up from a full-width frame would push the tail of a long
    // line outside the scroll view and clip it.
    private var scale: CGFloat {
        switch role {
        case .active: 1
        case .upcoming: 0.9
        case .recentPast, .past: 0.86
        case .far: 0.85
        }
    }

    private var foreground: Color {
        switch role {
        case .active: Color(white: 0.96)
        case .upcoming: Color.white.opacity(0.78)
        case .recentPast, .past, .far: Color.white.opacity(0.55)
        }
    }
}

/// Apple Music's instrumental marker is a progress indicator, not a blinking
/// "…": the three dots read out how much of the gap is left. The cluster
/// breathes on a slow cycle timed so it bottoms out right as the vocal is about
/// to return, each dot brightens as playback crosses its third of the gap and
/// then stays lit, and the whole group pops and collapses over the last beat.
/// The old rolling-wave fade was tied to wall-clock time, so it carried no
/// information and never lined up with the music.
///
/// Every value is sampled from the transport rather than driven by a
/// free-running animation, so a seek into the middle of a gap lands on the
/// right fill and the right phase instead of starting over. Inactive gaps draw
/// nothing, matching the web player, so the pulsing never scatters down the
/// whole lyric column.
private struct InstrumentalDotsView: View {
    let start: Double
    let end: Double
    let isActive: Bool
    let elapsed: () -> Double

    /// Half a breath: the cluster runs from `maxScale` to `minScale` over this,
    /// then back. Matches the web player's 4 s `gap-loop`.
    private static let breathHalfCycle: Double = 4
    /// How long before the next line the exit pop starts.
    private static let exitLead: Double = 0.6
    private static let maxScale: Double = 1.12
    private static let minScale: Double = 0.85
    private static let popScale: Double = 1.2
    /// The dots grow in over this once the gap becomes active.
    private static let entryDuration: Double = 0.4

    private var duration: Double { max(end - start, 0.1) }

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { _ in
            let t = min(max(elapsed(), start), end)
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .opacity(dotOpacity(index: index, at: t))
                }
            }
            .scaleEffect(clusterScale(at: t), anchor: .leading)
            .opacity(isActive ? 1 : 0)
            .frame(height: 26, alignment: .leading)
        }
    }

    /// Each dot owns a third of the gap and fills across it, easing out so the
    /// last of the brightening is gentle. Once filled it stays lit, leaving the
    /// cluster as a coarse three-step progress bar through the instrumental.
    private func dotOpacity(index: Int, at t: Double) -> Double {
        let third = duration / 3
        let fill = clamp01((t - (start + Double(index) * third)) / third)
        return 0.3 + 0.7 * easeOut(fill)
    }

    private func clusterScale(at t: Double) -> Double {
        guard isActive else { return 0 }
        let remaining = end - t
        guard remaining > Self.exitLead else { return exitScale(remaining: remaining) }
        return breathScale(at: t) * easeOut(clamp01((t - start) / Self.entryDuration))
    }

    /// Cosine breath pinned so its trough lands exactly where the exit pop takes
    /// over — the pop then springs out of the bottom of a breath rather than
    /// from wherever a free-running loop happened to be.
    private func breathScale(at t: Double) -> Double {
        let mid = (Self.maxScale + Self.minScale) / 2
        let amplitude = (Self.maxScale - Self.minScale) / 2
        let trough = start + duration - Self.exitLead
        return mid - amplitude * cos(.pi * (t - trough) / Self.breathHalfCycle)
    }

    /// Overshoot to `popScale` in the first third of the lead-out, then collapse
    /// to nothing as the next line lands.
    private func exitScale(remaining: Double) -> Double {
        let progress = clamp01(1 - remaining / Self.exitLead)
        if progress < 0.35 {
            return Self.minScale + (Self.popScale - Self.minScale) * easeOut(progress / 0.35)
        }
        return Self.popScale * (1 - easeOut((progress - 0.35) / 0.65))
    }

    private func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

    private func easeOut(_ value: Double) -> Double { 1 - pow(1 - clamp01(value), 2) }
}

/// Mimics Apple's Lossless/Hi-Res badge: concentric arcs radiating from a
/// shared origin on the left edge, each one taller and bowing further right
/// than the last. The arcs never cross, so they read as one clean ")))"
/// soundwave instead of the tangle of overlapping sines this used to draw.
private struct QualityWaveMark: Shape {
    var turns: Int = 3

    // The Lossless mark is a flat tape coiled into a leaning helix: three bold
    // lobes that pinch to a point where the tape turns edge-on. Model it as a
    // filled ribbon between the tape's two projected edges rather than a set of
    // thin sine strokes.
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 1.0, dy: 1.0)
        let midY = r.midY
        let radius = r.height * 0.34    // vertical swing of the coil centreline
        let halfBand = r.height * 0.22  // apparent half-width of the flat tape
        let slant: CGFloat = 0.30       // rightward lean of the coil
        let samples = 120

        func point(_ t: CGFloat, edge: CGFloat) -> CGPoint {
            let a = 2 * .pi * CGFloat(turns) * t
            // centreline swings with sin(a); the tape face projects to
            // ±halfBand·cos(a), collapsing to a point (the crossing) where the
            // tape is edge-on to the viewer.
            let y = midY - radius * sin(a) + edge * halfBand * cos(a)
            let x = r.minX + t * r.width + slant * (midY - y)
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: point(0, edge: +1))
        for s in 1...samples {
            path.addLine(to: point(CGFloat(s) / CGFloat(samples), edge: +1))
        }
        for s in stride(from: samples, through: 0, by: -1) {
            path.addLine(to: point(CGFloat(s) / CGFloat(samples), edge: -1))
        }
        path.closeSubpath()
        return path
    }
}

private struct HiddenScrollIndicators: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollIndicators(.hidden)
        } else {
            content
        }
    }
}

struct QueueView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playback: PlaybackEngine
    var body: some View { NavigationView { List { ForEach(playback.queue) { TrackRow(track: $0, context: playback.queue) }.onDelete(perform: playback.remove).onMove(perform: playback.move) }.navigationTitle("Queue").toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Done") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { EditButton() } } }.navigationViewStyle(.stack) }
}

struct TrackCollectionView: View {
    let title: String
    let tracks: [Track]
    var cover: String? = nil
    var creator: String? = nil
    var usesLikedArtwork = false

    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var downloads: DownloadManager

    private var artworkURL: URL? {
        if let cover, let url = Artwork.url(cover, size: 640) { return url }
        return tracks.first?.artworkURL
    }

    private var subtitle: String {
        let owner = (creator?.isEmpty == false) ? creator! : "You"
        let count = tracks.count
        let noun = count == 1 ? "song" : "songs"
        return "\(owner) · \(count) \(noun)"
    }

    private var collectionDownloadState: AppStoreDownloadButton.State {
        if let fraction = downloads.collectionProgress(for: tracks) {
            if fraction <= 0.02, tracks.contains(where: { downloads.isPreparing($0) }) {
                return .preparing
            }
            return .downloading(max(0.02, fraction))
        }
        if downloads.allDownloaded(tracks) {
            return .downloaded
        }
        return .idle
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                collectionHero
                collectionActions
                if let message = playback.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(message.hasPrefix("Preview only") ? .secondary : .red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        TrackRow(track: track, context: tracks)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background {
            ZStack {
                Color.black.ignoresSafeArea()
                RadialGradient(
                    colors: [Color.pink.opacity(usesLikedArtwork ? 0.22 : 0.12), Color.clear],
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 20,
                    endRadius: 420
                )
                .ignoresSafeArea()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tracks.isEmpty {
                Text("Nothing here yet.").foregroundColor(.secondary)
            }
        }
    }

    private var collectionHero: some View {
        VStack(spacing: 14) {
            Group {
                if usesLikedArtwork {
                    likedArtworkPlaceholder
                } else {
                    ArtworkView(url: artworkURL)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)

            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
    }

    private var likedArtworkPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.72), Color(white: 0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "heart.fill")
                .font(.system(size: 72, weight: .bold))
                .foregroundStyle(.pink)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
    }

    private var collectionActions: some View {
        HStack(spacing: 16) {
            Button {
                guard !tracks.isEmpty else { return }
                playback.shuffleEnabled = true
                if let track = tracks.randomElement() { playback.play(track, in: tracks) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlass(cornerRadius: 24, strong: false)
            .accessibilityLabel("Shuffle")
            .disabled(tracks.isEmpty)

            Button {
                guard let first = tracks.first else { return }
                playback.shuffleEnabled = false
                playback.play(first, in: tracks)
            } label: {
                SettledLoading(isLoading: playback.isLoading && tracks.contains(where: { $0.id == playback.currentTrack?.id })) { spinning in
                    HStack(spacing: 8) {
                        // ZStack keeps the glyph slot a fixed width so "Play" never shifts.
                        ZStack {
                            Image(systemName: "play.fill").opacity(spinning ? 0 : 1)
                            ProgressView().tint(.black).opacity(spinning ? 1 : 0)
                        }
                        Text("Play").fontWeight(.semibold)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Capsule(style: .continuous).fill(Color.white))
                }
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .accessibilityLabel("Play")

            AppStoreDownloadButton(state: collectionDownloadState) {
                handleCollectionDownloadTap()
            }
            .liquidGlass(cornerRadius: 24, strong: false)
            .disabled(tracks.isEmpty)
        }
        .padding(.horizontal, 28)
    }

    private func handleCollectionDownloadTap() {
        guard !tracks.isEmpty else { return }
        switch collectionDownloadState {
        case .idle:
            Task { await downloads.downloadAll(tracks) }
        case .preparing, .downloading:
            downloads.cancelAll(in: tracks)
        case .downloaded:
            break
        }
    }
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
    var body: some View {
        Form {
            Picker("Preferred catalog provider", selection: $provider) {
                ForEach(Provider.musicCases) { Text($0.title).tag($0.rawValue) }
            }
            Text("Catalog search uses TIDAL metadata. Full audio resolves Amazon → Lucida → Deezer like web Monochrome — not TIDAL stream manifests. Podcasts play enclosure media directly (video episodes show in now playing).")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .navigationTitle("Providers")
    }
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
    @EnvironmentObject private var playback: PlaybackEngine
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(tracks) { track in
                    Button { playback.play(track, in: tracks) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            ArtworkView(url: track.artworkURL).frame(width: 142, height: 142).clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(track.artist.name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(width: 142)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackContextMenu(track: track) }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct TrackContextMenu: View {
    let track: Track
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var library: LibraryRepository
    var body: some View {
        Button { playback.play(track) } label: { Label("Play", systemImage: "play.fill") }
        Button { playback.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
        if !track.isPodcast {
            Button { library.toggleFavorite(track) } label: { Label("Like", systemImage: "heart") }
        }
    }
}

/// Square media card shared by album and standalone-song entries (e.g. Editor's
/// Picks) so a song reads as the same tile shape as an album, just backed by
/// a track's artwork/title/artist instead.
struct AlbumCard: View {
    private let artworkURL: URL?
    private let title: String
    private let artistName: String

    init(album: Album) {
        artworkURL = album.artworkURL
        title = album.title
        artistName = album.artist.name
    }

    init(track: Track) {
        artworkURL = track.artworkURL
        title = track.title
        artistName = track.artist.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(url: artworkURL).frame(width: 168, height: 168).clipShape(RoundedRectangle(cornerRadius: 11))
            Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(1)
            Text(artistName).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }.frame(width: 168, alignment: .leading)
    }
}

struct AlbumListRow: View {
    let album: Album
    var body: some View { HStack { ArtworkView(url: album.artworkURL).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading) { Text(album.title); Text(album.artist.name).font(.caption).foregroundColor(.secondary) } } }
}

struct PodcastListRow: View {
    let podcast: Podcast
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: podcast.artworkURL).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(podcast.title).lineLimit(1)
                if let publisher = podcast.publisher, !publisher.isEmpty {
                    Text(publisher).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                if let count = podcast.episodeCount, count > 0 {
                    Text("\(count) episodes").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }
}

struct PodcastsBrowseView: View {
    @State private var query = ""
    @State private var podcasts: [Podcast] = []
    @State private var loading = true
    @State private var didSearch = false
    @State private var errorText: String?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sectionTitle: String {
        trimmedQuery.isEmpty ? "Trending" : "Results"
    }

    var body: some View {
        Group {
            if loading && podcasts.isEmpty {
                ProgressView(trimmedQuery.isEmpty ? "Loading podcasts…" : "Searching…")
            } else if let errorText, podcasts.isEmpty {
                VStack(spacing: 8) {
                    Text(trimmedQuery.isEmpty ? "Couldn’t load podcasts" : "Couldn’t search").font(.headline)
                    Text(errorText).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                }.padding()
            } else if podcasts.isEmpty && didSearch {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundColor(.secondary)
                    Text("No podcasts found").font(.headline)
                    Text("Try a different show name or host.").font(.subheadline).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                List {
                    Section(sectionTitle) {
                        ForEach(podcasts) { podcast in
                            NavigationLink(destination: PodcastDetailView(podcastID: podcast.id, initial: podcast)) {
                                PodcastListRow(podcast: podcast)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Podcasts")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search podcasts")
        .onChange(of: query) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didSearch = false
                errorText = nil
            }
        }
        .task(id: query) {
            if trimmedQuery.isEmpty {
                await loadTrending()
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await searchPodcasts()
        }
        .refreshable {
            if trimmedQuery.isEmpty {
                await loadTrending()
            } else {
                await searchPodcasts()
            }
        }
    }

    private func loadTrending() async {
        loading = true
        do {
            podcasts = try await PodcastsService.shared.trending()
            errorText = nil
            didSearch = false
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func searchPodcasts() async {
        let requested = trimmedQuery
        guard !requested.isEmpty else { return }
        loading = true
        do {
            podcasts = try await PodcastsService.shared.search(query: requested, max: 40)
            if requested == trimmedQuery {
                errorText = nil
                didSearch = true
            }
        } catch {
            if requested == trimmedQuery {
                errorText = error.localizedDescription
                didSearch = true
            }
        }
        if requested == trimmedQuery { loading = false }
    }
}

struct PodcastDetailView: View {
    let podcastID: String
    var initial: Podcast?
    @EnvironmentObject private var playback: PlaybackEngine
    @ObservedObject private var podcastProgress = PodcastProgressStore.shared
    @State private var podcast: Podcast?
    @State private var episodes: [Track] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let podcast = podcast ?? initial {
                    VStack(spacing: 14) {
                        ArtworkView(url: podcast.artworkURL)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(radius: 16, y: 8)
                        Text(podcast.title).font(.title2.bold()).multilineTextAlignment(.center)
                        if let publisher = podcast.publisher, !publisher.isEmpty {
                            Text(publisher).foregroundColor(.pink)
                        }
                        if let description = podcast.description, !description.isEmpty {
                            Text(description).font(.footnote).foregroundColor(.secondary).lineLimit(4).multilineTextAlignment(.center)
                        }
                        HStack {
                            Button { playResume() } label: {
                                Label(resumeLabel, systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.pink)
                            .disabled(episodes.isEmpty)
                        }
                        .padding(.horizontal)
                    }
                    .padding()
                }

                if loading { ProgressView().padding() }
                else if let errorText {
                    Text(errorText).foregroundColor(.secondary).padding()
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, context: episodes, index: index + 1)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var resumeLabel: String {
        if resumeStartIndex() != nil { return "Resume" }
        return "Play Latest"
    }

    private func resumeStartIndex() -> Int? {
        var bestIndex: Int?
        var bestUpdated: TimeInterval = 0
        for (index, track) in episodes.enumerated() {
            guard let entry = podcastProgress.progress(for: track.id), entry.position >= 5 else { continue }
            if entry.updatedAt > bestUpdated {
                bestUpdated = entry.updatedAt
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func playResume() {
        guard !episodes.isEmpty else { return }
        let index = resumeStartIndex() ?? 0
        playback.play(episodes[index], in: episodes)
    }

    private func load() async {
        loading = true
        do {
            async let detail = PodcastsService.shared.podcast(id: podcastID)
            async let eps = PodcastsService.shared.episodes(podcastID: podcastID)
            if let fetched = try await detail { podcast = fetched }
            else if podcast == nil { podcast = initial }
            episodes = try await eps
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

struct ArtworkView: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var loadFailed = false

    init(url: URL?) {
        self.url = url
        // Seed from cache before the first render; `.task` only runs after one
        // frame, which flashed a spinner over art that was already in memory.
        _image = State(initialValue: url.flatMap { ArtworkImageCache.shared.image(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed || url == nil {
                placeholder
            } else {
                SettledLoading(isLoading: true) { spinning in
                    ZStack { placeholder; ProgressView().opacity(spinning ? 1 : 0) }
                }
            }
        }
        .clipped()
        .task(id: url) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.gray.opacity(0.5), .black.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.largeTitle).foregroundColor(.white.opacity(0.65))
        }
    }

    private func load() async {
        loadFailed = false
        guard let url else { image = nil; return }
        if let cached = ArtworkImageCache.shared.image(for: url) {
            image = cached
            return
        }
        // Keep prior art visible while next URL fetches → no pill flash.
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                loadFailed = true
                return
            }
            guard let decoded = UIImage(data: data) else { loadFailed = true; return }
            ArtworkImageCache.shared.insert(decoded, for: url)
            image = decoded
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}

final class ArtworkImageCache {
    static let shared = ArtworkImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// Dominant cover colors for Now Playing ambient gradient (Apple Music–style).
struct ArtworkPalette: Equatable {
    var top: Color
    var mid: Color
    var bottom: Color

    static let fallback = ArtworkPalette(
        top: Color(red: 0.18, green: 0.18, blue: 0.22),
        mid: Color(red: 0.10, green: 0.10, blue: 0.12),
        bottom: .black
    )

    static func load(from url: URL?) async -> ArtworkPalette {
        guard let url else { return .fallback }
        if let cached = ArtworkImageCache.shared.image(for: url) {
            return extract(from: cached)
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return .fallback }
            ArtworkImageCache.shared.insert(image, for: url)
            return extract(from: image)
        } catch {
            return .fallback
        }
    }

    static func extract(from image: UIImage) -> ArtworkPalette {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .fallback }
        UIGraphicsPushContext(ctx)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        func average(x0: Int, y0: Int, x1: Int, y1: Int) -> (CGFloat, CGFloat, CGFloat) {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    let pr = Double(pixels[i]) / 255
                    let pg = Double(pixels[i + 1]) / 255
                    let pb = Double(pixels[i + 2]) / 255
                    // Skip near-white / near-black → keep palette vivid.
                    let luma = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
                    if luma < 0.08 || luma > 0.92 { continue }
                    r += pr; g += pg; b += pb; n += 1
                }
            }
            guard n > 0 else { return (0.2, 0.2, 0.24) }
            return (r / n, g / n, b / n)
        }

        let topRGB = average(x0: 0, y0: 0, x1: width, y1: height / 2)
        let midRGB = average(x0: 0, y0: height / 4, x1: width, y1: (height * 3) / 4)
        let botRGB = average(x0: 0, y0: height / 2, x1: width, y1: height)

        func wash(_ c: (CGFloat, CGFloat, CGFloat), boost: CGFloat, darken: CGFloat) -> Color {
            let avg = (c.0 + c.1 + c.2) / 3
            let r = min(1, max(0, (avg + (c.0 - avg) * boost) * darken))
            let g = min(1, max(0, (avg + (c.1 - avg) * boost) * darken))
            let b = min(1, max(0, (avg + (c.2 - avg) * boost) * darken))
            return Color(red: r, green: g, blue: b)
        }

        return ArtworkPalette(
            top: wash(topRGB, boost: 1.45, darken: 0.72),
            mid: wash(midRGB, boost: 1.35, darken: 0.48),
            bottom: wash(botRGB, boost: 1.2, darken: 0.22)
        )
    }
}

struct FeatureCard: View {
    let icon: String; let title: String; let subtitle: String
    var body: some View { HStack(spacing: 16) { Image(systemName: icon).font(.title).foregroundColor(.pink).frame(width: 48, height: 48).background(Color.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundColor(.secondary) } }.padding().background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal) }
}

struct LibraryDestination: View {
    let icon: String; let color: Color; let title: String; let count: Int?
    var body: some View { HStack { Image(systemName: icon).foregroundColor(.white).frame(width: 34, height: 34).background(color, in: RoundedRectangle(cornerRadius: 7)); Text(title); Spacer(); if let count { Text("\(count)").foregroundColor(.secondary) } } }
}

/// Skip controls get a springy press-in plus a directional nudge, so a tap reads as
/// "moving" even while the next stream is still resolving.
struct SkipButton: View {
    enum Direction {
        case backward, forward

        var symbol: String { self == .forward ? "forward.fill" : "backward.fill" }
        var label: String { self == .forward ? "Next track" : "Previous track" }
        var nudge: CGFloat { self == .forward ? 5 : -5 }
    }

    let direction: Direction
    var font: Font = .title
    let action: () -> Void

    @State private var pulse = 0

    var body: some View {
        Button {
            pulse += 1
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            action()
        } label: {
            Image(systemName: direction.symbol)
                .font(font)
                .symbolEffect(.bounce, options: .speed(1.8), value: pulse)
                .contentShape(Rectangle())
        }
        .buttonStyle(SkipButtonStyle(direction: direction))
        .accessibilityLabel(direction.label)
    }
}

struct SkipButtonStyle: ButtonStyle {
    let direction: SkipButton.Direction

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .offset(x: configuration.isPressed ? direction.nudge : 0)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

/// Renders `AVPlayer` video frames without AVKit chrome — now-playing controls stay ours.
private struct PlayerVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
