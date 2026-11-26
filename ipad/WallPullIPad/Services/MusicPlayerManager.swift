import AVFoundation
import Combine
import Foundation
import MediaPlayer
import SwiftUI
import UIKit

final class WallPullAudioSessionCoordinator: @unchecked Sendable {
    static let shared = WallPullAudioSessionCoordinator()
    private let queue = DispatchQueue(label: "com.wallpull.ipad.audiosession", qos: .userInitiated)
    private var radioActive = false
    private var videoUnmutedCount = 0

    private init() {}

    func setRadioActive(_ active: Bool) {
        queue.async {
            self.radioActive = active
            self.applyStateLocked()
        }
    }

    func pushVideoUnmuted() {
        queue.async {
            self.videoUnmutedCount += 1
            self.applyStateLocked()
        }
    }

    func popVideoUnmuted() {
        queue.async {
            self.videoUnmutedCount = max(0, self.videoUnmutedCount - 1)
            self.applyStateLocked()
        }
    }

    private func applyStateLocked() {
        let session = AVAudioSession.sharedInstance()
        if radioActive || videoUnmutedCount > 0 {
            try? session.setCategory(.playback, mode: .default, options: [])
            try? session.setActive(true)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
    }
}

@MainActor
final class MusicPlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class MusicPlayerManager: ObservableObject {
    static let idlePlaceholder = MusicPlayerManager()

    @Published var activeItem: VaultItem? = nil
    @Published var activeTrack: VaultAudioTrack? = nil
    @Published var activeTrackIndex: Int = 0
    @Published var isPlaying: Bool = false
    let clock = MusicPlaybackClock()
    var currentTime: Double {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }
    var duration: Double {
        get { clock.duration }
        set { clock.duration = newValue }
    }
    @Published var isLoopingSingle: Bool = UserDefaults.standard.bool(forKey: "wp_music_loop_single") {
        didSet {
            UserDefaults.standard.set(isLoopingSingle, forKey: "wp_music_loop_single")
        }
    }

    private var player: AVPlayer? = nil
    private var timeObserver: Any? = nil
    private var timeControlObs: NSKeyValueObservation? = nil
    private var itemStatusObs: NSKeyValueObservation? = nil
    private var endObserver: NSObjectProtocol? = nil
    private var interruptionObserver: NSObjectProtocol? = nil
    private var routeChangeObserver: NSObjectProtocol? = nil
    private var artworkTask: Task<Void, Never>? = nil
    private var cachedArtworkItemID: String? = nil
    private var cachedArtwork: MPMediaItemArtwork? = nil
    private var remoteCommandsConfigured: Bool = false
    private var queueItems: [VaultItem] = []
    private weak var vaultRef: LocalVaultStore? = nil

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    func resolvedPlayableTracks(for item: VaultItem, vault: LocalVaultStore) -> [(track: VaultAudioTrack, url: URL)] {
        if let tracks = item.audioTracks, !tracks.isEmpty {
            let valid: [(VaultAudioTrack, URL)] = tracks.compactMap { track in
                let url = vault.audioURL(for: track)
                return FileManager.default.fileExists(atPath: url.path) ? (track, url) : nil
            }
            if !valid.isEmpty {
                return valid
            }
        }
        if item.mediaType == .video && item.hasMusic {
            let videoURL = vault.mediaURL(for: item)
            if FileManager.default.fileExists(atPath: videoURL.path) {
                let embeddedTrack = VaultAudioTrack(
                    id: "vbgm-\(item.id)",
                    title: item.title,
                    fileName: item.fileName,
                    durationSeconds: item.durationSeconds
                )
                return [(embeddedTrack, videoURL)]
            }
        }
        return []
    }

    private func activatePlaybackAudioSession() {
        WallPullAudioSessionCoordinator.shared.setRadioActive(true)
    }

    func play(
        item: VaultItem,
        trackIndex: Int = 0,
        pool: [VaultItem],
        vault: LocalVaultStore,
        forceRestart: Bool = false
    ) {
        let playable = resolvedPlayableTracks(for: item, vault: vault)
        guard !playable.isEmpty else {
            vault.showToast("此壁纸暂未包含可播放的背景音乐", isError: true)
            return
        }
        let safeIdx = max(0, min(trackIndex, playable.count - 1))
        let chosen = playable[safeIdx]

        vaultRef = vault
        queueItems = pool.filter { !resolvedPlayableTracks(for: $0, vault: vault).isEmpty }
        if queueItems.isEmpty {
            queueItems = [item]
        }

        if activeItem?.id == item.id && activeTrack?.id == chosen.track.id, let player {
            if forceRestart {
                currentTime = 0
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
                    Task { @MainActor [weak self, weak player] in
                        guard let self, finished, self.player === player else { return }
                        self.isPlaying = true
                        self.activatePlaybackAudioSession()
                        player?.play()
                        self.publishNowPlayingInfo()
                    }
                }
            } else {
                togglePlayPause()
            }
            return
        }

