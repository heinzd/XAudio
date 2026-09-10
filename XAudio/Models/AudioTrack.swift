import Foundation

struct AudioTrack: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let artist: String?
    let album: String?
    let year: String?
    let artworkData: Data?
    let duration: TimeInterval

    var id: URL { url }
}

enum PlaybackOrder: String, CaseIterable, Identifiable, Sendable {
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
        case .sequential: "list.bullet"
        case .shuffled: "shuffle"
        }
    }
}

