import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

private enum NowPlayingArtworkFactory {
    nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

@MainActor
@Observable
final class AudioLibraryModel {
    var rootFolder: URL?
    var currentFolder: URL?
    var selectedFolders: Set<URL> = []
    var folders: [URL] = []
    var playlist: [AudioTrack] = []
    var currentIndex: Int?
    var playbackOrder: PlaybackOrder = .sequential
    var isBuildingPlaylist = false
    var isPlaying = false
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    var navigationScrollRequest: URL?
    var favoritePaths: Set<String> = []
    var playlistIsFavorites = false
    var repeatsPlaylist = false

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var accessedRoot: URL?
    @ObservationIgnored private var playbackSequence: [URL] = []
    @ObservationIgnored private var lastNowPlayingUpdateSecond = -1
    @ObservationIgnored private var playlistSourceSignature = ""
    private var savedPositions: [String: TimeInterval] = [:]

    private static let positionsDefaultsKey = "playbackPositions.json"
    private static let rootBookmarkDefaultsKey = "audioRootFolder.bookmark"

    init() {
        savedPositions = Self.loadSavedPositions()
        allowAutomaticScreenLock()
        configureAudioSession()
        configureRemoteCommands()
        restoreRootFolder()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.updatePlaybackTime(time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackDidFinish() }
        }
    }

