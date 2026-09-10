import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AudioLibraryModel
    @State private var showsFolderImporter = false
    @State private var playlistPresentation: PlaylistPresentation?

    var body: some View {
        NavigationStack {
            Group {
                if model.rootFolder == nil {
                    ContentUnavailableView {
                        Label("Kein Hörbuchordner", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Wähle den Stammordner deiner MP3-Sammlung aus.")
                    } actions: {
                        Button("Ordner auswählen") { showsFolderImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    folderBrowser
                }
            }
            .navigationTitle("XAudio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stammordner", systemImage: "folder.badge.gearshape") {
                        showsFolderImporter = true
                    }
                }
            }
            .fileImporter(
                isPresented: $showsFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { model.openRoot(url) }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .fullScreenCover(item: $playlistPresentation) { presentation in
                PlaylistView(model: model, presentation: presentation)
            }
            .alert("Fehler", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "Unbekannter Fehler")
            }
        }
    }

    private var folderBrowser: some View {
        List {
            Button {
                playlistPresentation = .favorites
            } label: {
                HStack {
                    Label("Favoriten", systemImage: "star.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(model.favoriteCount)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.yellow)

            Section {
                if model.currentFolder != model.rootFolder {
                    Button(action: model.goUp) {
                        Label("Übergeordneter Ordner", systemImage: "arrow.up.left")
                    }
                }

                ForEach(model.folders, id: \.self) { folder in
                    HStack {
                        Button {
                            model.showFolder(folder)
                        } label: {
                            Label(folder.lastPathComponent, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.toggleSelection(folder)
                        } label: {
                            Image(systemName: model.selectedFolders.contains(folder)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .font(.title3)
                                .foregroundStyle(
                                    model.selectedFolders.contains(folder)
                                        ? Color.blue
                                        : Color.secondary
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ordner markieren")
                    }
                }
            } header: {
                Text(model.currentFolder?.lastPathComponent ?? "Ordner")
            } footer: {
                if model.selectedFolders.count == 1,
                   let selected = model.selectedFolders.first {
                    Text("Abspielliste aus: \(selected.lastPathComponent)")
                } else if model.selectedFolders.count > 1 {
                    Text("Abspielliste aus \(model.selectedFolders.count) markierten Ordnern")
                } else {
                    Text("Kein Ordner markiert: Der aktuelle Ordner wird verwendet.")
                }
            }

            Button {
                let sources = model.selectedFolders.isEmpty
                    ? model.currentFolder.map { [$0] } ?? []
                    : model.selectedFolders.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                playlistPresentation = .folders(sources)
            } label: {
                Label("Abspielliste erstellen", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
    }
}

private enum PlaylistPresentation: Identifiable {
    case folders([URL])
    case favorites

    var id: String {
        switch self {
        case .folders: "folders"
        case .favorites: "favorites"
        }
    }

    var isFavorites: Bool {
        if case .favorites = self { return true }
        return false
    }
}

private struct PlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AudioLibraryModel
    let presentation: PlaylistPresentation

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                LandscapePlayerView(model: model)
            } else {
                portraitView
            }
        }
        .task(id: presentation.id) {
            switch presentation {
            case .folders(let sources):
                model.openSelectedPlaylist(from: sources)
            case .favorites:
                model.openFavorites()
            }
        }
        .onDisappear {
            model.stopPlayback()
        }
    }

    private var portraitView: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                    if model.isBuildingPlaylist {
                        ProgressView("MP3-Dateien werden gelesen …")
                    } else if model.playlist.isEmpty {
                        ContentUnavailableView(
                            presentation.isFavorites ? "Keine Favoriten" : "Keine MP3-Dateien",
                            systemImage: presentation.isFavorites ? "star" : "music.note.list"
                        )
                    } else {
                        List(Array(model.playlist.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 10) {
                                Button {
                                    model.play(at: index)
                                } label: {
                                    HStack(spacing: 10) {
                                        ArtworkView(data: track.artworkData, size: 44)
                                        VStack(alignment: .leading) {
                                            Text(track.title).lineLimit(2)
                                            if let artist = track.artist {
                                                Text(artist)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            let albumAndYear = [track.album, track.year]
                                                .compactMap { $0 }
                                                .joined(separator: " · ")
                                            if !albumAndYear.isEmpty {
                                                Text(albumAndYear)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if model.currentIndex == index {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                FavoriteButton(model: model, track: track)
                            }
                            .id(track.id)
                        }
                    }
                }
                .onChange(of: model.navigationScrollRequest) { _, trackID in
                    guard let trackID else { return }
                    withAnimation { proxy.scrollTo(trackID, anchor: .center) }
                }
            }
            .navigationTitle(presentation.isFavorites ? "Favoriten" : "Abspielliste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurück", systemImage: "chevron.left") {
                        model.stopPlayback()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Picker("Wiedergabe", selection: Binding(
                            get: { model.playbackOrder },
                            set: { model.changeOrder(to: $0) }
                        )) {
                            ForEach(PlaybackOrder.allCases) { order in
                                Image(systemName: order.symbol)
                                    .tag(order)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(.blue)
                        .frame(width: 120)

                        Button {
                            model.repeatsPlaylist.toggle()
                        } label: {
                            Image(systemName: "repeat")
                                .foregroundStyle(
                                    model.repeatsPlaylist ? Color.blue : Color.secondary
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            model.repeatsPlaylist
                                ? "Endloswiedergabe ausschalten"
                                : "Endloswiedergabe einschalten"
                        )
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.currentTrack != nil {
                    PlayerBar(model: model)
                }
            }
        }
    }
}