        startPlayingURL(chosen.url, item: item, track: chosen.track, index: safeIdx)
    }

    func playAllAvailable(from items: [VaultItem], vault: LocalVaultStore) {
        let withMusic = items.filter { !resolvedPlayableTracks(for: $0, vault: vault).isEmpty }
        guard let firstItem = withMusic.first else {
            vault.showToast("当前列表暂无带配乐的壁纸", isError: true)
            return
        }
        play(item: firstItem, trackIndex: 0, pool: withMusic, vault: vault)
    }

    private func startPlayingURL(_ url: URL, item: VaultItem, track: VaultAudioTrack, index: Int) {
        cleanupPlayerObservers()
        ensureRemoteCommandsConfigured()

        activeItem = item
        activeTrack = track
        activeTrackIndex = index
        currentTime = 0
        duration = track.durationSeconds ?? 0
        isPlaying = true

        activatePlaybackAudioSession()

        let playerItem = AVPlayerItem(url: url)
        itemStatusObs = playerItem.observe(\.status, options: [.new, .initial]) { observed, _ in
            guard observed.status == .readyToPlay else { return }
            Task { @MainActor in
                for itemTrack in observed.tracks {
                    if itemTrack.assetTrack?.mediaType == .video {
                        itemTrack.isEnabled = false
                    }
                }
            }
        }
        let p = AVPlayer(playerItem: playerItem)
        player = p

        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sec = CMTimeGetSeconds(cmTime)
                if sec.isFinite {
                    self.currentTime = max(0, sec)
                }
                if let durCM = self.player?.currentItem?.duration {
                    let durSec = CMTimeGetSeconds(durCM)
                    if durSec.isFinite && durSec > 0 && abs(self.duration - durSec) > 0.2 {
                        self.duration = durSec
                        self.publishNowPlayingInfo()
                    }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTrackFinished()
            }
        }

