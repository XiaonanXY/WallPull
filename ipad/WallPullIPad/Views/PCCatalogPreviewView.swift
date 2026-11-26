import SwiftUI
import UIKit

struct PCCatalogPreviewSession: Identifiable {
    let id: String
    let catalogList: [PCCatalogItem]
    let peer: LocalSendPeer
}

@MainActor
private final class RemoteFullImageCache {
    static let shared = RemoteFullImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 10
        cache.totalCostLimit = 180 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ img: UIImage, forKey key: String) {
        let px = Int(img.size.width * img.scale * img.size.height * img.scale)
        cache.setObject(img, forKey: key as NSString, cost: max(1, px * 4))
    }
}

struct PCCatalogPreviewView: View {
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    var musicPlayer: MusicPlayerManager = .idlePlaceholder
    let peer: LocalSendPeer
    let catalogList: [PCCatalogItem]
    @State var currentID: String
    var isClosing: Bool = false
    var onCurrentIDChanged: ((String) -> Void)? = nil
    let onClose: () -> Void

    @State private var isCleanImmersive: Bool = false
    @State private var fillMode: Bool = false
    @State private var isMuted: Bool = false
    @State private var videoPlaying: Bool = true
    @State private var videoSpeed: Float = 1.0
    @State private var videoCurrentSec: Double = 0
    @State private var videoDurationSec: Double = 0
    @State private var videoSeekRequest: Double? = nil
    @State private var isScrubbingVideo: Bool = false
    @State private var isCurrentPageZoomed: Bool = false
    @State private var dragDismissOffset: CGFloat = 0
    @State private var selectedVariantIdx: Int = 0
    @State private var pullingID: String? = nil
    @State private var loadedImageKey: String? = nil

    private var currentItem: PCCatalogItem? {
        catalogList.first(where: { $0.id == currentID }) ?? catalogList.first
    }

    private var dismissProgress: Double {
        min(1.0, max(0.0, Double(dragDismissOffset) / 240.0))
    }

    private var windowSafeInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .opacity(1.0 - dismissProgress * 0.55)
                .ignoresSafeArea(.all)

