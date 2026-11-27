import AVFoundation
import Combine
import CryptoKit
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

struct StickerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private enum CheckerboardTileCache {
    static let lightTile: UIImage = makeTile(light: UIColor(white: 0.92, alpha: 1), dark: UIColor(white: 0.84, alpha: 1), size: 28)
    static let darkTile: UIImage = makeTile(light: UIColor(white: 0.20, alpha: 1), dark: UIColor(white: 0.14, alpha: 1), size: 28)

    private static func makeTile(light: UIColor, dark: UIColor, size: CGFloat) -> UIImage {
        let half = size * 0.5
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            light.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            dark.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: half, height: half))
            ctx.fill(CGRect(x: half, y: half, width: half, height: half))
        }
    }
}

struct CheckerboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    var squareSize: CGFloat = 14

    var body: some View {
        let tile = colorScheme == .dark ? CheckerboardTileCache.darkTile : CheckerboardTileCache.lightTile
        Image(uiImage: tile)
            .resizable(resizingMode: .tile)
    }
}

private actor AsyncDecodeLimiter {
    static let shared = AsyncDecodeLimiter(limit: 4)
    private let limit: Int
    private var running: Int = 0
    private var waiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    func withSlot<T: Sendable>(_ work: @Sendable () async -> T?) async -> T? {
        let acquired = await acquire()
        guard acquired else { return nil }
        let res = await work()
        release()
        return res
    }

    private func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    waiters.append((id: id, cont: cont))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let entry = waiters.remove(at: idx)
            entry.cont.resume(returning: false)
        }
    }

    private func release() {
        while !waiters.isEmpty {
            let next = waiters.removeLast()
            next.cont.resume(returning: true)
            return
        }
        running = max(0, running - 1)
    }
}

final class PCThumbnailCache: @unchecked Sendable {
    static let shared = PCThumbnailCache()

    private let memCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 420
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()

    private let diskDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("pc_thumbs_v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let decodeOpts: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: 600,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]

    struct FetchResult: Sendable {
        let image: UIImage?
        let unauthorized: Bool
    }

    func image(forKey key: String) -> UIImage? {
        memCache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        let px = Int((image.size.width * image.scale) * (image.size.height * image.scale))
        memCache.setObject(image, forKey: key as NSString, cost: max(1, px * 4))
    }

    func clearAll() {
        memCache.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private func diskFileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent("\(hex).jpg")
    }

    nonisolated static func decodeImage(fromFile url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, decodeOpts as CFDictionary) else {
            return nil
        }
        let img = UIImage(cgImage: cg)
        return img.preparingForDisplay() ?? img
    }

    nonisolated static func decodeImage(fromData data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, decodeOpts as CFDictionary) else {
            guard let raw = UIImage(data: data) else { return nil }
            return raw.preparingForDisplay() ?? raw
        }
        let img = UIImage(cgImage: cg)
        return img.preparingForDisplay() ?? img
    }

    func loadOrFetch(cacheKey: String, request: URLRequest, session: URLSession) async -> FetchResult {
        if let hit = image(forKey: cacheKey) {
            return FetchResult(image: hit, unauthorized: false)
        }
        let diskURL = diskFileURL(forKey: cacheKey)
        let localImg: UIImage? = await AsyncDecodeLimiter.shared.withSlot { () -> UIImage? in
            guard !Task.isCancelled, FileManager.default.fileExists(atPath: diskURL.path) else { return nil }
            return Self.decodeImage(fromFile: diskURL)
        }
        if let localImg {
            setImage(localImg, forKey: cacheKey)
            return FetchResult(image: localImg, unauthorized: false)
        }
        guard !Task.isCancelled else { return FetchResult(image: nil, unauthorized: false) }

        guard let (data, resp) = try? await session.data(for: request),
              let http = resp as? HTTPURLResponse else {
            return FetchResult(image: nil, unauthorized: false)
        }
        if http.statusCode == 401 {
            return FetchResult(image: nil, unauthorized: true)
        }
        guard http.statusCode == 200, !data.isEmpty, !Task.isCancelled else {
            return FetchResult(image: nil, unauthorized: false)
        }

        let decoded: UIImage? = await AsyncDecodeLimiter.shared.withSlot { () -> UIImage? in
            guard !Task.isCancelled else { return nil }
            try? data.write(to: diskURL, options: [.atomic])
            return Self.decodeImage(fromData: data)
        }
        if let decoded {
            setImage(decoded, forKey: cacheKey)
        }
        return FetchResult(image: decoded, unauthorized: false)
    }
}

