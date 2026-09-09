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

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var accessedRoot: URL?

    init() {
        configureAudioSession()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.elapsed = time.seconds.isFinite ? time.seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        accessedRoot?.stopAccessingSecurityScopedResource()
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
            let urls = Self.mp3Files(recursivelyBelow: source)
            var tracks: [AudioTrack] = []
            tracks.reserveCapacity(urls.count)
            for url in urls {
                tracks.append(await AudioMetadataReader.track(at: url))
            }
            if playbackOrder == .shuffled { tracks.shuffle() }
            playlist = tracks
            currentIndex = tracks.isEmpty ? nil : 0
            elapsed = 0
            isPlaying = false
            player.replaceCurrentItem(with: nil)
            isBuildingPlaylist = false
        }
    }

    func changeOrder(to order: PlaybackOrder) {
        guard playbackOrder != order else { return }
        let activeURL = currentTrack?.url
        playbackOrder = order
        if order == .sequential {
            playlist.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        } else {
            playlist.shuffle()
        }
        if let activeURL { currentIndex = playlist.firstIndex { $0.url == activeURL } }
    }

    func playPause() {
        guard let track = currentTrack else { return }
        if player.currentItem == nil || (player.currentItem?.asset as? AVURLAsset)?.url != track.url {
            player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func play(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        currentIndex = index
        elapsed = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: playlist[index].url))
        player.play()
        isPlaying = true
    }

    func previous() {
        guard let currentIndex else { return }
        if elapsed > 5 {
            player.seek(to: .zero)
            elapsed = 0
        } else if currentIndex > 0 {
            play(at: currentIndex - 1)
        }
    }

    func next() {
        guard let currentIndex else { return }
        if currentIndex + 1 < playlist.count {
            play(at: currentIndex + 1)
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
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

