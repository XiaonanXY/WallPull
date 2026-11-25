import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class MusicPlayerManager: ObservableObject {
    @Published var activeItem: VaultItem? = nil
    @Published var activeTrack: VaultAudioTrack? = nil
    @Published var activeTrackIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoopingSingle: Bool = true

    private var player: AVPlayer? = nil
    private var timeObserver: Any? = nil
    private var endObserver: NSObjectProtocol? = nil
    private var queueItems: [VaultItem] = []
    private weak var vaultRef: LocalVaultStore? = nil

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func play(item: VaultItem, trackIndex: Int = 0, pool: [VaultItem], vault: LocalVaultStore) {
        guard let tracks = item.audioTracks, !tracks.isEmpty else {
            vault.showToast("此壁纸暂未包含可播放的背景音乐", isError: true)
            return
        }
        let safeIdx = max(0, min(trackIndex, tracks.count - 1))
        let track = tracks[safeIdx]
        let url = vault.audioURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else {
            vault.showToast("音频文件尚未缓存到本地，请重新从电脑拉取", isError: true)
            return
        }

        vaultRef = vault
        queueItems = pool.filter { $0.hasMusic }
        if queueItems.isEmpty {
            queueItems = [item]
        }

        if activeItem?.id == item.id && activeTrack?.id == track.id, player != nil {
            togglePlayPause()
            return
        }

        startPlayingURL(url, item: item, track: track, index: safeIdx)
    }

    func playAllAvailable(from items: [VaultItem], vault: LocalVaultStore) {
        let withMusic = items.filter { item in
            guard let tracks = item.audioTracks, let first = tracks.first else { return false }
            return FileManager.default.fileExists(atPath: vault.audioURL(for: first).path)
        }
        guard let firstItem = withMusic.first else {
            vault.showToast("离线库中暂无带配乐的壁纸（可从电脑拉取带 🎵 标记的壁纸）", isError: true)
            return
        }
        play(item: firstItem, trackIndex: 0, pool: withMusic, vault: vault)
    }

    private func startPlayingURL(_ url: URL, item: VaultItem, track: VaultAudioTrack, index: Int) {
        cleanupPlayerObservers()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        let playerItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: playerItem)
        player = p
        activeItem = item
        activeTrack = track
        activeTrackIndex = index
        currentTime = 0
        duration = track.durationSeconds ?? 0

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
                    if durSec.isFinite && durSec > 0 {
                        self.duration = durSec
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
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func nextTrack() {
        guard let vault = vaultRef, let curItem = activeItem else { return }
        let tracks = curItem.audioTracks ?? []
        if activeTrackIndex + 1 < tracks.count {
            play(item: curItem, trackIndex: activeTrackIndex + 1, pool: queueItems, vault: vault)
            return
        }
        guard !queueItems.isEmpty else { return }
        if let idx = queueItems.firstIndex(where: { $0.id == curItem.id }) {
            let nextIdx = (idx + 1) % queueItems.count
            let nextItem = queueItems[nextIdx]
            play(item: nextItem, trackIndex: 0, pool: queueItems, vault: vault)
        } else if let first = queueItems.first {
            play(item: first, trackIndex: 0, pool: queueItems, vault: vault)
        }
    }

    func prevTrack() {
        guard let vault = vaultRef, let curItem = activeItem else { return }
        if currentTime > 4.0 {
            seek(to: 0)
            return
        }
        if activeTrackIndex > 0 {
            play(item: curItem, trackIndex: activeTrackIndex - 1, pool: queueItems, vault: vault)
            return
        }
        guard !queueItems.isEmpty else { return }
        if let idx = queueItems.firstIndex(where: { $0.id == curItem.id }) {
            let prevIdx = (idx - 1 + queueItems.count) % queueItems.count
            let prevItem = queueItems[prevIdx]
            let lastTrackIdx = max(0, (prevItem.audioTracks?.count ?? 1) - 1)
            play(item: prevItem, trackIndex: lastTrackIdx, pool: queueItems, vault: vault)
        }
    }

    func stop() {
        cleanupPlayerObservers()
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        activeTrack = nil
        activeItem = nil
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
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
                }
            }
        } else {
            nextTrack()
        }
    }

    private func cleanupPlayerObservers() {
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