// MARK: - Trilinear Retina Card Thumbnail View (0-state UIKit sync-cache + off-main bounded predecode)
struct RetinaCardImageView: UIViewRepresentable {
    let url: URL
    let isCutout: Bool
    let revision: Int
    var fallbackSymbol: String = "photo"

    final class Coordinator {
        var currentKey: String = ""
        var failedKey: String = ""
        var loadTask: Task<Void, Never>? = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZeroIntrinsicImageContainerView {
        let view = ZeroIntrinsicImageContainerView()
        apply(view: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: ZeroIntrinsicImageContainerView, context: Context) {
        apply(view: uiView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ uiView: ZeroIntrinsicImageContainerView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        coordinator.currentKey = ""
        coordinator.failedKey = ""
    }

    private func apply(view: ZeroIntrinsicImageContainerView, coordinator: Coordinator) {
        view.isCutout = isCutout
        let key = RetinaThumbnailCache.cacheKey(url: url, revision: revision, maxPixelSize: 720)
        if coordinator.currentKey == key && (view.imageView.image != nil || coordinator.failedKey == key) {
            return
        }
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        coordinator.currentKey = key
        coordinator.failedKey = ""

        if let cached = RetinaThumbnailCache.shared.image(forKey: key) {
            view.setLoadedImage(cached)
            return
        }

        view.showPlaceholder(symbol: nil)
        let fileURL = url
        let sym = fallbackSymbol
        coordinator.loadTask = Task(priority: .userInitiated) {
            let loaded: UIImage? = await AsyncDecodeLimiter.shared.withSlot {
                guard !Task.isCancelled else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 720,
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
            }
            guard !Task.isCancelled else { return }
            if let loaded {
                RetinaThumbnailCache.shared.setImage(loaded, forKey: key)
            }
            await MainActor.run {
                guard coordinator.currentKey == key else { return }
                if let loaded {
                    view.setLoadedImage(loaded)
                } else {
                    coordinator.failedKey = key
                    view.showPlaceholder(symbol: sym)
                }
            }
        }
    }
}

final class ZeroIntrinsicImageContainerView: UIView {
    let imageView = UIImageView()
    private let placeholderView = UIImageView()
    private var lastLayoutBounds: CGRect = .zero
    private var lastLayoutCutout: Bool = false

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

        placeholderView.contentMode = .center
        placeholderView.tintColor = .secondaryLabel.withAlphaComponent(0.55)
        placeholderView.isHidden = true
        addSubview(placeholderView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLoadedImage(_ image: UIImage) {
        if imageView.image !== image {
            imageView.image = image
        }
        placeholderView.isHidden = true
    }

    func showPlaceholder(symbol: String?) {
        imageView.image = nil
        if let symbol, !symbol.isEmpty {
            let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            placeholderView.image = UIImage(systemName: symbol, withConfiguration: cfg)
            placeholderView.isHidden = false
        } else {
            placeholderView.image = nil
            placeholderView.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != lastLayoutBounds || isCutout != lastLayoutCutout {
            lastLayoutBounds = bounds
            lastLayoutCutout = isCutout
            imageView.frame = isCutout ? bounds.insetBy(dx: 8, dy: 8) : bounds
            placeholderView.frame = bounds
        }
    }
}

// MARK: - Native UIKit Popover Share Button (fixes Screenshot 6 infinite loop & UUID name)
enum WallPullShareHelper {
    static func cleanShareURLs(for sources: [(url: URL, suggestedName: String)]) -> [URL] {
        let fm = FileManager.default
        let rootDir = fm.temporaryDirectory.appendingPathComponent("WallPullShare", isDirectory: true)
        try? fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        if let children = try? fm.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let cutoff = Date().addingTimeInterval(-3600)
            for child in children {
                let vals = try? child.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let stamp = vals?.contentModificationDate ?? vals?.creationDate ?? .distantPast
                if stamp < cutoff {
                    try? fm.removeItem(at: child)
                }
            }
        }
        let dir = rootDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var usedNames: Set<String> = []
        var out: [URL] = []
        for src in sources {
            guard fm.fileExists(atPath: src.url.path) else { continue }
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
            if (try? fm.linkItem(at: src.url, to: dst)) == nil {
                try? fm.copyItem(at: src.url, to: dst)
            }
            if fm.fileExists(atPath: dst.path) {
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
            let items = buildShareItems()
            WallPullShareHelper.presentShareSheet(items: items, sourceView: anchorView)
        } label: {
            label()
                .background(UIKitShareAnchorView { view in
                    anchorView = view
                })
        }
        .buttonStyle(StickerPressButtonStyle())
    }
}

extension WallPullShareHelper {
    @MainActor
    static func presentShareSheet(items: [Any], sourceView: UIView? = nil) {
        guard !items.isEmpty else { return }
        guard let hostVC = topViewController(startingFrom: sourceView?.window?.rootViewController) else {
            return
        }
        if hostVC.presentedViewController is UIActivityViewController {
            return
        }
        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = ac.popoverPresentationController {
            if let anchor = sourceView {
                pop.sourceView = anchor
                pop.sourceRect = anchor.bounds
            } else {
                pop.sourceView = hostVC.view
                pop.sourceRect = CGRect(x: hostVC.view.bounds.midX, y: max(80, hostVC.view.bounds.maxY - 90), width: 1, height: 1)
            }
            pop.permittedArrowDirections = [.up, .down]
        }
        hostVC.present(ac, animated: true)
    }

    @MainActor
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

@available(iOS 16.0, *)
@MainActor
private enum SubjectLiftShared {
    static let analyzer: ImageAnalyzer? = ImageAnalyzer.isSupported ? ImageAnalyzer() : nil
}

// MARK: - True Edge-to-Edge Zoomable & Pannable Image View (with native VisionKit Subject Lifting)
struct ZoomableScrollImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    var fillMode: Bool = false
    var enableSubjectLifting: Bool = true
    var externalZoomScale: Binding<CGFloat>? = nil

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
        Coordinator(isZoomed: $isZoomed, externalZoomScale: externalZoomScale)
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
        imageView.isUserInteractionEnabled = true
        imageView.contentMode = fillMode ? .scaleAspectFill : .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        scroll.addSubview(imageView)
        scroll.zoomTarget = imageView

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView
        context.coordinator.enableSubjectLifting = enableSubjectLifting

        if enableSubjectLifting {
            installAndAnalyzeSubjectIfSupported(on: imageView, image: image, coordinator: context.coordinator)
        }

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
        context.coordinator.enableSubjectLifting = enableSubjectLifting
        var needsRelayout = false
        if iv.image !== image {
            iv.image = image
            uiView.setZoomScale(1.0, animated: false)
            needsRelayout = true
            if #available(iOS 16.0, *) {
                (context.coordinator.subjectInteractionObj as? ImageAnalysisInteraction)?.analysis = nil
            }
            context.coordinator.analyzedImageRef = nil
            if enableSubjectLifting {
                installAndAnalyzeSubjectIfSupported(on: iv, image: image, coordinator: context.coordinator)
            }
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
        context.coordinator.externalZoomScale = externalZoomScale
        if !needsRelayout, let targetZoom = externalZoomScale?.wrappedValue {
            let clamped = max(uiView.minimumZoomScale, min(uiView.maximumZoomScale, targetZoom))
            if abs(uiView.zoomScale - clamped) > 0.03 {
                context.coordinator.isApplyingExternalZoom = true
                uiView.setZoomScale(clamped, animated: false)
                context.coordinator.isApplyingExternalZoom = false
            }
        } else if needsRelayout, let binding = externalZoomScale {
            DispatchQueue.main.async {
                if abs(binding.wrappedValue - 1.0) > 0.02 {
                    binding.wrappedValue = 1.0
                }
            }
        }
        uiView.layoutImageFrameIfNeeded(force: needsRelayout)
    }

    static func dismantleUIView(_ uiView: ZoomContainerScrollView, coordinator: Coordinator) {
        coordinator.analysisTask?.cancel()
        coordinator.analysisTask = nil
    }

    @MainActor
    private func installAndAnalyzeSubjectIfSupported(
        on imageView: UIImageView,
        image: UIImage,
        coordinator: Coordinator
    ) {
        if #available(iOS 16.0, *), let analyzer = SubjectLiftShared.analyzer {
            let interaction: ImageAnalysisInteraction
            if let existing = coordinator.subjectInteractionObj as? ImageAnalysisInteraction {
                interaction = existing
            } else {
                let created = ImageAnalysisInteraction()
                created.preferredInteractionTypes = .imageSubject
                imageView.addInteraction(created)
                coordinator.subjectInteractionObj = created
                interaction = created
            }
            runSubjectAnalysis(analyzer: analyzer, interaction: interaction, image: image, coordinator: coordinator)
        }
    }

    @available(iOS 16.0, *)
    @MainActor
    private func runSubjectAnalysis(
        analyzer: ImageAnalyzer,
        interaction: ImageAnalysisInteraction,
        image: UIImage,
        coordinator: Coordinator
    ) {
        if coordinator.analyzedImageRef === image {
            return
        }
        coordinator.analysisTask?.cancel()
        coordinator.analyzedImageRef = image
        coordinator.analysisTask = Task {
            let config = ImageAnalyzer.Configuration([.text, .visualLookUp])
            guard let analysis = try? await analyzer.analyze(image, configuration: config),
                  !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, coordinator.imageView?.image === image else { return }
                interaction.preferredInteractionTypes = .imageSubject
                interaction.analysis = analysis
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isZoomed: Bool
        var externalZoomScale: Binding<CGFloat>?
        var isApplyingExternalZoom: Bool = false
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var enableSubjectLifting: Bool = true
        var subjectInteractionObj: AnyObject? = nil
        var analysisTask: Task<Void, Never>? = nil
        weak var analyzedImageRef: UIImage? = nil

        init(isZoomed: Binding<Bool>, externalZoomScale: Binding<CGFloat>? = nil) {
            self._isZoomed = isZoomed
            self.externalZoomScale = externalZoomScale
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.04
            let z = scrollView.zoomScale
            let syncScale = !isApplyingExternalZoom
            if isZoomed != zoomed || syncScale {
                DispatchQueue.main.async {
                    if self.isZoomed != zoomed {
                        self.isZoomed = zoomed
                    }
                    if syncScale, let ext = self.externalZoomScale, abs(ext.wrappedValue - z) > 0.015 {
                        ext.wrappedValue = z
                    }
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

    private let maxSlots = 6
    private let maxRawFallbackSlots = 2
    private var entries: [ObjectIdentifier: GalleryInlineVideoView.Coordinator] = [:]
    private var failedURLs: Set<URL> = []
    private var watchdogTimer: Timer?
    private var pendingRebalance: DispatchWorkItem?
    private var scrollSettleWork: DispatchWorkItem?
    private var scrollObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastScrollOffsets: [ObjectIdentifier: CGPoint] = [:]
    private var isActivelyScrolling = false
    private var globallyPaused = false

    func markFailed(_ url: URL) {
        failedURLs.insert(url)
    }

    func hasFailed(_ url: URL) -> Bool {
        failedURLs.contains(url)
    }

    func register(_ coord: GalleryInlineVideoView.Coordinator) {
        let key = ObjectIdentifier(coord)
        entries[key] = coord
        if let pv = coord.playerView {
            attachScrollObserverIfNeeded(from: pv)
        }
        pruneDeadEntries()
        if !globallyPaused {
            ensureTimerRunning()
        }
        if !isActivelyScrolling {
            scheduleRebalance(delay: 0.12)
        }
    }

    func unregister(_ coord: GalleryInlineVideoView.Coordinator) {
        let key = ObjectIdentifier(coord)
        entries.removeValue(forKey: key)
        coord.teardownPlayer()
        pruneDeadEntries()
        if entries.isEmpty {
            stopTimer()
            scrollObservers.removeAll()
            lastScrollOffsets.removeAll()
        } else if !isActivelyScrolling {
            scheduleRebalance(delay: 0.08)
        }
    }

    func setGloballyPaused(_ paused: Bool) {
        globallyPaused = paused
        if paused {
            pendingRebalance?.cancel()
            pendingRebalance = nil
            scrollSettleWork?.cancel()
            scrollSettleWork = nil
            isActivelyScrolling = false
            stopTimer()
            for coord in entries.values {
                coord.teardownPlayer()
            }
        } else if !entries.isEmpty {
            ensureTimerRunning()
            scheduleRebalance(delay: 0.10)
        }
    }

    func releaseAll() {
        pendingRebalance?.cancel()
        pendingRebalance = nil
        scrollSettleWork?.cancel()
        scrollSettleWork = nil
        for coord in entries.values {
            coord.teardownPlayer()
        }
    }

    private final class ScrollTickGate: @unchecked Sendable {
        var lastTickTime: CFTimeInterval = 0
    }

    fileprivate func attachScrollObserverIfNeeded(from view: UIView) {
        if scrollObservers.count > 24 {
            scrollObservers.removeAll()
            lastScrollOffsets.removeAll()
        }
        var cur: UIView? = view.superview
        while let v = cur {
            if let sv = v as? UIScrollView {
                let svID = ObjectIdentifier(sv)
                if scrollObservers[svID] == nil {
                    lastScrollOffsets[svID] = sv.contentOffset
                    let gate = ScrollTickGate()
                    scrollObservers[svID] = sv.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                        let now = CACurrentMediaTime()
                        if now - gate.lastTickTime < 0.07 { return }
                        gate.lastTickTime = now
                        Task { @MainActor [weak self, weak scrollView] in
                            guard let self, let scrollView else { return }
                            let id = ObjectIdentifier(scrollView)
                            let prev = self.lastScrollOffsets[id] ?? scrollView.contentOffset
                            let curOffset = scrollView.contentOffset
                            if abs(curOffset.y - prev.y) > 1.5 || abs(curOffset.x - prev.x) > 1.5 {
                                self.lastScrollOffsets[id] = curOffset
                                self.noteScrollActivity()
                            }
                        }
                    }
                }
                return
            }
            cur = v.superview
        }
    }

    private func noteScrollActivity() {
        isActivelyScrolling = true
        pendingRebalance?.cancel()
        pendingRebalance = nil
        scrollSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isActivelyScrolling = false
            self.rebalanceNow()
        }
        scrollSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func ensureTimerRunning() {
        guard watchdogTimer == nil else { return }
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
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

        // Skip heavy AVURLAsset / AVPlayer allocation while user is actively scrolling
        if isActivelyScrolling {
            return
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
            let effectiveTargetFailed = hasFailed(targetURL)
            if effectiveTargetFailed && (coord.fallbackURL == nil || hasFailed(coord.fallbackURL!)) {
                coord.teardownPlayer()
                continue
            }
            let needsFreshSetup = coord.player == nil
                || (coord.boundTargetURL != targetURL && coord.failedPrimaryURL != targetURL && !effectiveTargetFailed)

            if needsFreshSetup {
                if effectiveTargetFailed, let fb = coord.fallbackURL, !hasFailed(fb) {
                    coord.failedPrimaryURL = targetURL
                    coord.setupPlayer(url: fb, fallback: nil, in: pv)
                } else {
                    coord.setupPlayer(url: targetURL, fallback: coord.fallbackURL, in: pv)
                }
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
                if let cur = coord.currentURL {
                    markFailed(cur)
                }
                if let fb = coord.fallbackURL, coord.currentURL != fb, !hasFailed(fb) {
                    coord.failedPrimaryURL = coord.boundTargetURL
                    coord.setupPlayer(url: fb, fallback: nil, in: pv)
                } else {
                    coord.teardownPlayer()
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
                        if let cur = self.currentURL {
                            GalleryVideoPreviewCoordinator.shared.markFailed(cur)
                        }
                        guard self.isCurrentlyActive,
                              let pv = view,
                              let fb = self.fallbackURL,
                              self.currentURL != fb,
                              !GalleryVideoPreviewCoordinator.shared.hasFailed(fb) else {
                            self.teardownPlayer()
                            return
                        }
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
        var onAttachedToWindow: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onAttachedToWindow?(self)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .clear
        v.alpha = 0
        v.playerLayer.videoGravity = .resizeAspectFill
        let weakCoord = context.coordinator
        v.onAttachedToWindow = { [weak weakCoord] view in
            GalleryVideoPreviewCoordinator.shared.attachScrollObserverIfNeeded(from: view)
            if let coord = weakCoord {
                GalleryVideoPreviewCoordinator.shared.register(coord)
            }
        }
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
        if coord.playerView === uiView
            && coord.cardID == id
            && coord.targetURL == url
            && coord.fallbackURL == fallbackURL
            && coord.isCurrentlyActive == isActive {
            return
        }

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
        var holdsUnmutedSession: Bool = false
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
            if !muted && !coord.holdsUnmutedSession {
                coord.holdsUnmutedSession = true
                WallPullAudioSessionCoordinator.shared.pushVideoUnmuted()
            } else if muted && coord.holdsUnmutedSession {
                coord.holdsUnmutedSession = false
                WallPullAudioSessionCoordinator.shared.popVideoUnmuted()
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
        } else if p.timeControlStatus != .paused {
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

        if !muted && !coordinator.holdsUnmutedSession {
            coordinator.holdsUnmutedSession = true
            WallPullAudioSessionCoordinator.shared.pushVideoUnmuted()
        }

        let asset = AVURLAsset(url: targetURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = !targetURL.isFileURL

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
                DispatchQueue.main.async {
                    guard finished, coordinator.player === p, coordinator.desiredPlaying else { return }
                    p.playImmediately(atRate: coordinator.desiredRate)
                }
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
        if coordinator.holdsUnmutedSession {
            coordinator.holdsUnmutedSession = false
            WallPullAudioSessionCoordinator.shared.popVideoUnmuted()
        }
        coordinator.player?.pause()
        coordinator.player = nil
        coordinator.currentURL = nil
        coordinator.boundTargetURL = nil
        coordinator.fallbackURL = nil
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
        if text.isEmpty && !(uiView.text ?? "").isEmpty {
            uiView.unmarkText()
            uiView.text = ""
        } else if uiView.markedTextRange == nil && uiView.text != text {
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

struct StableSearchTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat = 14.5

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.text = text
        tf.font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        tf.borderStyle = .none
        tf.clearButtonMode = .never
        tf.returnKeyType = .search
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.delegate = context.coordinator
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.text = $text
        if text.isEmpty && !(uiView.text ?? "").isEmpty {
            uiView.unmarkText()
            uiView.text = ""
        } else if uiView.markedTextRange == nil && uiView.text != text {
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
            let val = sender.text ?? ""
            if text.wrappedValue != val {
                text.wrappedValue = val
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            let val = textField.text ?? ""
            if text.wrappedValue != val {
                text.wrappedValue = val
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

struct LANThumbView: UIViewRepresentable {
    let cacheKey: String
    let request: URLRequest?
    let session: URLSession
    let isVideo: Bool
    var onUnauthorized: (() -> Void)? = nil

    final class Coordinator {
        var currentKey: String = ""
        var failedKey: String = ""
        var loadTask: Task<Void, Never>? = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZeroIntrinsicImageContainerView {
        let view = ZeroIntrinsicImageContainerView()
        view.backgroundColor = .secondarySystemBackground
        apply(view: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: ZeroIntrinsicImageContainerView, context: Context) {
        apply(view: uiView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ uiView: ZeroIntrinsicImageContainerView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        coordinator.currentKey = ""
        coordinator.failedKey = ""
    }

    private func apply(view: ZeroIntrinsicImageContainerView, coordinator: Coordinator) {
        if coordinator.currentKey == cacheKey && (view.imageView.image != nil || coordinator.failedKey == cacheKey) {
            return
        }
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        coordinator.currentKey = cacheKey
        coordinator.failedKey = ""

        if let cached = PCThumbnailCache.shared.image(forKey: cacheKey) {
            view.setLoadedImage(cached)
            return
        }

        let sym = isVideo ? "film" : "photo"
        view.showPlaceholder(symbol: sym)
        guard let request else {
            coordinator.failedKey = cacheKey
            return
        }

        let key = cacheKey
        let sess = session
        let on401 = onUnauthorized
        coordinator.loadTask = Task(priority: .userInitiated) {
            let res = await PCThumbnailCache.shared.loadOrFetch(cacheKey: key, request: request, session: sess)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if res.unauthorized {
                    on401?()
                }
                guard coordinator.currentKey == key else { return }
                if let img = res.image {
                    view.setLoadedImage(img)
                } else {
                    coordinator.failedKey = key
                }
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
