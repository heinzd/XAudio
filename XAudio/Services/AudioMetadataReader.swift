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
            let embeddedArtwork = await dataValue(for: .commonIdentifierArtwork, in: metadata)
            let artwork = embeddedArtwork ?? folderArtworkData(beside: url)

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
                artworkData: folderArtworkData(beside: url),
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


    private static func folderArtworkData(beside audioURL: URL) -> Data? {
        let folder = audioURL.deletingLastPathComponent()
        let supportedExtensions = [
            "jpg", "jpeg", "png", "heic", "heif",
            "webp", "tif", "tiff", "bmp", "gif"
        ]

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let imageFiles = files
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                let left = supportedExtensions.firstIndex(
                    of: $0.pathExtension.lowercased()
                ) ?? .max
                let right = supportedExtensions.firstIndex(
                    of: $1.pathExtension.lowercased()
                ) ?? .max
                return left < right
            }

        if let genericCover = imageFiles.first(where: {
            $0.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare("cover") == .orderedSame
        }) {
            return try? Data(contentsOf: genericCover)
        }

        guard let expectedName = structuredCoverBaseName(
            for: folder.lastPathComponent
        ) else { return nil }

        guard let structuredCover = imageFiles.first(where: {
            $0.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(expectedName) == .orderedSame
        }) else { return nil }

        return try? Data(contentsOf: structuredCover)
    }

    private static func structuredCoverBaseName(
        for folderName: String
    ) -> String? {
        let pattern = #"^(\\d+)\\.\\s+(.+?)\\s+-\\s+(.+?)\\s+\\[(\\d{4})\\]$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let source = folderName as NSString
        let range = NSRange(location: 0, length: source.length)
        guard
            let match = expression.firstMatch(in: folderName, range: range),
            match.range == range
        else { return nil }

        let number = source.substring(with: match.range(at: 1))
        let title = source.substring(with: match.range(at: 2))
        let album = source.substring(with: match.range(at: 3))
        return "\(number). \(title) - \(album)"
    }
}

