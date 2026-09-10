import SwiftUI

struct ArtworkView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "book.closed.fill")
                    .resizable().scaledToFit().padding(size * 0.22)
                    .foregroundStyle(.secondary)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }
}

struct FavoriteButton: View {
    @Bindable var model: AudioLibraryModel
    let track: AudioTrack

    var body: some View {
        Button {
            model.toggleFavorite(track)
        } label: {
            Image(systemName: model.isFavorite(track) ? "star.fill" : "star")
                .foregroundStyle(model.isFavorite(track) ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            model.isFavorite(track)
                ? "Aus Favoriten entfernen"
                : "Zu Favoriten hinzufügen"
        )
    }
}

struct PlayerBar: View {
    @Bindable var model: AudioLibraryModel

    var body: some View {
        if let track = model.currentTrack {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ArtworkView(data: track.artworkData, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(2)

                        let albumAndYear = [track.album, track.year]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                        if !albumAndYear.isEmpty {
                            Text(albumAndYear)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(positionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Slider(
                    value: Binding(
                        get: { model.elapsed },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...max(track.duration, 1)
                )

                HStack(spacing: 14) {
                    Button {
                        model.saveCurrentPositionManually()
                    } label: {
                        Image(systemName: "play.rectangle")
                    }
                    .disabled(!model.canSaveCurrentPosition)
                    .accessibilityLabel("Position speichern")

                    Button {
                        model.jumpToSavedPosition()
                    } label: {
                        Image(systemName: "play.rectangle.fill")
                    }
                    .foregroundStyle(
                        model.hasSavedPositionForCurrentTrack
                            ? Color.blue
                            : Color.gray
                    )
                    .disabled(!model.hasSavedPositionForCurrentTrack)
                    .accessibilityLabel("Zur gespeicherten Position springen")

                    Spacer()

                    FavoriteButton(model: model, track: track)

                    Spacer()

                    Button(action: model.previous) {
                        Image(systemName: "backward.fill")
                    }
                    Button(action: model.playPause) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Button(action: model.next) {
                        Image(systemName: "forward.fill")
                    }
                }
                .font(.title3)
            }
            .padding()
            .background(.regularMaterial)
        }
    }

    private var positionText: String {
        guard let index = model.currentIndex else { return "" }
        return "\(index + 1) von \(model.playlist.count)"
    }
}



struct LandscapePlayerView: View {
    @Bindable var model: AudioLibraryModel

    var body: some View {
        Group {
            if let track = model.currentTrack {
                GeometryReader { geometry in
                    let coverSize = max(
                        180,
                        min(geometry.size.height - 32, geometry.size.width * 0.43)
                    )

                    HStack(spacing: 28) {
                        ArtworkView(data: track.artworkData, size: coverSize)
                            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 14) {
                                Spacer()

                                FavoriteButton(model: model, track: track)

                                Button {
                                    model.saveCurrentPositionManually()
                                } label: {
                                    Image(systemName: "play.rectangle")
                                }
                                .disabled(!model.canSaveCurrentPosition)
                                .accessibilityLabel("Position speichern")

                                Button {
                                    model.jumpToSavedPosition()
                                } label: {
                                    Image(systemName: "play.rectangle.fill")
                                }
                                .foregroundStyle(
                                    model.hasSavedPositionForCurrentTrack
                                        ? Color.blue
                                        : Color.gray
                                )
                                .disabled(!model.hasSavedPositionForCurrentTrack)
                                .accessibilityLabel("Zur gespeicherten Position springen")
                            }
                            .font(.title2)

                            Text(track.title)
                                .font(.title2.weight(.semibold))
                                .lineLimit(3)

                            if let artist = track.artist {
                                Text(artist)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            let albumAndYear = [track.album, track.year]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                            if !albumAndYear.isEmpty {
                                Text(albumAndYear)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            HStack {
                                Text(formatted(model.elapsed))
                                Spacer()
                                Text(positionText)
                                Spacer()
                                Text("−" + formatted(max(0, track.duration - model.elapsed)))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                            Slider(
                                value: Binding(
                                    get: { model.elapsed },
                                    set: { model.seek(to: $0) }
                                ),
                                in: 0...max(track.duration, 1)
                            )

                            HStack(spacing: 52) {
                                Spacer()

                                Button(action: model.previous) {
                                    Image(systemName: "backward.fill")
                                }

                                Button(action: model.playPause) {
                                    Image(
                                        systemName: model.isPlaying
                                            ? "pause.circle.fill"
                                            : "play.circle.fill"
                                    )
                                    .font(.system(size: 54))
                                }

                                Button(action: model.next) {
                                    Image(systemName: "forward.fill")
                                }

                                Spacer()
                            }
                            .font(.system(size: 30))
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "Kein Titel ausgewählt",
                    systemImage: "book.closed",
                    description: Text(
                        "Drehe das iPhone ins Hochformat und erstelle eine Abspielliste."
                    )
                )
            }
        }
        .background(.regularMaterial)
    }

    private var positionText: String {
        guard let index = model.currentIndex else { return "" }
        return "\(index + 1) von \(model.playlist.count)"
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(
            format: "%d:%02d:%02d",
            total / 3600,
            (total / 60) % 60,
            total % 60
        )
    }
}
