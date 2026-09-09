import AVFoundation
import Foundation

enum AudioMetadataReader {
    static func track(at url: URL) async -> AudioTrack {
        let asset = AVURLAsset(url: url)

        do {
            let metadata = try await asset.load(.commonMetadata)
            let duration = try await asset.load(.duration).seconds
            let title = await stringValue(for: .commonIdentifierTitle, in: metadata)
            let artist = await stringValue(for: .commonIdentifierArtist, in: metadata)
            let album = await stringValue(for: .commonIdentifierAlbumName, in: metadata)
            let artwork = await dataValue(for: .commonIdentifierArtwork, in: metadata)

            return AudioTrack(
                url: url,
                title: title ?? url.deletingPathExtension().lastPathComponent,
                artist: artist,
                album: album,
                artworkData: artwork,
                duration: duration.isFinite ? duration : 0
            )
        } catch {
            return AudioTrack(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                artist: nil,
                album: nil,
                artworkData: nil,
                duration: 0
            )
        }
    }

    private static func stringValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        guard let item = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: identifier
        ).first else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func dataValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> Data? {
        guard let item = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: identifier
        ).first else { return nil }
        return try? await item.load(.dataValue)
    }
}

