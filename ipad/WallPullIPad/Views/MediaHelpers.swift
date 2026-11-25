import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StickerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct CheckerboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    var squareSize: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let light = colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.92)
            let dark = colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.84)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            let cols = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            for r in 0..<rows {
                for c in 0..<cols where (r + c).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(c) * squareSize,
                        y: CGFloat(r) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(Path(rect), with: .color(dark))
                }
            }
        }
    }
}

// MARK: - Trilinear Retina Card Thumbnail View (UIKit mipmapped + async off-main predecode)
struct RetinaCardImageView: View {
    let url: URL
    let isCutout: Bool
    let revision: Int
    @State private var decodedImage: UIImage? = nil

    var body: some View {
        ZStack {
            if let decodedImage {
                TrilinearUIImageView(image: decodedImage, isCutout: isCutout)
            } else {
                Color.clear
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: "\(url.path)#\(revision)") {
            let cacheKey = "\(url.path)#\(revision)"
            if let cached = RetinaThumbnailCache.shared.image(forKey: cacheKey) {
                self.decodedImage = cached
                return
            }
            let fileURL = url
            let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
                let opts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 960,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    let img = UIImage(cgImage: cg)
                    return img.preparingForDisplay() ?? img
                }
                guard let ui = UIImage(contentsOfFile: fileURL.path) else { return nil }
                return ui.preparingForDisplay() ?? ui
            }.value
            if let loaded {
                RetinaThumbnailCache.shared.setImage(loaded, forKey: cacheKey)
            }
            await MainActor.run {
                self.decodedImage = loaded
            }
        }
    }
}

