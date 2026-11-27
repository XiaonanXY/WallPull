import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum StudioBackdrop: String, CaseIterable, Identifiable {
    case dark = "纯黑"
    case checker = "透明棋盘"
    case light = "纯白"
    var id: String { rawValue }
}

struct WallpaperDetailView: View {
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    @ObservedObject var musicPlayer: MusicPlayerManager
    let allItems: [VaultItem]
    @State var currentID: String
    var isClosing: Bool = false
    let onOpenStudio: (VaultItem) -> Void
    var onCurrentIDChanged: ((String) -> Void)? = nil
    let onClose: () -> Void

    @State private var backdrop: StudioBackdrop = .checker
    @State private var isCleanImmersive: Bool = false
    @State private var fillMode: Bool = false
    @State private var isMuted: Bool = false
    @State private var isExtractingBGM: Bool = false
    @State private var videoPlaying: Bool = true
    @State private var videoSpeed: Float = 1.0
    @State private var videoCurrentSec: Double = 0
    @State private var videoDurationSec: Double = 0
    @State private var videoSeekRequest: Double? = nil
    @State private var isScrubbingVideo: Bool = false
    @State private var isCurrentPageZoomed: Bool = false
    @State private var dragDismissOffset: CGFloat = 0
    @State private var showPeerPicker: Bool = false
    @State private var activeSheet: ActiveDetailSheet? = nil
    @State private var pendingCropPayload: DetailCropPayload? = nil
    @State private var isPreparingCrop: Bool = false
    @State private var showSingleDeleteConfirm: Bool = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var selectedTrackIdx: Int = 0
    @State private var selectedVariantIdx: Int = 0
    @State private var sessionItemIDs: [String] = []
    @State private var bgmExtractTask: Task<Void, Never>? = nil
    @State private var isCapturingFrame: Bool = false

    private enum ActiveDetailSheet: Identifiable {
        case info(VaultItem)
        case capturedFrame(CapturedFramePayload)
        case crop(DetailCropPayload)

        var id: String {
            switch self {
            case .info(let item):
                return "info-\(item.id)"
            case .capturedFrame(let payload):
                return "frame-\(payload.id.uuidString)"
            case .crop(let payload):
                return "crop-\(payload.id.uuidString)"
            }
        }
    }

    private struct CapturedFramePayload: Identifiable {
        let id = UUID()
        let image: UIImage
        let timestampSeconds: Double
        let item: VaultItem
    }

    private struct DetailCropPayload: Identifiable {
        let id = UUID()
        let image: UIImage
        let titleText: String
        let isTransparent: Bool
        let contentRating: String?
        let nativePixelSizeOverride: CGSize?
        let fullResImageProvider: (() async -> UIImage?)?
    }

    private var resolvedItems: [VaultItem] {
        guard !sessionItemIDs.isEmpty else { return allItems }
        let liveByID = Dictionary(uniqueKeysWithValues: vault.items.map { ($0.id, $0) })
        let fallbackByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        let mapped = sessionItemIDs.compactMap { liveByID[$0] ?? fallbackByID[$0] }
        return mapped.isEmpty ? allItems : mapped
    }

    private var currentItem: VaultItem? {
        resolvedItems.first(where: { $0.id == currentID }) ?? resolvedItems.first
    }

    private var usesLightBackdropChrome: Bool {
        currentItem?.isTransparentCutout == true && backdrop == .light
    }

    private var chromeForeground: Color {
        usesLightBackdropChrome ? Color(hex: "#18181B") : .white
    }

    private var chromePillFill: Color {
        usesLightBackdropChrome ? Color.black.opacity(0.08) : Color.white.opacity(0.14)
    }

    private var dismissProgress: Double {
        min(1.0, max(0.0, Double(dragDismissOffset) / 240.0))
    }

    private var showHUD: Bool {
        !isCleanImmersive
    }

