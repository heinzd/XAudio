import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AudioLibraryModel
    @State private var showsFolderImporter = false

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
                    browser
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
            .safeAreaInset(edge: .bottom) {
                if model.currentTrack != nil { PlayerBar(model: model) }
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

    private var browser: some View {
        List {
            Section {
                if model.currentFolder != model.rootFolder {
                    Button {
                        model.goUp()
                    } label: {
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
                            Image(systemName: model.selectedFolder == folder ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ordner markieren")
                    }
                }
            } header: {
                Text(model.currentFolder?.lastPathComponent ?? "Ordner")
            } footer: {
                if let selected = model.selectedFolder {
                    Text("Playlist ab: \(selected.lastPathComponent)")
                } else {
                    Text("Kein Ordner markiert: Der aktuelle Ordner wird verwendet.")
                }
            }

            Section("Abspielliste") {
                Picker("Wiedergabe", selection: Binding(
                    get: { model.playbackOrder },
                    set: { model.changeOrder(to: $0) }
                )) {
                    ForEach(PlaybackOrder.allCases) { order in
                        Label(order.title, systemImage: order.symbol).tag(order)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    model.buildPlaylist()
                } label: {
                    if model.isBuildingPlaylist {
                        Label("MP3-Dateien werden gelesen …", systemImage: "hourglass")
                    } else {
                        Label("Abspielliste erstellen", systemImage: "text.badge.plus")
                    }
                }
                .disabled(model.isBuildingPlaylist)

                ForEach(Array(model.playlist.enumerated()), id: \.element.id) { index, track in
                    Button {
                        model.play(at: index)
                    } label: {
                        HStack {
                            ArtworkView(data: track.artworkData, size: 44)
                            VStack(alignment: .leading) {
                                Text(track.title).lineLimit(2)
                                if let artist = track.artist {
                                    Text(artist).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.currentIndex == index {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