final class ZeroIntrinsicImageContainerView: UIView {
    let imageView = UIImageView()
    var isCutout: Bool = false {
        didSet {
            if oldValue != isCutout {
                imageView.contentMode = isCutout ? .scaleAspectFit : .scaleAspectFill
                setNeedsLayout()
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        imageView.layer.contentsScale = UIScreen.main.scale
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = isCutout ? bounds.insetBy(dx: 8, dy: 8) : bounds
    }
}

private struct TrilinearUIImageView: UIViewRepresentable {
    let image: UIImage
    let isCutout: Bool

    func makeUIView(context: Context) -> ZeroIntrinsicImageContainerView {
        let container = ZeroIntrinsicImageContainerView()
        container.isCutout = isCutout
        container.imageView.image = image
        return container
    }

    func updateUIView(_ uiView: ZeroIntrinsicImageContainerView, context: Context) {
        if uiView.imageView.image !== image {
            uiView.imageView.image = image
        }
        uiView.isCutout = isCutout
    }
}

// MARK: - Native UIKit Popover Share Button (fixes Screenshot 6 infinite loop & UUID name)
enum WallPullShareHelper {
    static func cleanShareURLs(for sources: [(url: URL, suggestedName: String)]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WallPullShare", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var usedNames: Set<String> = []
        var out: [URL] = []
        for src in sources {
            guard FileManager.default.fileExists(atPath: src.url.path) else { continue }
            let ext = src.url.pathExtension.isEmpty ? "png" : src.url.pathExtension
            let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n")
            var stem = src.suggestedName.components(separatedBy: invalidChars).joined(separator: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stem.isEmpty { stem = "WallPull" }
            var candidate = "\(stem).\(ext)"
            var suffix = 2
            while usedNames.contains(candidate) {
                candidate = "\(stem) (\(suffix)).\(ext)"
                suffix += 1
            }
            usedNames.insert(candidate)
            let dst = dir.appendingPathComponent(candidate)
            if (try? FileManager.default.linkItem(at: src.url, to: dst)) == nil {
                try? FileManager.default.copyItem(at: src.url, to: dst)
            }
            if FileManager.default.fileExists(atPath: dst.path) {
                out.append(dst)
            } else {
                out.append(src.url)
            }
        }
        return out
    }
}

private struct UIKitShareAnchorView: UIViewRepresentable {
    final class AnchorView: UIView {
        var onPresentReady: ((AnchorView) -> Void)?
    }

    let onReady: (UIView) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { onReady(v) }
        return v
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        DispatchQueue.main.async { onReady(uiView) }
    }
}

struct UIKitSharePopoverButton<Label: View>: View {
    let buildShareItems: () -> [Any]
    @ViewBuilder let label: () -> Label

    @State private var anchorView: UIView? = nil

    var body: some View {
        Button {
            presentActivitySheet()
        } label: {
            label()
                .background(UIKitShareAnchorView { view in
                    anchorView = view
                })
        }
        .buttonStyle(StickerPressButtonStyle())
    }

    private func presentActivitySheet() {
        let items = buildShareItems()
        guard !items.isEmpty else { return }
        guard let hostVC = Self.topViewController(startingFrom: anchorView?.window?.rootViewController) else {
            return
        }
        if hostVC.presentedViewController is UIActivityViewController {
            return
        }
        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = ac.popoverPresentationController {
            if let anchor = anchorView {
                pop.sourceView = anchor
                pop.sourceRect = anchor.bounds
            } else {
                pop.sourceView = hostVC.view
                pop.sourceRect = CGRect(x: hostVC.view.bounds.midX, y: 80, width: 1, height: 1)
            }
            pop.permittedArrowDirections = [.up, .down]
        }
        hostVC.present(ac, animated: true)
    }

    private static func topViewController(startingFrom root: UIViewController?) -> UIViewController? {
        let base = root ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var top = base
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }
}

// MARK: - True Edge-to-Edge Zoomable & Pannable Image View (fixes Screenshot 2 fillMode)
struct ZoomableScrollImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    var fillMode: Bool = false

    final class ZoomContainerScrollView: UIScrollView {
        weak var zoomTarget: UIImageView?
        var fillModeEnabled: Bool = false
        private var lastBoundsSize: CGSize = .zero
        private var lastFillMode: Bool = false
        private var lastImageSize: CGSize = .zero

        func layoutImageFrameIfNeeded(force: Bool = false) {
            guard let iv = zoomTarget, bounds.size != .zero else { return }
            let imgSize = iv.image?.size ?? .zero
            if !force && bounds.size == lastBoundsSize && fillModeEnabled == lastFillMode && imgSize == lastImageSize {
                return
            }
            lastBoundsSize = bounds.size
            lastFillMode = fillModeEnabled
            lastImageSize = imgSize

            guard zoomScale <= 1.01 else { return }
            if fillModeEnabled && imgSize.width > 1 && imgSize.height > 1 {
                let scale = max(bounds.width / imgSize.width, bounds.height / imgSize.height)
                let fittedW = max(bounds.width, imgSize.width * scale)
                let fittedH = max(bounds.height, imgSize.height * scale)
                iv.frame = CGRect(x: 0, y: 0, width: fittedW, height: fittedH)
                contentSize = CGSize(width: fittedW, height: fittedH)
                contentOffset = CGPoint(
                    x: max(0, (fittedW - bounds.width) * 0.5),
                    y: max(0, (fittedH - bounds.height) * 0.5)
                )
            } else {
                iv.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
                contentOffset = .zero
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutImageFrameIfNeeded()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    func makeUIView(context: Context) -> ZoomContainerScrollView {
        let scroll = ZoomContainerScrollView()
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 5.0
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .fast
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.fillModeEnabled = fillMode

        let imageView = UIImageView(image: image)
        imageView.contentMode = fillMode ? .scaleAspectFill : .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        scroll.addSubview(imageView)
        scroll.zoomTarget = imageView

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ uiView: ZoomContainerScrollView, context: Context) {
        guard let iv = context.coordinator.imageView else { return }
        var needsRelayout = false
        if iv.image !== image {
            iv.image = image
            uiView.setZoomScale(1.0, animated: false)
            needsRelayout = true
            DispatchQueue.main.async {
                if isZoomed { isZoomed = false }
            }
        }
        if uiView.fillModeEnabled != fillMode {
            uiView.fillModeEnabled = fillMode
            iv.contentMode = fillMode ? .scaleAspectFill : .scaleAspectFit
            uiView.setZoomScale(1.0, animated: false)
            needsRelayout = true
        }
        uiView.layoutImageFrameIfNeeded(force: needsRelayout)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isZoomed: Bool
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        init(isZoomed: Binding<Bool>) {
            self._isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.04
            if isZoomed != zoomed {
                DispatchQueue.main.async {
                    self.isZoomed = zoomed
                }
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView, let iv = imageView else { return }
            if scroll.zoomScale > 1.05 {
                scroll.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: iv)
                let scale: CGFloat = 2.4
                let w = scroll.bounds.width / scale
                let h = scroll.bounds.height / scale
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - Viewport-Driven & Self-Healing Video Preview Coordinator
@MainActor
final class GalleryVideoPreviewCoordinator {
    static let shared = GalleryVideoPreviewCoordinator()

    private let maxSlots = 8
    private let maxRawFallbackSlots = 3
    private var entries: [ObjectIdentifier: GalleryInlineVideoView.Coordinator] = [:]
    private var watchdogTimer: Timer?
    private var pendingRebalance: DispatchWorkItem?
    private var globallyPaused = false

    func register(_ coord: GalleryInlineVideoView.Coordinator) {
        let key = ObjectIdentifier(coord)
        entries[key] = coord
        pruneDeadEntries()
        if !globallyPaused {
            ensureTimerRunning()
        }
        scheduleRebalance(delay: 0.08)
    }

    func unregister(_ coord: GalleryInlineVideoView.Coordinator) {
        let key = ObjectIdentifier(coord)
        entries.removeValue(forKey: key)
        coord.teardownPlayer()
        pruneDeadEntries()
        if entries.isEmpty {
            stopTimer()
        } else {
            scheduleRebalance(delay: 0.06)
        }
    }

    func setGloballyPaused(_ paused: Bool) {
        globallyPaused = paused
        if paused {
            pendingRebalance?.cancel()
            pendingRebalance = nil
            stopTimer()
            for coord in entries.values {
                coord.teardownPlayer()
            }
        } else if !entries.isEmpty {
            ensureTimerRunning()
            scheduleRebalance(delay: 0.08)
        }
    }

    func releaseAll() {
        pendingRebalance?.cancel()
        pendingRebalance = nil
        for coord in entries.values {
            coord.teardownPlayer()
        }
    }

    private func ensureTimerRunning() {
        guard watchdogTimer == nil else { return }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebalanceNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopTimer() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func scheduleRebalance(delay: TimeInterval) {
        pendingRebalance?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebalanceNow()
        }
        pendingRebalance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pruneDeadEntries() {
        entries = entries.filter { _, coord in
            coord.playerView != nil
        }
    }

    func rebalanceNow() {
        pruneDeadEntries()
        if entries.isEmpty {
            stopTimer()
            return
        }
        if globallyPaused {
            for coord in entries.values {
                coord.teardownPlayer()
            }
            return
        }

        struct Candidate {
            let key: ObjectIdentifier
            let coord: GalleryInlineVideoView.Coordinator
            let minY: CGFloat
            let minX: CGFloat
            let isRawFallback: Bool
        }

        var visibleCandidates: [Candidate] = []
        var offscreenCoords: [GalleryInlineVideoView.Coordinator] = []

        for (key, coord) in entries {
            guard coord.isCurrentlyActive,
                  let pv = coord.playerView,
                  let win = pv.window,
                  !pv.isHidden,
                  pv.bounds.width > 10,
                  pv.bounds.height > 10 else {
                offscreenCoords.append(coord)
                continue
            }
            let rectInWin = pv.convert(pv.bounds, to: win)
            let inter = win.bounds.intersection(rectInWin)
            let area = max(1.0, rectInWin.width * rectInWin.height)
            let visibleRatio = (inter.width * inter.height) / area
            if visibleRatio >= 0.08 {
                let isRaw = (coord.targetURL != nil && coord.targetURL == coord.fallbackURL)
                visibleCandidates.append(Candidate(
                    key: key,
                    coord: coord,
                    minY: rectInWin.minY,
                    minX: rectInWin.minX,
                    isRawFallback: isRaw
                ))
            } else {
                offscreenCoords.append(coord)
            }
        }

        for coord in offscreenCoords {
            coord.teardownPlayer()
        }

        visibleCandidates.sort { lhs, rhs in
            let rowL = Int((lhs.minY / 32.0).rounded())
            let rowR = Int((rhs.minY / 32.0).rounded())
            if rowL != rowR { return rowL < rowR }
            if abs(lhs.minX - rhs.minX) > 8 { return lhs.minX < rhs.minX }
            return lhs.coord.cardID < rhs.coord.cardID
        }

        var winners: [Candidate] = []
        var rawFallbackCount = 0
        for cand in visibleCandidates {
            if winners.count >= maxSlots { break }
            if cand.isRawFallback {
                if rawFallbackCount >= maxRawFallbackSlots { continue }
                rawFallbackCount += 1
            }
            winners.append(cand)
        }

        let winnerKeys = Set(winners.map(\.key))
        for (key, coord) in entries where !winnerKeys.contains(key) {
            coord.teardownPlayer()
        }

        for cand in winners {
            let coord = cand.coord
            guard let targetURL = coord.targetURL, let pv = coord.playerView else { continue }
            let needsFreshSetup = coord.player == nil
                || (coord.boundTargetURL != targetURL && coord.failedPrimaryURL != targetURL)

            if needsFreshSetup {
                coord.setupPlayer(url: targetURL, fallback: coord.fallbackURL, in: pv)
                continue
            }

            guard let p = coord.player, let item = p.currentItem else { continue }
            p.isMuted = true
            if pv.playerLayer.isReadyForDisplay && pv.alpha < 1.0 {
                pv.alpha = 1.0
            }
            if item.status == .readyToPlay {
                let curSec = CMTimeGetSeconds(p.currentTime())
                let durSec = CMTimeGetSeconds(item.duration)
                if durSec.isFinite && durSec > 0.25 && curSec.isFinite && curSec >= durSec - 0.05 && p.rate == 0 {
                    p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak coord, weak p] finished in
                        Task { @MainActor [weak coord, weak p] in
                            guard finished, let coord, let p, coord.isCurrentlyActive, coord.player === p else { return }
                            p.play()
                        }
                    }
                    continue
                }
                if p.rate == 0 {
                    p.play()
                }
                if curSec.isFinite {
                    if abs(curSec - coord.lastObservedSeconds) < 0.005 {
                        coord.stalledTicks += 1
                        if coord.stalledTicks >= 5 {
                            coord.stalledTicks = 0
                            coord.setupPlayer(url: coord.currentURL ?? targetURL, fallback: coord.fallbackURL, in: pv)
                        }
                    } else {
                        coord.lastObservedSeconds = curSec
                        coord.stalledTicks = 0
                    }
                }
            } else if item.status == .failed {
                if let fb = coord.fallbackURL, coord.currentURL != fb {
                    coord.failedPrimaryURL = coord.boundTargetURL
                    coord.setupPlayer(url: fb, fallback: nil, in: pv)
                } else {
                    coord.stalledTicks += 1
                    if coord.stalledTicks >= 4 {
                        coord.stalledTicks = 0
                        coord.setupPlayer(url: targetURL, fallback: coord.fallbackURL, in: pv)
                    }
                }
            }
        }
    }
}

struct GalleryInlineVideoView: UIViewRepresentable {
    let id: String
    let url: URL
    var fallbackURL: URL? = nil
    let isActive: Bool

    @MainActor
    final class Coordinator {
        var cardID: String = ""
        var player: AVPlayer?
        var readyForDisplayObs: NSKeyValueObservation?
        var statusObs: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
        var currentURL: URL?
        var boundTargetURL: URL?
        var targetURL: URL?
        var fallbackURL: URL?
        var failedPrimaryURL: URL?
        var isCurrentlyActive: Bool = false
        var lastObservedSeconds: Double = -1
        var stalledTicks: Int = 0
        weak var playerView: PlayerView?

        func setupPlayer(url playURL: URL, fallback: URL?, in view: PlayerView) {
            teardownPlayer()
            if AVAudioSession.sharedInstance().category == .soloAmbient {
                try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            let asset = AVURLAsset(url: playURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 1.2
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = true
            newPlayer.actionAtItemEnd = .none
            newPlayer.preventsDisplaySleepDuringVideoPlayback = false
            newPlayer.automaticallyWaitsToMinimizeStalling = false

            player = newPlayer
            currentURL = playURL
            boundTargetURL = targetURL
            fallbackURL = fallback
            lastObservedSeconds = -1
            stalledTicks = 0
            view.playerLayer.player = newPlayer
            view.playerLayer.videoGravity = .resizeAspectFill

            readyForDisplayObs = view.playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak view] layer, _ in
                if layer.isReadyForDisplay {
                    DispatchQueue.main.async {
                        UIView.animate(withDuration: 0.16) {
                            view?.alpha = 1.0
                        }
                    }
                }
            }

            statusObs = item.observe(\.status, options: [.new, .initial]) { [weak view, weak self, weak newPlayer] observed, _ in
                Task { @MainActor [weak self, weak view, weak newPlayer] in
                    guard let self, let newPlayer, self.player === newPlayer else { return }
                    if observed.status == .readyToPlay {
                        guard self.isCurrentlyActive else { return }
                        newPlayer.isMuted = true
                        newPlayer.play()
                        if view?.playerLayer.isReadyForDisplay == true {
                            UIView.animate(withDuration: 0.16) {
                                view?.alpha = 1.0
                            }
                        }
                    } else if observed.status == .failed {
                        guard self.isCurrentlyActive,
                              let pv = view,
                              let fb = self.fallbackURL,
                              self.currentURL != fb else { return }
                        self.failedPrimaryURL = self.boundTargetURL
                        self.setupPlayer(url: fb, fallback: nil, in: pv)
                    }
                }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak newPlayer] _ in
                Task { @MainActor [weak self, weak newPlayer] in
                    guard let self, let newPlayer, self.isCurrentlyActive, self.player === newPlayer else { return }
                    newPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak newPlayer] finished in
                        Task { @MainActor [weak self, weak newPlayer] in
                            guard finished, let self, let newPlayer, self.isCurrentlyActive, self.player === newPlayer else { return }
                            newPlayer.play()
                        }
                    }
                }
            }

            newPlayer.play()
        }

        func teardownPlayer() {
            readyForDisplayObs?.invalidate()
            readyForDisplayObs = nil
            statusObs?.invalidate()
            statusObs = nil
            if let obs = endObserver {
                NotificationCenter.default.removeObserver(obs)
                endObserver = nil
            }
            player?.pause()
            player = nil
            currentURL = nil
            boundTargetURL = nil
            lastObservedSeconds = -1
            stalledTicks = 0
            playerView?.playerLayer.player = nil
            playerView?.alpha = 0
        }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .clear
        v.alpha = 0
        v.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.playerView = v
        context.coordinator.cardID = id
        context.coordinator.targetURL = url
        context.coordinator.fallbackURL = fallbackURL
        context.coordinator.isCurrentlyActive = isActive
        GalleryVideoPreviewCoordinator.shared.register(context.coordinator)
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        let coord = context.coordinator
        let idChanged = !coord.cardID.isEmpty && coord.cardID != id
        if idChanged {
            coord.teardownPlayer()
            coord.failedPrimaryURL = nil
        }

        let targetChanged = coord.targetURL != url
        if targetChanged {
            coord.failedPrimaryURL = nil
        }

        coord.playerView = uiView
        coord.cardID = id
        coord.targetURL = url
        coord.fallbackURL = fallbackURL
        coord.isCurrentlyActive = isActive

        if !isActive {
            coord.teardownPlayer()
            GalleryVideoPreviewCoordinator.shared.register(coord)
            return
        }

        GalleryVideoPreviewCoordinator.shared.register(coord)
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        coordinator.isCurrentlyActive = false
        GalleryVideoPreviewCoordinator.shared.unregister(coordinator)
    }
}

/// Interactive detail-page video player with scrubbing, playback rate, fill toggle & automatic fallback
struct InlineLoopVideoView: UIViewRepresentable {
    let url: URL
    var fallbackURL: URL? = nil
    let muted: Bool
    let isPlaying: Bool
    var isCurrentPage: Bool = true
    let playbackSpeed: Float
    let fillMode: Bool
    @Binding var seekRequestSeconds: Double?
    var onTimeUpdate: ((Double, Double) -> Void)? = nil

    final class Coordinator {
        var player: AVPlayer?
        var currentURL: URL?
        var boundTargetURL: URL?
        var fallbackURL: URL?
        var timeObserver: Any?
        var readyForDisplayObs: NSKeyValueObservation?
        var statusObs: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
        var desiredPlaying: Bool = true
        var desiredRate: Float = 1.0
        var lastMuted: Bool = true
        var onTimeUpdate: ((Double, Double) -> Void)?
        weak var playerView: PlayerContainerView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .clear
        view.alpha = 0
        context.coordinator.playerView = view
        context.coordinator.onTimeUpdate = onTimeUpdate
        context.coordinator.desiredPlaying = isPlaying
        context.coordinator.desiredRate = playbackSpeed
        context.coordinator.lastMuted = muted
        if isCurrentPage {
            configure(url: url, boundTarget: url, fallback: fallbackURL, view: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        let coord = context.coordinator
        coord.playerView = uiView
        coord.onTimeUpdate = onTimeUpdate
        coord.desiredPlaying = isPlaying
        coord.desiredRate = playbackSpeed
        coord.fallbackURL = fallbackURL

        if !isCurrentPage {
            Self.teardown(coordinator: coord)
            return
        }

        if coord.player == nil || coord.boundTargetURL != url {
            configure(url: url, boundTarget: url, fallback: fallbackURL, view: uiView, coordinator: coord)
        }

        uiView.playerLayer.videoGravity = fillMode ? .resizeAspectFill : .resizeAspect
        guard let p = coord.player else { return }

        if coord.lastMuted != muted {
            coord.lastMuted = muted
            if !muted {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
        p.isMuted = muted

        if let seekSec = seekRequestSeconds {
            let cm = CMTime(seconds: max(0, seekSec), preferredTimescale: 600)
            p.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
            DispatchQueue.main.async {
                seekRequestSeconds = nil
            }
        }

        if isPlaying {
            if p.currentItem?.status == .readyToPlay && abs(p.rate - playbackSpeed) > 0.01 {
                p.playImmediately(atRate: playbackSpeed)
            }
        } else if p.rate != 0 {
            p.pause()
        }

        if uiView.playerLayer.isReadyForDisplay && uiView.alpha < 1.0 {
            uiView.alpha = 1.0
        }
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        teardown(coordinator: coordinator)
    }

    private func configure(url targetURL: URL, boundTarget: URL, fallback: URL?, view: PlayerContainerView, coordinator: Coordinator) {
        Self.teardown(coordinator: coordinator)

        if !muted {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
        } else if AVAudioSession.sharedInstance().category == .soloAmbient {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }

        let asset = AVURLAsset(url: targetURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false

        coordinator.player = player
        coordinator.currentURL = targetURL
        coordinator.boundTargetURL = boundTarget
        coordinator.fallbackURL = fallback
        view.alpha = 0
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fillMode ? .resizeAspectFill : .resizeAspect

        coordinator.readyForDisplayObs = view.playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak view] layer, _ in
            if layer.isReadyForDisplay {
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.18) {
                        view?.alpha = 1.0
                    }
                }
            }
        }

        coordinator.statusObs = item.observe(\.status, options: [.new, .initial]) { [weak view, weak coordinator] observed, _ in
            guard let coordinator else { return }
            if observed.status == .readyToPlay {
                DispatchQueue.main.async {
                    let dur = CMTimeGetSeconds(observed.duration)
                    if dur.isFinite && dur > 0 {
                        coordinator.onTimeUpdate?(0, dur)
                    }
                    if coordinator.desiredPlaying {
                        coordinator.player?.playImmediately(atRate: coordinator.desiredRate)
                    }
                    if view?.playerLayer.isReadyForDisplay == true {
                        UIView.animate(withDuration: 0.18) {
                            view?.alpha = 1.0
                        }
                    }
                }
            } else if observed.status == .failed {
                DispatchQueue.main.async {
                    guard let pv = view,
                          let fb = coordinator.fallbackURL,
                          coordinator.currentURL != fb else { return }
                    self.configure(url: fb, boundTarget: boundTarget, fallback: nil, view: pv, coordinator: coordinator)
                }
            }
        }

        coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak coordinator] _ in
            guard let coordinator, let p = coordinator.player else { return }
            p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                guard finished, coordinator.player === p, coordinator.desiredPlaying else { return }
                p.playImmediately(atRate: coordinator.desiredRate)
            }
        }

        coordinator.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { [weak coordinator] cmTime in
            guard let coordinator, let curItem = coordinator.player?.currentItem else { return }
            let cur = CMTimeGetSeconds(cmTime)
            let dur = CMTimeGetSeconds(curItem.duration)
            if cur.isFinite {
                let dVal = dur.isFinite && dur > 0 ? dur : 0
                coordinator.onTimeUpdate?(max(0, cur), dVal)
            }
        }

        if isPlaying {
            player.playImmediately(atRate: playbackSpeed)
        }
    }

    private static func teardown(coordinator: Coordinator) {
        coordinator.readyForDisplayObs?.invalidate()
        coordinator.readyForDisplayObs = nil
        coordinator.statusObs?.invalidate()
        coordinator.statusObs = nil
        if let endObs = coordinator.endObserver {
            NotificationCenter.default.removeObserver(endObs)
            coordinator.endObserver = nil
        }
        if let obs = coordinator.timeObserver, let p = coordinator.player {
            p.removeTimeObserver(obs)
        }
        coordinator.timeObserver = nil
        coordinator.player?.pause()
        coordinator.player = nil
        coordinator.currentURL = nil
        coordinator.boundTargetURL = nil
        coordinator.playerView?.playerLayer.player = nil
        coordinator.playerView?.alpha = 0
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct ClampedBadgeTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.text = text
        tf.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        tf.borderStyle = .none
        tf.clearButtonMode = .whileEditing
        tf.returnKeyType = .done
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.delegate = context.coordinator
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.text = $text
        if uiView.markedTextRange == nil && uiView.text != text {
            uiView.text = text
        }
        if uiView.placeholder != placeholder {
            uiView.placeholder = placeholder
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func editingChanged(_ sender: UITextField) {
            guard sender.markedTextRange == nil else { return }
            let raw = sender.text ?? ""
            let clamped = LocalVaultStore.clampDisconnectedBadgeText(raw)
            if sender.text != clamped {
                sender.text = clamped
            }
            if text.wrappedValue != clamped {
                text.wrappedValue = clamped
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            let clamped = LocalVaultStore.clampDisconnectedBadgeText(textField.text ?? "")
            if textField.text != clamped {
                textField.text = clamped
            }
            if text.wrappedValue != clamped {
                text.wrappedValue = clamped
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

struct LANThumbView: View {
    let item: PCCatalogItem
    let peer: LocalSendPeer
    @ObservedObject var localSend: LocalSendService
    @State private var image: UIImage? = nil

    var body: some View {
        Color.clear
            .overlay(
                ZStack {
                    Color(.secondarySystemBackground)
                    if let image {
                        TrilinearUIImageView(image: image, isCutout: false)
                    } else {
                        Image(systemName: item.isVideo ? "film" : "photo")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                }
            )
            .clipped()
            .task(id: "\(peer.ip):\(item.id)") {
                if let ui = await localSend.loadCachedPCThumb(for: item, peer: peer) {
                    self.image = ui
                }
            }
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onPickedURLs: ([URL], [String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPickedURLs: onPickedURLs) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos])
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPickedURLs: ([URL], [String]) -> Void

        init(onPickedURLs: @escaping ([URL], [String]) -> Void) {
            self.onPickedURLs = onPickedURLs
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            let group = DispatchGroup()
            var urls: [URL] = []
            var names: [String] = []
            let lock = NSLock()

            for res in results {
                let provider = res.itemProvider
                let typeID: String?
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    typeID = UTType.movie.identifier
                } else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                    typeID = UTType.png.identifier
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    typeID = UTType.image.identifier
                } else {
                    typeID = nil
                }
                guard let uti = typeID else { continue }
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: uti) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
                    let dst = FileManager.default.temporaryDirectory
                        .appendingPathComponent("wp_pick_\(UUID().uuidString).\(ext)")
                    if (try? FileManager.default.copyItem(at: url, to: dst)) != nil {
                        let resolvedName: String
                        if let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !suggested.isEmpty {
                            let lowerExt = ".\(ext.lowercased())"
                            resolvedName = suggested.lowercased().hasSuffix(lowerExt) ? suggested : "\(suggested).\(ext)"
                        } else {
                            resolvedName = url.lastPathComponent
                        }
                        lock.lock()
                        urls.append(dst)
                        names.append(resolvedName)
                        lock.unlock()
                    }
                }
            }
            group.notify(queue: .main) {
                self.onPickedURLs(urls, names)
            }
        }
    }
}
