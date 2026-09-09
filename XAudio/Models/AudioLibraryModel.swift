import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioLibraryModel {
    var rootFolder: URL?
    var currentFolder: URL?
    var selectedFolder: URL?
    var folders: [URL] = []
    var playlist: [AudioTrack] = []
    var currentIndex: Int?
    var playbackOrder: PlaybackOrder = .sequential
    var isBuildingPlaylist = false
    var isPlaying = false
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    var navigationScrollRequest: URL?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var accessedRoot: URL?
    @ObservationIgnored private var playbackSequence: [URL] = []
    @ObservationIgnored private var savedPositions: [String: TimeInterval] = [:]
    @ObservationIgnored private var lastPersistedSecond: Int = -1

    private static let positionsDefaultsKey = "playbackPositions.json"

    init() {
        savedPositions = Self.loadSavedPositions()
        configureAudioSession()
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

    var playlistSource: URL? { selectedFolder ?? currentFolder }

    func openRoot(_ url: URL) {
        accessedRoot?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedRoot = url
        rootFolder = url
        currentFolder = url
        selectedFolder = nil
        refreshFolders()
    }

    func showFolder(_ url: URL) {
        currentFolder = url
        selectedFolder = nil
        refreshFolders()
    }

    func goUp() {
        guard let rootFolder, let currentFolder, currentFolder != rootFolder else { return }
        let parent = currentFolder.deletingLastPathComponent()
        guard parent.path.hasPrefix(rootFolder.path) else { return }
        showFolder(parent)
    }

    func toggleSelection(_ url: URL) {
        selectedFolder = selectedFolder == url ? nil : url
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

    func buildPlaylist() {
        guard let source = playlistSource else { return }
        isBuildingPlaylist = true
        errorMessage = nil

        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                Self.mp3Files(recursivelyBelow: source)
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

    func changeOrder(to order: PlaybackOrder) {
        guard playbackOrder != order else { return }
        playbackOrder = order
        rebuildPlaybackSequence()
    }

    func playPause() {
        guard let track = currentTrack else { return }
        if player.currentItem == nil || (player.currentItem?.asset as? AVURLAsset)?.url != track.url {
            player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        }
        if isPlaying {
            player.pause()
            saveCurrentPosition()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func play(
        at index: Int,
        resumeSavedPosition: Bool = false,
        scrollToTrack: Bool = false
    ) {
        guard playlist.indices.contains(index) else { return }

        let track = playlist[index]
        let startPosition = resumeSavedPosition ? savedPosition(for: track) ?? 0 : 0
        let continuesCurrentTrack = resumeSavedPosition && currentTrack?.url == track.url
        if !continuesCurrentTrack {
            saveCurrentPosition()
        }
        currentIndex = index
        elapsed = startPosition
        lastPersistedSecond = Int(startPosition)
        player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        if startPosition > 0 {
            player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
        }
        player.play()
        isPlaying = true

        if scrollToTrack {
            navigationScrollRequest = track.id
        }
    }

    func continueCurrentTrack() {
        guard let currentIndex, savedPosition(for: playlist[currentIndex]) != nil else { return }
        play(at: currentIndex, resumeSavedPosition: true)
    }

    func savedPositionForCurrentTrack() -> TimeInterval? {
        guard let currentTrack else { return nil }
        return savedPosition(for: currentTrack)
    }

    func previous() {
        guard let currentIndex else { return }
        if elapsed > 5 {
            player.seek(to: .zero)
            elapsed = 0
        } else if let targetIndex = adjacentPlaylistIndex(offset: -1) {
            play(at: targetIndex, scrollToTrack: true)
        }
    }

    func next() {
        guard let currentIndex else { return }
        if let targetIndex = adjacentPlaylistIndex(offset: 1) {
            play(at: targetIndex, scrollToTrack: true)
        } else {
            saveCurrentPosition()
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
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
        if isPlaying, wholeSecond / 5 != lastPersistedSecond / 5 {
            lastPersistedSecond = wholeSecond
            saveCurrentPosition()
        }
    }

    private func trackDidFinish() {
        if let currentTrack {
            savedPositions.removeValue(forKey: positionKey(for: currentTrack))
            persistSavedPositions()
        }
        elapsed = 0
        next()
    }

    private func savedPosition(for track: AudioTrack) -> TimeInterval? {
        guard let position = savedPositions[positionKey(for: track)], position > 1 else {
            return nil
        }
        if track.duration > 0, position >= track.duration - 2 {
            return nil
        }
        return position
    }

    private func saveCurrentPosition() {
        guard let currentTrack, elapsed > 1 else { return }
        savedPositions[positionKey(for: currentTrack)] = elapsed
        persistSavedPositions()
    }

    private func positionKey(for track: AudioTrack) -> String {
        track.url.path
    }

    private func persistSavedPositions() {
        guard let data = try? JSONEncoder().encode(savedPositions) else { return }
        UserDefaults.standard.set(data, forKey: Self.positionsDefaultsKey)
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

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

