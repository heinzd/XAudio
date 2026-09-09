import Foundation

struct AudioTrack: Identifiable, Hashable {
    let url: URL
    let title: String
    let artist: String?
    let album: String?
    let artworkData: Data?
    let duration: TimeInterval

    var id: URL { url }
}

enum PlaybackOrder: String, CaseIterable, Identifiable {
    case sequential
    case shuffled

    var id: Self { self }

    var title: String {
        switch self {
        case .sequential: "Reihenfolge"
        case .shuffled: "Zufällig"
        }
    }

    var symbol: String {
        switch self {
        case .sequential: "arrow.right"
        case .shuffled: "shuffle"
        }
    }
}