    private var windowSafeInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
    }

    private func activeMediaURL(for item: VaultItem) -> URL {
        let idx = (item.id == currentID) ? selectedVariantIdx : 0
        return vault.mediaURL(for: item, variantIndex: idx)
    }

    var body: some View {
        ZStack {
            backgroundSurface
                .opacity(1.0 - dismissProgress * 0.55)
                .ignoresSafeArea(.all)

            TabView(selection: $currentID) {
                ForEach(resolvedItems) { item in
                    ZoomableMediaPage(
                        item: item,
                        mediaURL: activeMediaURL(for: item),
                        thumbURL: vault.thumbURL(for: item),
                        fallbackVideoURL: vault.galleryPreviewVideoURL(for: item),
                        thumbRevision: vault.thumbRevision,
                        muted: isMuted,
                        isPlaying: videoPlaying && !isClosing && item.id == currentID,
                        isCurrentPage: item.id == currentID,
                        playbackSpeed: videoSpeed,
                        fillMode: fillMode,
                        seekRequestSeconds: item.id == currentID ? $videoSeekRequest : .constant(nil),
                        isZoomed: $isCurrentPageZoomed,
                        onTimeUpdate: { cur, dur in
                            if item.id == currentID && !isScrubbingVideo {
                                videoCurrentSec = cur
                                if dur > 0 { videoDurationSec = dur }
                            }
                        }
                    )
                    .ignoresSafeArea(.all)
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(.all)
            .scaleEffect(1.0 - dismissProgress * 0.14)
            .offset(y: dragDismissOffset)
            .clipShape(RoundedRectangle(cornerRadius: dragDismissOffset > 4 ? 24 : 0, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCleanImmersive.toggle()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        guard !isCurrentPageZoomed && !fillMode else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        if dy > 0 && abs(dy) > abs(dx) * 1.35 {
                            dragDismissOffset = dy
                        }
                    }
                    .onEnded { value in
                        guard !isCurrentPageZoomed && !fillMode else {
                            if dragDismissOffset != 0 { dragDismissOffset = 0 }
                            return
                        }
                        if dragDismissOffset > 125 || value.predictedEndTranslation.height > 260 {
                            onClose()
                        } else {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                dragDismissOffset = 0
                            }
                        }
                    }
            )
            .onChange(of: currentID) { _ in
                isCurrentPageZoomed = false
                videoCurrentSec = 0
                videoDurationSec = currentItem?.durationSeconds ?? 0
                videoPlaying = true
                selectedTrackIdx = 0
                selectedVariantIdx = 0
                if !isMuted && currentItem?.mediaType == .video && musicPlayer.isPlaying {
                    musicPlayer.pausePlayback()
                }
                onCurrentIDChanged?(currentID)
            }

            if let item = currentItem, showHUD {
                VStack {
                    topBar(item: item)
                        .environment(\.colorScheme, usesLightBackdropChrome ? .light : .dark)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                    VStack(spacing: 10) {
                        if item.mediaType == .video {
                            videoControlsBar(item: item)
                        }
                        if !(item.audioTracks ?? []).isEmpty {
                            musicStripBar(item: item)
                        }
                        if item.allMediaFileNames.count > 1 {
                            variantSwitcherBar(item: item)
                        }
                        bottomDock(item: item)
                    }
                    .environment(\.colorScheme, usesLightBackdropChrome ? .light : .dark)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .opacity(1.0 - dismissProgress * 1.4)
            }
        }
        .statusBar(hidden: fillMode || isCleanImmersive)
        .onAppear {
            if sessionItemIDs.isEmpty {
                sessionItemIDs = allItems.map(\.id)
            }
            if videoDurationSec <= 0 {
                videoDurationSec = currentItem?.durationSeconds ?? 0
            }
            if !isMuted && currentItem?.mediaType == .video && musicPlayer.isPlaying {
                musicPlayer.pausePlayback()
            }
        }
        .onDisappear {
            bgmExtractTask?.cancel()
            bgmExtractTask = nil
        }
        .sheet(item: $activeSheet, onDismiss: {
            if let nextCrop = pendingCropPayload {
                pendingCropPayload = nil
                DispatchQueue.main.async {
                    activeSheet = .crop(nextCrop)
                }
            }
        }) { sheet in
            switch sheet {
            case .info(let item):
                DetailInfoSheet(item: item)
                    .preferredColorScheme(vault.appearanceMode.colorScheme)
            case .capturedFrame(let payload):
                VideoFramePreviewSheetView(
                    image: payload.image,
                    titleText: payload.item.title,
                    timestampSeconds: payload.timestampSeconds,
                    contentRating: payload.item.contentRating,
                    vault: vault,
                    localSend: localSend,
                    onOpenCrop: { frameImg in
                        pendingCropPayload = DetailCropPayload(
                            image: frameImg,
                            titleText: "\(payload.item.title) · 截帧",
                            isTransparent: false,
                            contentRating: payload.item.contentRating,
                            nativePixelSizeOverride: nil,
                            fullResImageProvider: nil
                        )
                        activeSheet = nil
                    },
                    onClose: { activeSheet = nil }
                )
            case .crop(let payload):
                ImageCropSheetView(
                    sourceImage: payload.image,
                    titleText: payload.titleText,
                    isTransparent: payload.isTransparent,
                    contentRating: payload.contentRating,
                    nativePixelSizeOverride: payload.nativePixelSizeOverride,
                    fullResImageProvider: payload.fullResImageProvider,
                    vault: vault,
                    localSend: localSend,
                    onClose: { activeSheet = nil }
                )
            }
        }
        .confirmationDialog(
            localSend.peers.isEmpty ? "暂未检测到接收设备" : "发送到局域网设备",
            isPresented: $showPeerPicker,
            titleVisibility: .visible
        ) {
            if let item = currentItem {
                let chosenURL = activeMediaURL(for: item)
                ForEach(localSend.peers) { peer in
                    Button("发送原文件到「\(peer.alias)」(\(peer.ip))") {
                        Task {
                            await localSend.sendVaultItems(
                                [item],
                                to: peer,
                                targetMode: "vault",
                                overrideMediaURLs: [item.id: chosenURL]
                            )
                        }
                    }
                    if item.mediaType == .image {
                        Button("推至「\(peer.alias)」剪贴板") {
                            Task {
                                await localSend.sendVaultItems(
                                    [item],
                                    to: peer,
                                    targetMode: "clipboard",
                                    overrideMediaURLs: [item.id: chosenURL]
                                )
                            }
                        }
                    }
                }
            }
            if localSend.peers.isEmpty {
                Button("立即扫描局域网设备") {
                    vault.showToast("正在扫描同 Wi-Fi 下的 WallPull 设备…")
                    Task { await localSend.scanNetwork() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if localSend.peers.isEmpty {
                Text("请确认电脑端 WallPull 已打开，且和 iPad 连接在同一个 Wi-Fi 下。")
            }
        }
    }

    @ViewBuilder
    private var backgroundSurface: some View {
        if currentItem?.isTransparentCutout == true {
            switch backdrop {
            case .checker:
                CheckerboardView(squareSize: 18)
            case .dark:
                Color(red: 0.06, green: 0.06, blue: 0.08)
            case .light:
                Color.white
            }
        } else {
            Color(red: 0.05, green: 0.05, blue: 0.07)
        }
    }

    private func topBar(item: VaultItem) -> some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(chromeForeground)
                    .frame(width: 38, height: 38)
                    .background(chromePillFill, in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(chromeForeground)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let res = item.resolutionText { Text(res) }
                    Text(formatFileSize(item.fileSize))
                    if item.allMediaFileNames.count > 1 { Text("\(item.allMediaFileNames.count) 张差分") }
                    if item.supportsLayerStudio { Text("✦ 可拆图层") }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(chromeForeground.opacity(0.68))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(chromePillFill, in: Capsule())

            Spacer()

            if item.isTransparentCutout {
                WallPullSegmentedPill(
                    options: StudioBackdrop.allCases,
                    selection: $backdrop,
                    label: { $0.rawValue },
                    height: 36,
                    lightOnDarkBackdrop: !usesLightBackdropChrome
                )
            }

            Button {
                withAnimation(.easeInOut(duration: 0.22)) { fillMode.toggle() }
            } label: {
                Label(fillMode ? "适应屏幕" : "铺满全屏", systemImage: fillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(fillMode ? .white : chromeForeground)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(fillMode ? vault.accentColor : chromePillFill, in: Capsule())
            }
            .buttonStyle(StickerPressButtonStyle())

            PulseHeartButton(isFavorite: item.isFavorite) {
                vault.toggleFavorite(item)
            }
            .scaleEffect(1.22)
            .frame(width: 38, height: 38)

            UIKitSharePopoverButton(buildShareItems: {
                let targetURL = activeMediaURL(for: item)
                let suffix = item.allMediaFileNames.count > 1 ? "_\(selectedVariantIdx + 1)" : ""
                return WallPullShareHelper.cleanShareURLs(for: [(url: targetURL, suggestedName: "\(item.title)\(suffix)")])
            }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(chromeForeground)
                    .frame(width: 38, height: 38)
                    .background(chromePillFill, in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, max(windowSafeInsets.top, 26) + 8)
    }

    private func fmtClock(_ s: Double) -> String {
        guard s.isFinite && s > 0 else { return "0:00" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func videoControlsBar(item: VaultItem) -> some View {
        let total = max(videoDurationSec, item.durationSeconds ?? 1)
        return HStack(spacing: 12) {
            Button {
                videoPlaying.toggle()
            } label: {
                Image(systemName: videoPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(chromeForeground)
                    .frame(width: 32, height: 32)
                    .background(chromePillFill, in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())

            Text(fmtClock(videoCurrentSec))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(chromeForeground.opacity(0.85))
                .frame(width: 40, alignment: .trailing)

            ElasticVideoSlider(
                value: Binding(
                    get: { min(videoCurrentSec, total) },
                    set: { newVal in
                        videoCurrentSec = newVal
                        videoSeekRequest = newVal
                    }
                ),
                total: total,
                accentColor: vault.accentColor,
                onEditingChanged: { editing in
                    isScrubbingVideo = editing
                }
            )
            .frame(maxWidth: 280)

            Text(fmtClock(total))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(chromeForeground.opacity(0.65))
                .frame(width: 40, alignment: .leading)

            Button {
                if videoSpeed == 1.0 { videoSpeed = 1.5 }
                else if videoSpeed == 1.5 { videoSpeed = 0.5 }
                else { videoSpeed = 1.0 }
            } label: {
                Text(videoSpeed == 1.0 ? "1.0x" : (videoSpeed == 1.5 ? "1.5x" : "0.5x"))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(chromeForeground)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(chromePillFill, in: Capsule())
            }
            .buttonStyle(StickerPressButtonStyle())

            Button {
                isMuted.toggle()
                if !isMuted && musicPlayer.isPlaying {
                    musicPlayer.pausePlayback()
                }
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(chromeForeground)
                    .frame(width: 32, height: 32)
                    .background(chromePillFill, in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())

            if item.hasEmbeddedAudio == true {
                Button {
                    bgmExtractTask?.cancel()
                    bgmExtractTask = Task { await extractAndShareVideoBGM(for: item) }
                } label: {
                    HStack(spacing: 4) {
                        if isExtractingBGM {
                            ProgressView()
                                .controlSize(.small)
                                .tint(chromeForeground)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 11.5, weight: .bold))
                        }
                        Text("提取 BGM")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(chromeForeground)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(chromePillFill, in: Capsule())
                }
                .disabled(isExtractingBGM)
                .buttonStyle(StickerPressButtonStyle())
            }

            Button {
                Task { await captureCurrentVideoFrame(for: item) }
            } label: {
                HStack(spacing: 4) {
                    if isCapturingFrame {
                        ProgressView()
                            .controlSize(.small)
                            .tint(chromeForeground)
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    Text("截帧")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
                .foregroundColor(chromeForeground)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(chromePillFill, in: Capsule())
            }
            .disabled(isCapturingFrame)
            .buttonStyle(StickerPressButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(chromeForeground.opacity(0.12), lineWidth: 1))
    }

    private func captureCurrentVideoFrame(for item: VaultItem) async {
        guard !isCapturingFrame else { return }
        isCapturingFrame = true
        defer { isCapturingFrame = false }

        let targetURL = activeMediaURL(for: item)
        let sec = videoCurrentSec
        do {
            let img = try await VideoFrameCaptureHelper.captureFrame(from: targetURL, atSeconds: sec)
            activeSheet = .capturedFrame(CapturedFramePayload(image: img, timestampSeconds: sec, item: item))
        } catch {
            vault.showToast(error.localizedDescription, isError: true)
        }
    }

    private func extractAndShareVideoBGM(for item: VaultItem) async {
        guard !isExtractingBGM else { return }
        let srcURL = activeMediaURL(for: item)
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            vault.showToast("视频原文件不存在", isError: true)
            return
        }
        isExtractingBGM = true
        defer { isExtractingBGM = false }

        let baseTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = (baseTitle.isEmpty ? "WallPull" : baseTitle)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let shareDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallPullShare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        let outURL = shareDir.appendingPathComponent("\(safeTitle) - BGM.m4a")

        let exportPrep = await Task.detached(priority: .userInitiated) { () -> (AVAssetExportSession?, String?) in
            let asset = AVURLAsset(url: srcURL)
            let audioTracks = asset.tracks(withMediaType: .audio)
            guard let srcTrack = audioTracks.first else {
                return (nil, "该视频未检测到可提取的音轨")
            }
            let composition = AVMutableComposition()
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                return (nil, "无法初始化音频导出轨道")
            }
            let validTrackDur = srcTrack.timeRange.duration.isValid && srcTrack.timeRange.duration.seconds > 0
            let range = validTrackDur
                ? srcTrack.timeRange
                : CMTimeRange(start: .zero, duration: asset.duration)
            do {
                try compTrack.insertTimeRange(range, of: srcTrack, at: .zero)
            } catch {
                return (nil, "读取视频音轨失败：\(error.localizedDescription)")
            }
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                return (nil, "当前设备不支持 M4A 音频导出")
            }
            session.outputURL = outURL
            session.outputFileType = .m4a
            session.shouldOptimizeForNetworkUse = true
            return (session, nil)
        }.value

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: shareDir)
            return
        }
        guard let exporter = exportPrep.0 else {
            try? FileManager.default.removeItem(at: shareDir)
            vault.showToast(exportPrep.1 ?? "提取 BGM 失败", isError: true)
            return
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously {
                    cont.resume()
                }
            }
        } onCancel: {
            exporter.cancelExport()
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: shareDir)
            return
        }
        if exporter.status == .completed && FileManager.default.fileExists(atPath: outURL.path) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            WallPullShareHelper.presentShareSheet(items: [outURL])
        } else {
            try? FileManager.default.removeItem(at: shareDir)
            let msg = exporter.error?.localizedDescription ?? "导出被取消"
            vault.showToast("提取 BGM 失败：\(msg)", isError: true)
        }
    }

    @ViewBuilder
    private func musicStripBar(item: VaultItem) -> some View {
        let tracks = item.audioTracks ?? []
        let safeIdx = max(0, min(selectedTrackIdx, max(0, tracks.count - 1)))
        if let currentTrack = tracks.indices.contains(safeIdx) ? tracks[safeIdx] : tracks.first {
            let isThisPlaying = musicPlayer.activeItem?.id == item.id
                && musicPlayer.activeTrack?.id == currentTrack.id
                && musicPlayer.isPlaying

            HStack(spacing: 10) {
            Button {
                if musicPlayer.activeItem?.id == item.id && musicPlayer.activeTrack?.id == currentTrack.id {
                    if !isThisPlaying && item.mediaType == .video {
                        isMuted = true
                    }
                    musicPlayer.togglePlayPause()
                } else {
                    if item.mediaType == .video {
                        isMuted = true
                    }
                    musicPlayer.play(item: item, trackIndex: safeIdx, pool: resolvedItems, vault: vault)
                }
            } label: {
                Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(vault.accentColor, in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())

            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(vault.accentColor)

            Text(currentTrack.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(chromeForeground)
                .lineLimit(1)
                .frame(maxWidth: 190, alignment: .leading)

            if tracks.count > 1 {
                Button {
                    selectedTrackIdx = (safeIdx + 1) % tracks.count
                    if item.mediaType == .video {
                        isMuted = true
                    }
                    musicPlayer.play(item: item, trackIndex: selectedTrackIdx, pool: resolvedItems, vault: vault)
                } label: {
                    Text("曲目 \(safeIdx + 1)/\(tracks.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(chromeForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(chromePillFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if musicPlayer.activeItem?.id == item.id && musicPlayer.activeTrack?.id == currentTrack.id {
                MusicClockText(clock: musicPlayer.clock)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(chromeForeground.opacity(0.75))
            }

            Button {
                musicPlayer.toggleLoopMode()
            } label: {
                Image(systemName: musicPlayer.isLoopingSingle ? "repeat.1" : "repeat")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(musicPlayer.isLoopingSingle ? vault.accentColor : chromeForeground)
                    .frame(width: 28, height: 28)
                    .background(chromePillFill, in: Circle())
            }
            .buttonStyle(.plain)

            UIKitSharePopoverButton(buildShareItems: {
                let pairs = tracks.map { track in
                    (url: vault.audioURL(for: track), suggestedName: "\(item.title) - \(track.title)")
                }
                return WallPullShareHelper.cleanShareURLs(for: pairs.count > 1 ? pairs : [pairs[safeIdx]])
            }) {
                Label(tracks.count > 1 ? "导出全部 BGM" : "导出 BGM", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(chromeForeground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(chromePillFill, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(chromeForeground.opacity(0.12), lineWidth: 1))
        }
    }

    private func variantSwitcherBar(item: VaultItem) -> some View {
        let count = item.allMediaFileNames.count
        return HStack(spacing: 8) {
            Text("原画差分 \(selectedVariantIdx + 1)/\(count)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(chromeForeground.opacity(0.85))
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { idx in
                        let active = selectedVariantIdx == idx
                        Button {
                            selectedVariantIdx = idx
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text("第 \(idx + 1) 张")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(active ? .white : chromeForeground)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(active ? vault.accentColor : chromePillFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 360)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(chromeForeground.opacity(0.12), lineWidth: 1))
    }

    private func bottomDock(item: VaultItem) -> some View {
        CenteredAdaptiveDock {
            HStack(spacing: 10) {
                    if item.mediaType == .image {
                        Button {
                            vault.copyLosslessToClipboard(item: item, variantIndex: selectedVariantIdx)
                        } label: {
                            Label("复制原图（贴微信）", systemImage: "doc.on.doc.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(vault.accentColor, in: Capsule())
                        }
                        .buttonStyle(StickerPressButtonStyle())

                        Button {
                            let targetURL = activeMediaURL(for: item)
                            Task { await vault.saveMediaURLToPhotos(targetURL, isVideo: false) }
                        } label: {
                            Label("存入相册", systemImage: "square.and.arrow.down.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(chromeForeground)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(chromePillFill, in: Capsule())
                        }
                        .buttonStyle(StickerPressButtonStyle())

                        Button {
                            guard !isPreparingCrop else { return }
                            isPreparingCrop = true
                            let targetURL = activeMediaURL(for: item)
                            let itemTitle = item.title
                            let isTransparent = item.isTransparentCutout
                            let contentRating = item.contentRating
                            Task {
                                defer { isPreparingCrop = false }
                                let previewResult = await Task.detached(priority: .userInitiated) { () -> (UIImage, CGSize)? in
                                    if let loaded = ImageCropSheetView.loadPreviewAndPixelSize(from: targetURL, maxPixelSize: 2048) {
                                        return loaded
                                    }
                                    if let fallback = UIImage(contentsOfFile: targetURL.path),
                                       let cg = fallback.cgImage {
                                        return (fallback, CGSize(width: cg.width, height: cg.height))
                                    }
                                    return nil
                                }.value
                                guard let (previewImg, fullPixelSize) = previewResult else {
                                    vault.showToast("未能读取图片原文件", isError: true)
                                    return
                                }
                                activeSheet = .crop(DetailCropPayload(
                                    image: previewImg,
                                    titleText: itemTitle,
                                    isTransparent: isTransparent,
                                    contentRating: contentRating,
                                    nativePixelSizeOverride: fullPixelSize,
                                    fullResImageProvider: {
                                        await Task.detached(priority: .userInitiated) {
                                            ImageCropSheetView.loadFullResolutionImage(from: targetURL)
                                        }.value
                                    }
                                ))
                            }
                        } label: {
                            Label(isPreparingCrop ? "载入中…" : "比例裁切", systemImage: "crop")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(chromeForeground)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(chromePillFill, in: Capsule())
                        }
                        .disabled(isPreparingCrop)
                        .buttonStyle(StickerPressButtonStyle())
                    } else {
                        Button {
                            Task { await vault.saveToPhotos(items: [item]) }
                        } label: {
                            Label("存入相册", systemImage: "square.and.arrow.down.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(vault.accentColor, in: Capsule())
                        }
                        .buttonStyle(StickerPressButtonStyle())
                    }

                    if item.supportsLayerStudio {
                        Button {
                            onOpenStudio(item)
                        } label: {
                            Label("透视拆图", systemImage: "square.3.layers.3d")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(chromeForeground)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(chromePillFill, in: Capsule())
                        }
                        .buttonStyle(StickerPressButtonStyle())
                    }

                    Button {
                        if localSend.peers.isEmpty {
                            Task { await localSend.scanNetwork() }
                        }
                        showPeerPicker = true
                    } label: {
                        Label("发到设备", systemImage: "paperplane.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(chromeForeground)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(chromePillFill, in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button {
                        if let item = currentItem {
                            activeSheet = .info(item)
                        }
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(chromeForeground)
                            .frame(width: 38, height: 38)
                            .background(chromePillFill, in: Circle())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button(role: .destructive) {
                        showSingleDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(width: 38, height: 38)
                            .background(chromePillFill, in: Circle())
                    }
                    .buttonStyle(StickerPressButtonStyle())
                    .alert("确认删除此壁纸？", isPresented: $showSingleDeleteConfirm) {
                        Button("取消", role: .cancel) {}
                        Button("确认删除", role: .destructive) {
                            let list = resolvedItems
                            let curIdx = list.firstIndex(where: { $0.id == item.id })
                            let remaining = list.filter { $0.id != item.id }
                            let nextID: String?
                            if let curIdx, !remaining.isEmpty {
                                nextID = remaining[min(curIdx, remaining.count - 1)].id
                            } else {
                                nextID = remaining.first?.id
                            }
                            sessionItemIDs.removeAll { $0 == item.id }
                            vault.deleteItems(ids: [item.id])
                            if let nextID {
                                currentID = nextID
                            } else {
                                onClose()
                            }
                        }
                    } message: {
                        Text("将从 iPad 本地离线库中移除「\(item.title)」，该操作无法撤销。")
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(chromeForeground.opacity(0.14), lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, max(windowSafeInsets.bottom, 16) + 6)
    }
}

private struct DetailInfoSheet: View {
    let item: VaultItem
    @Environment(\.dismiss) private var dismiss

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section("壁纸规格") {
                    infoRow("名称", item.title)
                    infoRow("媒体类型", item.mediaType == .video ? "动态视频壁纸" : (item.isTransparentCutout ? "透明立绘" : "高清原画"))
                    infoRow("内容分级", item.contentRatingLabel)
                    if let res = item.resolutionText {
                        infoRow("分辨率", res)
                    }
                    if let dur = item.durationText {
                        infoRow("时长", dur)
                    }
                    if item.allMediaFileNames.count > 1 {
                        infoRow("多张原画差分", "共 \(item.allMediaFileNames.count) 张")
                    }
                    infoRow("文件体积", formatFileSize(item.fileSize))
                    infoRow("存储格式", URL(fileURLWithPath: item.fileName).pathExtension.uppercased())
                }

                Section("扩展能力与来源") {
                    infoRow("来源设备", item.sourceDevice)
                    infoRow("入库时间", item.addedAt.formatted(date: .abbreviated, time: .shortened))
                    infoRow("2D 透视拆图", item.supportsLayerStudio ? "已支持（可离线拆图）" : "未检测到")
                    infoRow(
                        "背景配乐",
                        item.hasMusic
                            ? ((item.audioTracks?.count ?? 0) > 0 ? "\(item.audioTracks!.count) 首独立音轨" : "视频内嵌原声")
                            : "无"
                    )
                }
            }
            .navigationTitle("壁纸详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct ZoomableMediaPage: View {
    let item: VaultItem
    let mediaURL: URL
    let thumbURL: URL?
    let fallbackVideoURL: URL
    let thumbRevision: Int
    let muted: Bool
    let isPlaying: Bool
    let isCurrentPage: Bool
    let playbackSpeed: Float
    let fillMode: Bool
    @Binding var seekRequestSeconds: Double?
    @Binding var isZoomed: Bool
    let onTimeUpdate: (Double, Double) -> Void

    @State private var fullImage: UIImage? = nil
    @State private var posterImage: UIImage? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if item.mediaType == .video {
                    if let posterImage {
                        Image(uiImage: posterImage)
                            .resizable()
                            .aspectRatio(contentMode: fillMode ? .fill : .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    InlineLoopVideoView(
                        url: mediaURL,
                        fallbackURL: fallbackVideoURL == mediaURL ? nil : fallbackVideoURL,
                        muted: muted,
                        isPlaying: isPlaying,
                        isCurrentPage: isCurrentPage,
                        playbackSpeed: playbackSpeed,
                        fillMode: fillMode,
                        seekRequestSeconds: $seekRequestSeconds,
                        onTimeUpdate: onTimeUpdate
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                } else if let fullImage {
                    ZoomableScrollImageView(image: fullImage, isZoomed: $isZoomed, fillMode: fillMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .ignoresSafeArea(.all)
        .task(id: "\(mediaURL.path)#\(thumbRevision)") {
            if item.mediaType == .video {
                guard let posterURL = thumbURL else { return }
                let hdKey = RetinaThumbnailCache.cacheKey(url: posterURL, revision: thumbRevision, maxPixelSize: 2048)
                if let cachedHD = RetinaThumbnailCache.shared.image(forKey: hdKey) {
                    self.posterImage = cachedHD
                    return
                }
                let cardKey = RetinaThumbnailCache.cacheKey(url: posterURL, revision: thumbRevision, maxPixelSize: 720)
                if self.posterImage == nil, let quickPreview = RetinaThumbnailCache.shared.image(forKey: cardKey) {
                    self.posterImage = quickPreview
                }
                let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: posterURL.path)
                }.value
                guard !Task.isCancelled else { return }
                if let loaded {
                    RetinaThumbnailCache.shared.setImage(loaded, forKey: hdKey)
                    await MainActor.run {
                        self.posterImage = loaded
                    }
                }
            } else {
                let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
                    let opts: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ]
                    if let src = CGImageSourceCreateWithURL(mediaURL as CFURL, nil),
                       let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                        let img = UIImage(cgImage: cg)
                        return img.preparingForDisplay() ?? img
                    }
                    guard let fallback = UIImage(contentsOfFile: mediaURL.path) else { return nil }
                    return fallback.preparingForDisplay() ?? fallback
                }.value
                await MainActor.run {
                    self.fullImage = loaded
                }
            }
        }
    }
}