    var currentTrack: AudioTrack? {
        guard let currentIndex, playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex]
    }

    var playlistSources: [URL] {
        if selectedFolders.isEmpty {
            return currentFolder.map { [$0] } ?? []
        }
        return selectedFolders.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    func openRoot(_ url: URL) {
        accessedRoot?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedRoot = url
        rootFolder = url
        persistRootBookmark(url)
        loadPositionsFromRootFolder()
        loadFavorites()
        playlistSourceSignature = ""
        currentFolder = url
        selectedFolders.removeAll()
        refreshFolders()
    }

    func showFolder(_ url: URL) {
        currentFolder = url
        refreshFolders()
    }

    func goUp() {
        guard let rootFolder, let currentFolder, currentFolder != rootFolder else { return }
        let parent = currentFolder.deletingLastPathComponent()
        guard parent.path.hasPrefix(rootFolder.path) else { return }
        showFolder(parent)
    }

    func toggleSelection(_ url: URL) {
        if selectedFolders.contains(url) {
            selectedFolders.remove(url)
        } else {
            selectedFolders.insert(url)
        }
        playlistSourceSignature = ""
    }

    func refreshFolders() {
        guard let currentFolder else {
            folders = []
            return
        }
        do {
            folders = try FileManager.default.contentsOfDirectory(
                at: currentFolder,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
            folders = []
        }
    }

    func openSelectedPlaylist() {
        playbackOrder = .sequential
        playlistIsFavorites = false
        let sources = playlistSources
        let signature = sources
            .map(\.standardizedFileURL.path)
            .sorted()
            .joined(separator: "\n")
        guard signature != playlistSourceSignature || playlist.isEmpty else {
            rebuildPlaybackSequence()
            return
        }
        playlistSourceSignature = signature
        buildPlaylist(from: sources)
    }

    func openFavorites() {
        playbackOrder = .sequential
        playlistIsFavorites = true
        loadFavorites()
        let signature = "favorites\n" + favoritePaths.sorted().joined(separator: "\n")
        guard signature != playlistSourceSignature || playlist.isEmpty else {
            rebuildPlaybackSequence()
            return
        }
        playlistSourceSignature = signature
        guard let rootFolder else { return }
        let urls = favoritePaths.sorted()
            .map { rootFolder.appendingPathComponent($0, isDirectory: false) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        buildPlaylist(explicitURLs: urls)
    }

    func stopPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        elapsed = 0

        playlist.removeAll()
        playbackSequence.removeAll()
        currentIndex = nil
        navigationScrollRequest = nil
        playlistSourceSignature = ""
        playlistIsFavorites = false

        updateNowPlayingInfo()
    }

    private func buildPlaylist(
        from sources: [URL] = [],
        explicitURLs: [URL]? = nil
    ) {
        guard explicitURLs != nil || !sources.isEmpty else { return }
        isBuildingPlaylist = true
        errorMessage = nil

        Task { @MainActor in
            let urls = await Task.detached(priority: .userInitiated) {
                if let explicitURLs {
                    return explicitURLs.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                }
                let allURLs = sources.flatMap { Self.mp3Files(recursivelyBelow: $0) }
                return Array(Set(allURLs)).sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
            }.value
            var tracks: [AudioTrack] = []
            tracks.reserveCapacity(urls.count)
            for url in urls {
                tracks.append(await AudioMetadataReader.track(at: url))
            }
            playlist = tracks
            rebuildPlaybackSequence()
            currentIndex = tracks.isEmpty ? nil : 0
            elapsed = 0
            isPlaying = false
            player.replaceCurrentItem(with: nil)
            isBuildingPlaylist = false
        }
    }

    var favoriteCount: Int { favoritePaths.count }

    func isFavorite(_ track: AudioTrack) -> Bool {
        favoritePaths.contains(relativePath(for: track.url))
    }

    func toggleFavorite(_ track: AudioTrack) {
        let path = relativePath(for: track.url)
        if favoritePaths.contains(path) {
            favoritePaths.remove(path)
            if playlistIsFavorites {
                let removedIndex = playlist.firstIndex { $0.url == track.url }
                let previousCurrentIndex = currentIndex
                let wasCurrent = currentTrack?.url == track.url
                playlist.removeAll { $0.url == track.url }
                if wasCurrent {
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                    isPlaying = false
                    elapsed = 0
                }
                if playlist.isEmpty {
                    currentIndex = nil
                } else if let removedIndex, let previousCurrentIndex {
                    currentIndex = removedIndex < previousCurrentIndex
                        ? previousCurrentIndex - 1
                        : min(previousCurrentIndex, playlist.count - 1)
                }
                playlistSourceSignature = "favorites\n" + favoritePaths.sorted().joined(separator: "\n")
                rebuildPlaybackSequence()
            }
        } else {
            favoritePaths.insert(path)
        }
        persistFavorites()
    }

    func changeOrder(to order: PlaybackOrder) {
        guard playbackOrder != order else { return }
        playbackOrder = order
        rebuildPlaybackSequence()
    }

    func playPause() {
        guard let track = currentTrack else { return }
        allowAutomaticScreenLock()
        if player.currentItem == nil || (player.currentItem?.asset as? AVURLAsset)?.url != track.url {
            player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func play(
        at index: Int,
        resumeSavedPosition: Bool = false,
        scrollToTrack: Bool = false
    ) {
        guard playlist.indices.contains(index) else { return }
        allowAutomaticScreenLock()

        let track = playlist[index]
        let startPosition = resumeSavedPosition ? savedPosition(for: track) ?? 0 : 0
        currentIndex = index
        elapsed = startPosition
        player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        if startPosition > 0 {
            player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
        }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()

        if scrollToTrack {
            navigationScrollRequest = track.id
        }
    }

    func saveCurrentPositionManually() {
        guard let currentTrack, elapsed > 1 else { return }
        savedPositions[positionKey(for: currentTrack)] = elapsed
        persistSavedPositions()
    }

    func jumpToSavedPosition() {
        guard let currentIndex, savedPosition(for: playlist[currentIndex]) != nil else { return }
        play(at: currentIndex, resumeSavedPosition: true)
    }

    var canSaveCurrentPosition: Bool {
        currentTrack != nil && elapsed > 1
    }

    func savedPositionForCurrentTrack() -> TimeInterval? {
        guard let currentTrack else { return nil }
        return savedPosition(for: currentTrack)
    }

    var hasSavedPositionForCurrentTrack: Bool {
        savedPositionForCurrentTrack() != nil
    }

    func previous() {
        guard let currentIndex else { return }
        if elapsed > 5 {
            player.seek(to: .zero)
            elapsed = 0
            updateNowPlayingInfo()
        } else if let targetIndex = adjacentPlaylistIndex(offset: -1) {
            play(at: targetIndex, scrollToTrack: true)
        }
    }

    func next() {
        guard currentIndex != nil else { return }
        if let targetIndex = adjacentPlaylistIndex(offset: 1) {
            play(at: targetIndex, scrollToTrack: true)
        } else if repeatsPlaylist,
                  let firstURL = playbackSequence.first,
                  let firstIndex = playlist.firstIndex(where: { $0.url == firstURL }) {
            play(at: firstIndex, scrollToTrack: true)
        } else {
            player.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
        updateNowPlayingInfo()
    }

    private func rebuildPlaybackSequence() {
        let sequential = playlist.map(\.url)
        playbackSequence = playbackOrder == .sequential
            ? sequential
            : Self.shuffledChangingOrder(sequential)
    }

    private func adjacentPlaylistIndex(offset: Int) -> Int? {
        guard
            let currentURL = currentTrack?.url,
            let sequenceIndex = playbackSequence.firstIndex(of: currentURL)
        else { return nil }

        let targetSequenceIndex = sequenceIndex + offset
        guard playbackSequence.indices.contains(targetSequenceIndex) else { return nil }
        let targetURL = playbackSequence[targetSequenceIndex]
        return playlist.firstIndex { $0.url == targetURL }
    }

    private func updatePlaybackTime(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        elapsed = seconds

        let wholeSecond = Int(seconds)
        if wholeSecond / 5 != lastNowPlayingUpdateSecond / 5 {
            lastNowPlayingUpdateSecond = wholeSecond
            updateNowPlayingInfo()
        }
    }

    private func trackDidFinish() {
        elapsed = 0
        next()
    }

    private func savedPosition(for track: AudioTrack) -> TimeInterval? {
        let stableKey = positionKey(for: track)
        var position = savedPositions[stableKey]

        if position == nil {
            let relativeSuffix = "/" + relativePath(for: track.url)
            if let legacyEntry = savedPositions.first(where: { $0.key.hasSuffix(relativeSuffix) }) {
                position = legacyEntry.value
                savedPositions[stableKey] = legacyEntry.value
                savedPositions.removeValue(forKey: legacyEntry.key)
                persistSavedPositions()
            }
        }

        guard let position, position > 1 else { return nil }
        if track.duration > 0, position >= track.duration - 2 {
            return nil
        }
        return position
    }

    private func positionKey(for track: AudioTrack) -> String {
        let rootName = rootFolder?.lastPathComponent ?? "AudioLibrary"
        return rootName + "/" + relativePath(for: track.url)
    }

    private func relativePath(for url: URL) -> String {
        guard let rootFolder else { return url.lastPathComponent }

        let rootComponents = rootFolder.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard
            fileComponents.count >= rootComponents.count,
            Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else { return url.lastPathComponent }

        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private struct FavoritesFile: Codable {
        let version: Int
        let favorites: [String]
    }

    private var favoritesFileURL: URL? {
        rootFolder?.appendingPathComponent(".xaudio-favorites.json", isDirectory: false)
    }

    private func loadFavorites() {
        guard
            let favoritesFileURL,
            let data = try? Data(contentsOf: favoritesFileURL),
            let file = try? JSONDecoder().decode(FavoritesFile.self, from: data)
        else {
            favoritePaths = []
            return
        }
        favoritePaths = Set(file.favorites)
    }

    private func persistFavorites() {
        guard let favoritesFileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let file = FavoritesFile(version: 1, favorites: favoritePaths.sorted())
            try encoder.encode(file).write(to: favoritesFileURL, options: .atomic)
        } catch {
            errorMessage = "Favoriten konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private var positionsFileURL: URL? {
        rootFolder?.appendingPathComponent(".xaudio-positions.json", isDirectory: false)
    }

    private func loadPositionsFromRootFolder() {
        guard
            let positionsFileURL,
            let data = try? Data(contentsOf: positionsFileURL),
            let positions = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return }

        savedPositions.merge(positions) { _, rootValue in rootValue }
    }

    private func persistSavedPositions() {
        guard let data = try? JSONEncoder().encode(savedPositions) else { return }
        UserDefaults.standard.set(data, forKey: Self.positionsDefaultsKey)
        if let positionsFileURL {
            try? data.write(to: positionsFileURL, options: .atomic)
        }
    }

    private static func loadSavedPositions() -> [String: TimeInterval] {
        guard
            let data = UserDefaults.standard.data(forKey: positionsDefaultsKey),
            let positions = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return positions
    }

    nonisolated private static func shuffledChangingOrder<Element: Equatable>(
        _ elements: [Element]
    ) -> [Element] {
        guard elements.count > 1 else { return elements }

        var shuffled = elements.shuffled()
        if shuffled == elements {
            let first = shuffled.removeFirst()
            shuffled.append(first)
        }
        return shuffled
    }

    nonisolated private static func mp3Files(recursivelyBelow folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func persistRootBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.rootBookmarkDefaultsKey)
        } catch {
            errorMessage = "Der Stammordner konnte nicht dauerhaft gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func restoreRootFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.rootBookmarkDefaultsKey) else {
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            openRoot(url)
            if isStale {
                persistRootBookmark(url)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.rootBookmarkDefaultsKey)
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playFromRemoteCommand()
            }
            return .success
        }

        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pauseFromRemoteCommand()
            }
            return .success
        }

        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playPause()
            }
            return .success
        }

        commands.previousTrackCommand.isEnabled = true
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.previous()
            }
            return .success
        }

        commands.nextTrackCommand.isEnabled = true
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
            }
            return .success
        }

        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                self?.seek(to: position)
            }
            return .success
        }
    }

    private func playFromRemoteCommand() {
        guard !isPlaying else { return }
        playPause()
    }

    private func pauseFromRemoteCommand() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let artist = track.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        let albumAndYear = [track.album, track.year]
            .compactMap { $0 }
            .joined(separator: " · ")
        if !albumAndYear.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = albumAndYear
        }
        if
            let artworkData = track.artworkData,
            let artwork = NowPlayingArtworkFactory.makeArtwork(from: artworkData)
        {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func allowAutomaticScreenLock() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

