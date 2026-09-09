import SwiftUI

struct ArtworkView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "book.closed.fill")
                    .resizable().scaledToFit().padding(size * 0.22)
                    .foregroundStyle(.secondary)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
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
                        Text(track.title).font(.headline).lineLimit(2)
                        Text(positionText).font(.caption).foregroundStyle(.secondary)
                    }
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

                Slider(
                    value: Binding(get: { model.elapsed }, set: { model.seek(to: $0) }),
                    in: 0...max(track.duration, 1)
                )
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