        p.play()
        timeControlObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let rateIsPlaying = observed.timeControlStatus == .playing || observed.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor [weak self] in
                guard let self, self.player === observed else { return }
                if self.isPlaying != rateIsPlaying {
                    self.isPlaying = rateIsPlaying
                    self.publishNowPlayingInfo()
                }
            }
        }
        publishNowPlayingInfo()
    }

    func toggleLoopMode() {
        isLoopingSingle.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        vaultRef?.showToast(isLoopingSingle ? "配乐电台：单曲循环" : "配乐电台：列表循环")
    }

    func pausePlayback() {
        guard isPlaying, let player else { return }
        player.pause()
        isPlaying = false
        WallPullAudioSessionCoordinator.shared.setRadioActive(false)
        publishNowPlayingInfo()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            WallPullAudioSessionCoordinator.shared.setRadioActive(false)
        } else {
            isPlaying = true
            activatePlaybackAudioSession()
            player.play()
        }
        publishNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        publishNowPlayingInfo()
    }

    func nextTrack() {
        guard let vault = vaultRef, let curItem = activeItem else { return }
        let playable = resolvedPlayableTracks(for: curItem, vault: vault)
        if activeTrackIndex + 1 < playable.count {
            play(item: curItem, trackIndex: activeTrackIndex + 1, pool: queueItems, vault: vault, forceRestart: true)
            return
        }
        guard !queueItems.isEmpty else { return }
        let startIdx = queueItems.firstIndex(where: { $0.id == curItem.id }) ?? -1
        for offset in 1...queueItems.count {
            let nextIdx = (startIdx + offset + queueItems.count) % queueItems.count
            let nextItem = queueItems[nextIdx]
            let nextPlayable = resolvedPlayableTracks(for: nextItem, vault: vault)
            if !nextPlayable.isEmpty {
                play(item: nextItem, trackIndex: 0, pool: queueItems, vault: vault, forceRestart: true)
                return
            }
        }
    }

    func prevTrack() {
        guard let vault = vaultRef, let curItem = activeItem else { return }
        if currentTime > 4.0 {
            seek(to: 0)
            return
        }
        let playable = resolvedPlayableTracks(for: curItem, vault: vault)
        if activeTrackIndex > 0 && activeTrackIndex - 1 < playable.count {
            play(item: curItem, trackIndex: activeTrackIndex - 1, pool: queueItems, vault: vault, forceRestart: true)
            return
        }
        guard !queueItems.isEmpty else { return }
        let startIdx = queueItems.firstIndex(where: { $0.id == curItem.id }) ?? 0
        for offset in 1...queueItems.count {
            let prevIdx = (startIdx - offset + queueItems.count * 2) % queueItems.count
            let prevItem = queueItems[prevIdx]
            let prevPlayable = resolvedPlayableTracks(for: prevItem, vault: vault)
            if !prevPlayable.isEmpty {
                play(item: prevItem, trackIndex: max(0, prevPlayable.count - 1), pool: queueItems, vault: vault, forceRestart: true)
                return
            }
        }
    }

    func stop() {
        let oldPlayer = player
        cleanupPlayerObservers()
        artworkTask?.cancel()
        artworkTask = nil
        cachedArtwork = nil
        cachedArtworkItemID = nil
        player = nil

        // Update observable UI state immediately before touching AVAudioSession IPC
        isPlaying = false
        currentTime = 0
        duration = 0
        activeTrack = nil
        activeItem = nil

        oldPlayer?.pause()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        WallPullAudioSessionCoordinator.shared.setRadioActive(false)
    }

    func handleDeletedItems(_ deletedIDs: Set<String>) {
        guard !deletedIDs.isEmpty else { return }
        queueItems.removeAll { deletedIDs.contains($0.id) }
        if let cur = activeItem, deletedIDs.contains(cur.id) {
            stop()
        }
    }

    private func handleTrackFinished() {
        if isLoopingSingle {
            guard let player else { return }
            currentTime = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, finished, self.player === player else { return }
                    player.play()
                    self.isPlaying = true
                    self.publishNowPlayingInfo()
                }
            }
        } else {
            nextTrack()
        }
    }

    private func ensureRemoteCommandsConfigured() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.seek(to: posEvent.positionTime)
            }
            return .success
        }

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.nextTrack()
            }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.prevTrack()
            }
            return .success
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if typeRaw == AVAudioSession.InterruptionType.began.rawValue {
                    self.isPlaying = false
                    WallPullAudioSessionCoordinator.shared.setRadioActive(false)
                    self.publishNowPlayingInfo()
                } else if typeRaw == AVAudioSession.InterruptionType.ended.rawValue {
                    let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                    if opts.contains(.shouldResume), let p = self.player {
                        self.activatePlaybackAudioSession()
                        p.play()
                        self.isPlaying = true
                        self.publishNowPlayingInfo()
                    }
                }
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if reasonRaw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                   self.isPlaying {
                    self.player?.pause()
                    self.isPlaying = false
                    WallPullAudioSessionCoordinator.shared.setRadioActive(false)
                    self.publishNowPlayingInfo()
                }
            }
        }
    }

    private func publishNowPlayingInfo() {
        guard let track = activeTrack, let item = activeItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: item.title,
            MPMediaItemPropertyAlbumTitle: "WallPull 配乐电台",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if cachedArtworkItemID == item.id, let art = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = art
        } else if let vault = vaultRef, let thumbURL = vault.thumbURL(for: item) {
            let key = RetinaThumbnailCache.cacheKey(url: thumbURL, revision: vault.thumbRevision, maxPixelSize: 720)
            if let img = RetinaThumbnailCache.shared.image(forKey: key) {
                let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                cachedArtworkItemID = item.id
                cachedArtwork = art
                info[MPMediaItemPropertyArtwork] = art
            } else if cachedArtworkItemID != item.id {
                cachedArtworkItemID = item.id
                cachedArtwork = nil
                artworkTask?.cancel()
                let itemID = item.id
                artworkTask = Task.detached(priority: .utility) { [weak self] in
                    guard let img = UIImage(contentsOfFile: thumbURL.path) else { return }
                    let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    await MainActor.run { [weak self] in
                        guard let self, self.activeItem?.id == itemID else { return }
                        self.cachedArtwork = art
                        self.publishNowPlayingInfo()
                    }
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func cleanupPlayerObservers() {
        itemStatusObs?.invalidate()
        itemStatusObs = nil
        timeControlObs?.invalidate()
        timeControlObs = nil
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}