            TabView(selection: $currentID) {
                ForEach(catalogList) { item in
                    let vIdx = (item.id == currentID) ? selectedVariantIdx : 0
                    RemoteCatalogMediaPage(
                        item: item,
                        variantIndex: vIdx,
                        peer: peer,
                        localSend: localSend,
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
                        },
                        onFullImageLoaded: { key in
                            loadedImageKey = key
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
            .onChange(of: currentID) { newID in
                isCurrentPageZoomed = false
                videoCurrentSec = 0
                videoDurationSec = 0
                videoPlaying = true
                selectedVariantIdx = 0
                if !isMuted && currentItem?.isVideo == true && musicPlayer.isPlaying {
                    musicPlayer.pausePlayback()
                }
                onCurrentIDChanged?(newID)
            }

            if let item = currentItem, !isCleanImmersive {
                VStack {
                    topBar(item: item)
                        .environment(\.colorScheme, .dark)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                    VStack(spacing: 10) {
                        if item.isVideo {
                            videoControlsBar(item: item)
                        }
                        if !item.isVideo && (item.assetCount ?? 1) > 1 {
                            variantSwitcherBar(item: item)
                        }
                        bottomDock(item: item)
                    }
                    .environment(\.colorScheme, .dark)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .opacity(1.0 - dismissProgress * 1.4)
            }
        }
        .statusBar(hidden: fillMode || isCleanImmersive)
        .onAppear {
            if !isMuted && currentItem?.isVideo == true && musicPlayer.isPlaying {
                musicPlayer.pausePlayback()
            }
        }
    }

    private func topBar(item: PCCatalogItem) -> some View {
        let crLower = (item.contentRating ?? "everyone").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if item.isPCFavorite {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("电脑收藏")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(hex: "#FF4D6D").opacity(0.92), in: Capsule())
                    }
                    if crLower == "mature" {
                        Text("18+")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#EF4444").opacity(0.92), in: Capsule())
                    } else if crLower == "questionable" {
                        Text("擦边")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.92), in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    if let res = item.resolution { Text(res) }
                    Text(formatFileSize(item.fileSize))
                    if (item.assetCount ?? 1) > 1 { Text("\(item.assetCount ?? 1) 张差分") }
                    if item.supportsStudio { Text("✦ 可拆图层") }
                    if item.hasMusic { Text("♪ 含配乐") }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(Color.white.opacity(0.68))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.14), in: Capsule())

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.22)) { fillMode.toggle() }
            } label: {
                Label(fillMode ? "适应屏幕" : "铺满全屏", systemImage: fillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(fillMode ? vault.accentColor : Color.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(StickerPressButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, max(windowSafeInsets.top, 26) + 8)
    }

    private func fmtClock(_ s: Double) -> String {
        guard s.isFinite && s > 0 else { return "0:00" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func videoControlsBar(item: PCCatalogItem) -> some View {
        let total = max(videoDurationSec, 1.0)
        return HStack(spacing: 12) {
            Button {
                videoPlaying.toggle()
            } label: {
                Image(systemName: videoPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())

            Text(fmtClock(videoCurrentSec))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.85))
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
                .foregroundColor(Color.white.opacity(0.65))
                .frame(width: 40, alignment: .leading)

            Button {
                if videoSpeed == 1.0 { videoSpeed = 1.5 }
                else if videoSpeed == 1.5 { videoSpeed = 0.5 }
                else { videoSpeed = 1.0 }
            } label: {
                Text(videoSpeed == 1.0 ? "1.0x" : (videoSpeed == 1.5 ? "1.5x" : "0.5x"))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.14), in: Capsule())
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
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func variantSwitcherBar(item: PCCatalogItem) -> some View {
        let count = max(1, item.assetCount ?? 1)
        return HStack(spacing: 8) {
            Text("原画差分 \(selectedVariantIdx + 1)/\(count)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.85))
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
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(active ? vault.accentColor : Color.white.opacity(0.14), in: Capsule())
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
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func bottomDock(item: PCCatalogItem) -> some View {
        let owned = vault.hasImportedCatalogItem(item)
        let isPulling = pullingID == item.id || localSend.activePullIDs.contains(item.id)
        let fullKey = "\(peer.ip):\(item.id):\(selectedVariantIdx)"
        let _ = loadedImageKey
        let loadedImg = RemoteFullImageCache.shared.image(forKey: fullKey)

        return HStack {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if owned {
                    Label("已在平板库中", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.86), in: Capsule())
                } else {
                    Button {
                        pullingID = item.id
                        Task {
                            await localSend.pullCatalogItemsToVault([item], from: peer)
                            if pullingID == item.id {
                                pullingID = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isPulling {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isPulling ? "正在收入平板…" : "收入平板")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(vault.accentColor, in: Capsule())
                    }
                    .disabled(pullingID != nil)
                    .buttonStyle(StickerPressButtonStyle())
                }

                if !item.isVideo, let loadedImg {
                    Button {
                        vault.copyUIImageLosslessToClipboard(loadedImg)
                    } label: {
                        Label("复制原图（贴微信）", systemImage: "doc.on.doc.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, max(windowSafeInsets.bottom, 16) + 6)
    }
}

private struct RemoteCatalogMediaPage: View {
    let item: PCCatalogItem
    let variantIndex: Int
    let peer: LocalSendPeer
    @ObservedObject var localSend: LocalSendService
    let muted: Bool
    let isPlaying: Bool
    let isCurrentPage: Bool
    let playbackSpeed: Float
    let fillMode: Bool
    @Binding var seekRequestSeconds: Double?
    @Binding var isZoomed: Bool
    let onTimeUpdate: (Double, Double) -> Void
    let onFullImageLoaded: (String) -> Void

    @State private var fullImage: UIImage? = nil
    @State private var loadFailed: Bool = false

    private var cacheKey: String {
        "\(peer.ip):\(item.id):\(variantIndex)"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if item.isVideo {
                    if let thumb = localSend.cachedThumbImage(for: item, peer: peer) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: fillMode ? .fill : .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    if let assetURL = localSend.pcAssetURL(for: item, peer: peer, variantIndex: 0) {
                        InlineLoopVideoView(
                            url: assetURL,
                            fallbackURL: localSend.pcPreviewVideoURL(for: item, peer: peer),
                            muted: muted,
                            isPlaying: isPlaying,
                            isCurrentPage: isCurrentPage,
                            playbackSpeed: playbackSpeed,
                            fillMode: fillMode,
                            seekRequestSeconds: $seekRequestSeconds,
                            onTimeUpdate: onTimeUpdate
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else if let fullImage {
                    ZoomableScrollImageView(image: fullImage, isZoomed: $isZoomed, fillMode: fillMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ZStack {
                        if let thumb = localSend.cachedThumbImage(for: item, peer: peer) {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: fillMode ? .fill : .fit)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
                        if loadFailed {
                            Text("电脑原图加载失败，请确认连接正常")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                Text("正在加载高清原图…")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.all)
        .task(id: "\(cacheKey)#\(isCurrentPage)") {
            guard !item.isVideo else { return }
            if let cached = RemoteFullImageCache.shared.image(forKey: cacheKey) {
                self.fullImage = cached
                self.loadFailed = false
                onFullImageLoaded(cacheKey)
                return
            }
            guard isCurrentPage,
                  let url = localSend.pcAssetURL(for: item, peer: peer, variantIndex: variantIndex) else { return }
            loadFailed = false
            var req = URLRequest(url: url, timeoutInterval: 25)
            req.cachePolicy = .returnCacheDataElseLoad
            localSend.applyAuthHeader(&req, for: peer)
            if let (data, resp) = try? await localSend.lanURLSession.data(for: req),
               let http = resp as? HTTPURLResponse {
                if http.statusCode == 401 {
                    localSend.pairingRequiredPeer = peer
                    loadFailed = true
                    return
                }
                if (http.statusCode == 200 || http.statusCode == 206),
                   let decoded = await Task.detached(priority: .userInitiated, operation: {
                       guard let img = UIImage(data: data) else { return nil as UIImage? }
                       return img.preparingForDisplay() ?? img
                   }).value {
                    localSend.touchPeerAlive(fingerprint: peer.fingerprint)
                    RemoteFullImageCache.shared.setImage(decoded, forKey: cacheKey)
                    self.fullImage = decoded
                    onFullImageLoaded(cacheKey)
                } else {
                    loadFailed = true
                }
            } else {
                loadFailed = true
            }
        }
    }
}
