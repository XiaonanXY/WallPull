import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class RetinaThumbnailCache: @unchecked Sendable {
    static let shared = RetinaThumbnailCache()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 360
        c.totalCostLimit = 240 * 1024 * 1024
        return c
    }()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        let px = Int((image.size.width * image.scale) * (image.size.height * image.scale))
        cache.setObject(image, forKey: key as NSString, cost: max(1, px * 4))
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private final class NonRedirectUpdateDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct AnalyzedMediaPayload: Sendable {
    let mediaType: VaultMediaType
    let width: Int
    let height: Int
    let durationSeconds: Double?
    let fileSize: Int64
    let isTransparentCutout: Bool
    let thumbFileName: String?
    let colorBucket: String?
}

@MainActor
final class LocalVaultStore: ObservableObject {
    @Published var items: [VaultItem] = [] {
        didSet { recomputeFilteredItems() }
    }
    @Published var categoryFilter: VaultCategoryFilter {
        didSet {
            UserDefaults.standard.set(categoryFilter.rawValue, forKey: "wp_category_filter")
            recomputeFilteredItems()
        }
    }
    @Published var ratingFilter: ContentRatingFilter {
        didSet {
            UserDefaults.standard.set(ratingFilter.rawValue, forKey: "wp_rating_filter")
            recomputeFilteredItems()
        }
    }
    @Published var specFilter: SpecFilter {
        didSet {
            UserDefaults.standard.set(specFilter.rawValue, forKey: "wp_spec_filter")
            recomputeFilteredItems()
        }
    }
    @Published var colorFilter: ColorBucketKind? {
        didSet {
            UserDefaults.standard.set(colorFilter?.rawValue ?? "", forKey: "wp_color_filter")
            recomputeFilteredItems()
        }
    }
    @Published var sortMode: VaultSortMode {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: "wp_sort_mode")
            recomputeFilteredItems()
        }
    }
    @Published var searchText: String = "" {
        didSet { recomputeFilteredItems() }
    }
    @Published private(set) var cachedFilteredItems: [VaultItem] = []
    @Published var columnsCount: Int {
        didSet { UserDefaults.standard.set(columnsCount, forKey: "wp_columns_count") }
    }
    @Published var toast: ToastBannerState? = nil
    @Published var thumbRevision: Int = 0
    @Published var newlyLandedIDs: Set<String> = []

    @Published var appearanceModeRaw: String {
        didSet { UserDefaults.standard.set(appearanceModeRaw, forKey: "wp_appearance_mode") }
    }
    @Published var accentHex: String {
        didSet { UserDefaults.standard.set(accentHex, forKey: "wp_accent_hex") }
    }
    @Published var clipboardHapticEnabled: Bool {
        didSet { UserDefaults.standard.set(clipboardHapticEnabled, forKey: "wp_clipboard_haptic") }
    }
    @Published var deviceAlias: String {
        didSet {
            UserDefaults.standard.set(deviceAlias, forKey: "wp_device_alias")
            onAliasChanged?(deviceAlias)
        }
    }
    @Published var showCardCaptions: Bool {
        didSet { UserDefaults.standard.set(showCardCaptions, forKey: "wp_show_card_captions") }
    }
    @Published var cardAspectModeRaw: String {
        didSet {
            UserDefaults.standard.set(cardAspectModeRaw, forKey: "wp_card_aspect_mode")
            recomputeFilteredItems()
        }
    }
    @Published var autoPlayGalleryVideos: Bool {
        didSet { UserDefaults.standard.set(autoPlayGalleryVideos, forKey: "wp_autoplay_gallery_videos") }
    }
    @Published var customDisconnectedLabel: String {
        didSet {
            let clamped = Self.clampDisconnectedBadgeText(customDisconnectedLabel)
            if customDisconnectedLabel != clamped {
                customDisconnectedLabel = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "wp_custom_disconnected_label")
        }
    }

    var onAliasChanged: ((String) -> Void)? = nil
    var onItemsDeleted: ((Set<String>) -> Void)? = nil

    static let maxDisconnectedBadgeWeight = 70 // 10 ASCII chars (7 each) or 7 non-ASCII/Chinese chars (10 each)

    nonisolated static func disconnectedBadgeWeight(_ raw: String) -> (weight: Int, maxWeight: Int) {
        let cleaned = raw.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        var total = 0
        for ch in cleaned {
            let w = ch.unicodeScalars.allSatisfy(\.isASCII) ? 7 : 10
            total += w
        }
        return (total, maxDisconnectedBadgeWeight)
    }

    nonisolated static func clampDisconnectedBadgeText(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        var out = ""
        var used = 0
        for ch in cleaned {
            let w = ch.unicodeScalars.allSatisfy(\.isASCII) ? 7 : 10
            if used + w > maxDisconnectedBadgeWeight { break }
            out.append(ch)
            used += w
        }
        return out
    }

    var effectiveDisconnectedLabel: String {
        let trimmed = Self.clampDisconnectedBadgeText(customDisconnectedLabel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "电脑互联" : trimmed
    }

    let vaultDir: URL
    let mediaDir: URL
    let thumbsDir: URL
    let previewsDir: URL
    let audioDir: URL
    let studioDir: URL
    let catalogURL: URL

    private var toastDismissTask: Task<Void, Never>? = nil
    private var debouncedSaveTask: Task<Void, Never>? = nil

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    var cardAspectMode: CardAspectMode {
        get { CardAspectMode(rawValue: cardAspectModeRaw) ?? .widescreen }
        set { cardAspectModeRaw = newValue.rawValue }
    }

    var accentColor: Color {
        Color(hex: accentHex)
    }

    var totalStorageBytes: Int64 {
        items.reduce(0) { $0 + max(0, $1.fileSize) }
    }

    var hasAnyMusic: Bool {
        items.contains { $0.hasMusic }
    }

    var activeFilterCount: Int {
        var count = 0
        if ratingFilter != .all { count += 1 }
        if specFilter != .all { count += 1 }
        if colorFilter != nil { count += 1 }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if sortMode != .newest { count += 1 }
        return count
    }

    func resetAllFilters() {
        ratingFilter = .all
        specFilter = .all
        colorFilter = nil
        searchText = ""
        sortMode = .newest
    }

    init() {
        let ud = UserDefaults.standard
        self.categoryFilter = ud.string(forKey: "wp_category_filter").flatMap(VaultCategoryFilter.init(rawValue:)) ?? .all
        self.ratingFilter = ud.string(forKey: "wp_rating_filter").flatMap(ContentRatingFilter.init(rawValue:)) ?? .all
        self.specFilter = ud.string(forKey: "wp_spec_filter").flatMap(SpecFilter.init(rawValue:)) ?? .all
        self.colorFilter = ud.string(forKey: "wp_color_filter").flatMap { $0.isEmpty ? nil : ColorBucketKind(rawValue: $0) }
        self.sortMode = ud.string(forKey: "wp_sort_mode").flatMap(VaultSortMode.init(rawValue:)) ?? .newest
        let savedCols = ud.integer(forKey: "wp_columns_count")
        self.columnsCount = (2...6).contains(savedCols) ? savedCols : 3

        self.appearanceModeRaw = ud.string(forKey: "wp_appearance_mode") ?? AppearanceMode.system.rawValue
        self.accentHex = ud.string(forKey: "wp_accent_hex") ?? "#7C3AED"
        self.clipboardHapticEnabled = ud.object(forKey: "wp_clipboard_haptic") == nil ? true : ud.bool(forKey: "wp_clipboard_haptic")
        self.deviceAlias = ud.string(forKey: "wp_device_alias") ?? "WallPull iPad"
        self.showCardCaptions = ud.object(forKey: "wp_show_card_captions") == nil ? true : ud.bool(forKey: "wp_show_card_captions")
        self.cardAspectModeRaw = ud.string(forKey: "wp_card_aspect_mode") ?? CardAspectMode.widescreen.rawValue
        self.autoPlayGalleryVideos = ud.object(forKey: "wp_autoplay_gallery_videos") == nil ? true : ud.bool(forKey: "wp_autoplay_gallery_videos")
        self.customDisconnectedLabel = Self.clampDisconnectedBadgeText(ud.string(forKey: "wp_custom_disconnected_label") ?? "")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        vaultDir = docs.appendingPathComponent("Vault", isDirectory: true)
        mediaDir = vaultDir.appendingPathComponent("media", isDirectory: true)
        thumbsDir = vaultDir.appendingPathComponent("thumbs", isDirectory: true)
        previewsDir = vaultDir.appendingPathComponent("previews", isDirectory: true)
        audioDir = vaultDir.appendingPathComponent("audio", isDirectory: true)
        studioDir = vaultDir.appendingPathComponent("studio", isDirectory: true)
        catalogURL = vaultDir.appendingPathComponent("catalog.json")
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: studioDir, withIntermediateDirectories: true)
        loadCatalog()
        recomputeFilteredItems()
        migrateRetinaThumbnailsIfNeeded()
        upgradeLegacyAndMissingVideoPreviewsIfNeeded()
    }

    func mediaURL(for item: VaultItem) -> URL {
        mediaDir.appendingPathComponent(item.fileName)
    }

    func mediaURL(for item: VaultItem, variantIndex: Int) -> URL {
        let files = item.allMediaFileNames
        let safeIdx = max(0, min(variantIndex, files.count - 1))
        return mediaDir.appendingPathComponent(files[safeIdx])
    }

    func thumbURL(for item: VaultItem) -> URL? {
        guard let t = item.thumbFileName else { return nil }
        return thumbsDir.appendingPathComponent(t)
    }

    func galleryPreviewVideoURL(for item: VaultItem) -> URL {
        if let pName = item.previewVideoFileName {
            let url = previewsDir.appendingPathComponent(pName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return mediaURL(for: item)
    }

    func audioURL(for track: VaultAudioTrack) -> URL {
        audioDir.appendingPathComponent(track.fileName)
    }

    func studioItemDir(for itemId: String) -> URL {
        studioDir.appendingPathComponent(itemId, isDirectory: true)
    }

    func loadOfflineStudioBundle(for itemId: String) -> OfflineStudioBundle? {
        let manifestURL = studioItemDir(for: itemId).appendingPathComponent("bundle.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(OfflineStudioBundle.self, from: data)
    }

    func saveOfflineStudioBundle(_ bundle: OfflineStudioBundle, groupImages: [String: Data], for itemId: String) {
        let dir = studioItemDir(for: itemId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (fileName, pngData) in groupImages {
            try? pngData.write(to: dir.appendingPathComponent(fileName), options: [.atomic])
        }
        if let encoded = try? JSONEncoder().encode(bundle) {
            try? encoded.write(to: dir.appendingPathComponent("bundle.json"), options: [.atomic])
        }
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx].hasOfflineStudioBundle = true
            items[idx].hasSceneLayers = true
            saveCatalog()
        }
    }

    private func matchesBaseFilters(_ item: VaultItem, ignoreColor: Bool = false) -> Bool {
        switch categoryFilter {
        case .all: break
        case .image:
            if item.mediaType != .image { return false }
        case .video:
            if item.mediaType != .video { return false }
        case .favorite:
            if !item.isFavorite { return false }
        }

        switch ratingFilter {
        case .all: break
        case .everyone:
            let cr = (item.contentRating ?? "Everyone").lowercased()
            if cr != "everyone" && !cr.isEmpty { return false }
        case .mature:
            let cr = (item.contentRating ?? "Everyone").lowercased()
            if cr != "questionable" && cr != "mature" { return false }
        }

        switch specFilter {
        case .all: break
        case .uhd4k:
            if max(item.width, item.height) < 3840 && item.pixelCount < 3840 * 2160 { return false }
        case .landscape:
            if item.width <= 0 || item.width <= item.height { return false }
        case .portrait:
            if item.height <= 0 || item.height <= item.width { return false }
        case .audio:
            if !item.hasMusic { return false }
        case .layered:
            if !item.supportsLayerStudio { return false }
        }

        if !ignoreColor, let cf = colorFilter, item.colorBucket != cf.rawValue {
            return false
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty && !item.title.lowercased().contains(q) && !item.fileName.lowercased().contains(q) {
            return false
        }
        return true
    }

    func colorBucketCounts() -> [ColorBucketKind: Int] {
        var counts: [ColorBucketKind: Int] = [:]
        for b in ColorBucketKind.allCases { counts[b] = 0 }
        for item in items where matchesBaseFilters(item, ignoreColor: true) {
            if let raw = item.colorBucket, let b = ColorBucketKind(rawValue: raw) {
                counts[b, default: 0] += 1
            }
        }
        return counts
    }

    var filteredItems: [VaultItem] {
        cachedFilteredItems
    }

    private func recomputeFilteredItems() {
        let base = items.filter { matchesBaseFilters($0, ignoreColor: false) }
        let ordered: [VaultItem]
        switch sortMode {
        case .newest:
            ordered = base.sorted { $0.addedAt > $1.addedAt }
        case .title:
            ordered = base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .size:
            ordered = base.sorted { $0.fileSize > $1.fileSize }
        case .resolution:
            ordered = base.sorted {
                if $0.pixelCount != $1.pixelCount { return $0.pixelCount > $1.pixelCount }
                return $0.fileSize > $1.fileSize
            }
        }

        guard cardAspectMode == .adaptive else {
            cachedFilteredItems = ordered
            return
        }
        // Cluster items by 7 exact aspect ratio buckets so cards in each row share matching height
        func aspectBucket(_ ratio: CGFloat) -> Int {
            if ratio >= 2.05 { return 0 }      // Ultrawide 21:9+
            if ratio >= 1.70 { return 1 }      // 16:9 widescreen
            if ratio >= 1.45 { return 2 }      // 16:10 / 3:2
            if ratio >= 1.18 { return 3 }      // 4:3
            if ratio >= 0.90 { return 4 }      // 1:1 square
            if ratio >= 0.68 { return 5 }      // 3:4 portrait
            return 6                           // 9:16 tall portrait
        }
        var buckets = [[VaultItem]](repeating: [], count: 7)
        for item in ordered {
            buckets[aspectBucket(item.aspectRatio)].append(item)
        }
        let rankedBuckets = buckets.enumerated()
            .filter { !$0.element.isEmpty }
            .sorted { lhs, rhs in
                if lhs.element.count != rhs.element.count {
                    return lhs.element.count > rhs.element.count
                }
                return lhs.offset < rhs.offset
            }
        cachedFilteredItems = rankedBuckets.flatMap(\.element)
    }

    func showToast(_ message: String, isError: Bool = false) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            toast = ToastBannerState(message: message, isError: isError)
        }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                toast = nil
            }
        }
    }

    func loadCatalog() {
        guard let data = try? Data(contentsOf: catalogURL),
              let decoded = try? JSONDecoder().decode([VaultItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.filter { FileManager.default.fileExists(atPath: mediaURL(for: $0).path) }
    }

    func saveCatalog() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(items) {
            try? data.write(to: catalogURL, options: [.atomic])
        }
    }

    func hasImportedCatalogItem(_ pcItem: PCCatalogItem) -> Bool {
        if items.contains(where: { $0.remoteID == pcItem.id }) {
            return true
        }
        return items.contains {
            ($0.remoteID == nil || $0.remoteID?.isEmpty == true)
                && $0.title == pcItem.title
                && $0.mediaType.rawValue == pcItem.mediaType
                && $0.fileSize == pcItem.fileSize
        }
    }

    func findDuplicate(sha256: String?, remoteID: String?) -> VaultItem? {
        if let rid = remoteID,
           let existing = items.first(where: { $0.remoteID == rid }),
           FileManager.default.fileExists(atPath: mediaURL(for: existing).path) {
            return existing
        }
        if let hash = sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !hash.isEmpty,
           let existing = items.first(where: { $0.sha256?.lowercased() == hash }),
           FileManager.default.fileExists(atPath: mediaURL(for: existing).path) {
            return existing
        }
        return nil
    }

    func saveCatalogDebounced() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.saveCatalog()
        }
    }

    func flushCatalogSaveNow() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        saveCatalog()
    }

    func markLandedCompleted(_ id: String) {
        newlyLandedIDs.remove(id)
    }

    func insertStreamedItem(_ item: VaultItem) {
        if findDuplicate(sha256: item.sha256, remoteID: item.remoteID) != nil {
            return
        }
        newlyLandedIDs.insert(item.id)
        items.insert(item, at: 0)
        saveCatalogDebounced()
        let iid = item.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.newlyLandedIDs.remove(iid)
        }
    }

    func commitBatch(_ newItems: [VaultItem]) {
        guard !newItems.isEmpty else { return }
        var appended = false
        for item in newItems.reversed() {
            if findDuplicate(sha256: item.sha256, remoteID: item.remoteID) == nil {
                newlyLandedIDs.insert(item.id)
                items.insert(item, at: 0)
                appended = true
            }
        }
        if appended {
            saveCatalog()
        }
    }

    func updateItemMetadata(id: String, mutate: (inout VaultItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
        saveCatalogDebounced()
    }

    func importFile(
        from tempURL: URL,
        suggestedFileName: String,
        titleOverride: String? = nil,
        sourceDevice: String,
        isCutoutHint: Bool = false,
        sha256: String? = nil,
        remoteID: String? = nil,
        hasSceneLayers: Bool = false,
        contentRating: String? = nil,
        previewVideoFileName: String? = nil,
        additionalFiles: [String]? = nil,
        audioTracks: [VaultAudioTrack]? = nil
    ) async -> VaultItem? {
        if let existing = findDuplicate(sha256: sha256, remoteID: remoteID) {
            if hasSceneLayers && existing.hasSceneLayers != true {
                updateItemMetadata(id: existing.id) { $0.hasSceneLayers = true }
                flushCatalogSaveNow()
            }
            return existing
        }

        let id = UUID().uuidString
        let ext = URL(fileURLWithPath: suggestedFileName).pathExtension.lowercased()
        let safeExt = ext.isEmpty ? (tempURL.pathExtension.isEmpty ? "png" : tempURL.pathExtension.lowercased()) : ext
        let storedFileName = "\(id).\(safeExt)"
        let mDir = mediaDir
        let tDir = thumbsDir

        let analyzed = await Task.detached(priority: .userInitiated) {
            Self.analyzeAndWriteMedia(
                from: tempURL,
                id: id,
                storedFileName: storedFileName,
                safeExt: safeExt,
                mediaDir: mDir,
                thumbsDir: tDir,
                isCutoutHint: isCutoutHint
            )
        }.value

        guard let analyzed else { return nil }

        let cleanTitle = (titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: suggestedFileName).deletingPathExtension().lastPathComponent
        let item = VaultItem(
            id: id,
            title: cleanTitle,
            mediaType: analyzed.mediaType,
            fileName: storedFileName,
            thumbFileName: analyzed.thumbFileName,
            previewVideoFileName: previewVideoFileName,
            width: analyzed.width,
            height: analyzed.height,
            durationSeconds: analyzed.durationSeconds,
            fileSize: analyzed.fileSize,
            isTransparentCutout: analyzed.isTransparentCutout,
            colorBucket: analyzed.colorBucket,
            contentRating: contentRating,
            isFavorite: false,
            addedAt: Date(),
            sourceDevice: sourceDevice,
            sha256: sha256?.lowercased(),
            remoteID: remoteID,
            audioTracks: audioTracks,
            additionalFiles: additionalFiles,
            hasSceneLayers: hasSceneLayers,
            hasOfflineStudioBundle: false,
            visualFingerprint: nil
        )
        insertStreamedItem(item)
        flushCatalogSaveNow()

        if item.mediaType == .video && previewVideoFileName == nil {
            let pDir = previewsDir
            let mURL = mDir.appendingPathComponent(storedFileName)
            Task.detached(priority: .utility) { [weak self] in
                if let clipName = await Self.generateLightweightVideoPreview(srcURL: mURL, id: id, previewsDir: pDir) {
                    await MainActor.run { [weak self] in
                        self?.updateItemMetadata(id: id) { $0.previewVideoFileName = clipName }
                        self?.flushCatalogSaveNow()
                    }
                }
            }
        }
        return item
    }

    nonisolated static func analyzeAndWriteMedia(
        from tempURL: URL,
        id: String,
        storedFileName: String,
        safeExt: String,
        mediaDir: URL,
        thumbsDir: URL,
        isCutoutHint: Bool
    ) -> AnalyzedMediaPayload? {
        let destURL = mediaDir.appendingPathComponent(storedFileName)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destURL)
        } catch {
            return nil
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let isVideo = ["mp4", "mov", "m4v", "webm"].contains(safeExt)

        if isVideo {
            let asset = AVURLAsset(url: destURL)
            let durationSec = CMTimeGetSeconds(asset.duration)
            var w = 0
            var h = 0
            if let track = asset.tracks(withMediaType: .video).first {
                let transformed = track.naturalSize.applying(track.preferredTransform)
                w = Int(abs(transformed.width).rounded())
                h = Int(abs(transformed.height).rounded())
            }
            var thumbName: String? = nil
            var bucket: String? = nil
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            gen.maximumSize = CGSize(width: 2048, height: 2048)
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: min(0.5, max(0, durationSec * 0.25)), preferredTimescale: 600), actualTime: nil) {
                bucket = classifyColorBucket(cgImage: cg)
                let ui = UIImage(cgImage: cg)
                if let jpg = ui.jpegData(compressionQuality: 0.95) {
                    let name = "\(id).jpg"
                    try? jpg.write(to: thumbsDir.appendingPathComponent(name), options: [.atomic])
                    thumbName = name
                }
            }
            return AnalyzedMediaPayload(
                mediaType: .video,
                width: w,
                height: h,
                durationSeconds: durationSec.isFinite ? durationSec : nil,
                fileSize: size,
                isTransparentCutout: false,
                thumbFileName: thumbName,
                colorBucket: bucket
            )
        } else {
            var w = 0
            var h = 0
            var hasAlpha = isCutoutHint
            var bucket: String? = nil
            var thumbName: String? = nil
            if let src = CGImageSourceCreateWithURL(destURL as CFURL, nil) {
                if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                    h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                }
                let opts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if let thumbCG = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    bucket = classifyColorBucket(cgImage: thumbCG)
                    if !hasAlpha {
                        hasAlpha = detectMeaningfulAlpha(cgImage: thumbCG)
                    }
                    if hasAlpha {
                        if let png = UIImage(cgImage: thumbCG).pngData() {
                            let name = "\(id).png"
                            try? png.write(to: thumbsDir.appendingPathComponent(name), options: [.atomic])
                            thumbName = name
                        }
                    } else if let jpg = UIImage(cgImage: thumbCG).jpegData(compressionQuality: 0.95) {
                        let name = "\(id).jpg"
                        try? jpg.write(to: thumbsDir.appendingPathComponent(name), options: [.atomic])
                        thumbName = name
                    }
                }
            }
            return AnalyzedMediaPayload(
                mediaType: .image,
                width: w,
                height: h,
                durationSeconds: nil,
                fileSize: size,
                isTransparentCutout: hasAlpha,
                thumbFileName: thumbName,
                colorBucket: bucket
            )
        }
    }

    nonisolated static func generateLightweightVideoPreview(srcURL: URL, id: String, previewsDir: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: srcURL.path) else { return nil }
        let outName = "\(id)_prev_hd.mp4"
        let dstURL = previewsDir.appendingPathComponent(outName)
        if FileManager.default.fileExists(atPath: dstURL.path),
           let sz = (try? FileManager.default.attributesOfItem(atPath: dstURL.path)[.size] as? NSNumber)?.int64Value,
           sz > 2048 {
            return outName
        }

        let asset = AVURLAsset(url: srcURL)
        // Build a clean video-only composition to prevent unusual audio tracks from failing AVAssetExportSession
        let exportSourceAsset: AVAsset
        if let srcTrack = asset.tracks(withMediaType: .video).first {
            let comp = AVMutableComposition()
            if let compTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                compTrack.preferredTransform = srcTrack.preferredTransform
                let trackDur = CMTimeGetSeconds(srcTrack.timeRange.duration)
                let assetDur = CMTimeGetSeconds(asset.duration)
                let rawDur = (trackDur.isFinite && trackDur > 0) ? trackDur : assetDur
                let clippedDur = rawDur.isFinite && rawDur > 0 ? min(rawDur, 12.0) : 12.0
                let range = CMTimeRange(start: .zero, duration: CMTime(seconds: clippedDur, preferredTimescale: 600))
                if (try? compTrack.insertTimeRange(range, of: srcTrack, at: .zero)) != nil {
                    exportSourceAsset = comp
                } else {
                    exportSourceAsset = asset
                }
            } else {
                exportSourceAsset = asset
            }
        } else {
            exportSourceAsset = asset
        }

        let presets = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540]
        for preset in presets {
            guard let session = AVAssetExportSession(asset: exportSourceAsset, presetName: preset) else {
                continue
            }
            let tmpURL = previewsDir.appendingPathComponent("\(id)_\(UUID().uuidString).tmp.mp4")
            try? FileManager.default.removeItem(at: tmpURL)
            session.outputURL = tmpURL
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            if exportSourceAsset === asset {
                let durSec = CMTimeGetSeconds(asset.duration)
                if durSec.isFinite && durSec > 14 {
                    session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 12, preferredTimescale: 600))
                }
            }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    cont.resume()
                }
            }
            if session.status == .completed, FileManager.default.fileExists(atPath: tmpURL.path) {
                try? FileManager.default.removeItem(at: dstURL)
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: dstURL)
                    return outName
                } catch {
                    try? FileManager.default.removeItem(at: tmpURL)
                }
            } else {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }
        return nil
    }

    private func migrateRetinaThumbnailsIfNeeded() {
        let schemaVer = UserDefaults.standard.integer(forKey: "wp_thumb_schema")
        guard schemaVer < 3 else { return }
        if items.isEmpty {
            UserDefaults.standard.set(3, forKey: "wp_thumb_schema")
            return
        }
        let snapshot = items
        let mDir = mediaDir
        let tDir = thumbsDir
        let pDir = previewsDir
        Task.detached(priority: .utility) { [weak self] in
            var updatedMap: [String: (String?, String?, String?)] = [:]
            for item in snapshot {
                let srcURL = mDir.appendingPathComponent(item.fileName)
                guard FileManager.default.fileExists(atPath: srcURL.path) else { continue }
                var thumbOut: String? = nil
                var bucketOut: String? = nil
                var prevOut: String? = nil

                if item.mediaType == .video {
                    let asset = AVURLAsset(url: srcURL)
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    gen.requestedTimeToleranceBefore = .zero
                    gen.requestedTimeToleranceAfter = .zero
                    gen.maximumSize = CGSize(width: 2048, height: 2048)
                    let sec = min(0.5, max(0, (item.durationSeconds ?? 1.0) * 0.25))
                    if let cg = try? gen.copyCGImage(at: CMTime(seconds: sec, preferredTimescale: 600), actualTime: nil),
                       let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) {
                        let name = "\(item.id).jpg"
                        try? jpg.write(to: tDir.appendingPathComponent(name), options: [.atomic])
                        thumbOut = name
                        bucketOut = item.colorBucket ?? Self.classifyColorBucket(cgImage: cg)
                    }
                    if item.previewVideoFileName == nil {
                        prevOut = await Self.generateLightweightVideoPreview(srcURL: srcURL, id: item.id, previewsDir: pDir)
                    }
                } else if let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil) {
                    let opts: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: 2048,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                        if item.isTransparentCutout, let png = UIImage(cgImage: cg).pngData() {
                            let name = "\(item.id).png"
                            try? png.write(to: tDir.appendingPathComponent(name), options: [.atomic])
                            thumbOut = name
                            bucketOut = item.colorBucket ?? Self.classifyColorBucket(cgImage: cg)
                        } else if let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) {
                            let name = "\(item.id).jpg"
                            try? jpg.write(to: tDir.appendingPathComponent(name), options: [.atomic])
                            thumbOut = name
                            bucketOut = item.colorBucket ?? Self.classifyColorBucket(cgImage: cg)
                        }
                    }
                }
                if thumbOut != nil || bucketOut != nil || prevOut != nil {
                    updatedMap[item.id] = (thumbOut, bucketOut, prevOut)
                }
            }
            let finalUpdatedMap = updatedMap
            await MainActor.run { [weak self] in
                guard let self else { return }
                RetinaThumbnailCache.shared.removeAll()
                for idx in self.items.indices {
                    let iid = self.items[idx].id
                    if let upd = finalUpdatedMap[iid] {
                        if let t = upd.0 { self.items[idx].thumbFileName = t }
                        if let b = upd.1 { self.items[idx].colorBucket = b }
                        if let pv = upd.2 { self.items[idx].previewVideoFileName = pv }
                    }
                }
                self.saveCatalog()
                self.thumbRevision += 1
                UserDefaults.standard.set(3, forKey: "wp_thumb_schema")
            }
        }
    }

    private func upgradeLegacyAndMissingVideoPreviewsIfNeeded() {
        let pDir = previewsDir
        let mDir = mediaDir
        if UserDefaults.standard.integer(forKey: "wp_preview_video_schema") < 4 {
            let existingFiles = (try? FileManager.default.contentsOfDirectory(at: pDir, includingPropertiesForKeys: nil)) ?? []
            for f in existingFiles where !f.lastPathComponent.hasSuffix("_prev_hd.mp4") {
                try? FileManager.default.removeItem(at: f)
            }
            var mutated = false
            for idx in items.indices where items[idx].mediaType == .video {
                if let pv = items[idx].previewVideoFileName, !pv.hasSuffix("_prev_hd.mp4") {
                    items[idx].previewVideoFileName = nil
                    mutated = true
                }
            }
            if mutated {
                saveCatalog()
            }
            UserDefaults.standard.set(4, forKey: "wp_preview_video_schema")
        }

        let snapshot = items.filter { item in
            guard item.mediaType == .video else { return false }
            return FileManager.default.fileExists(atPath: mDir.appendingPathComponent(item.fileName).path)
        }
        guard !snapshot.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            for item in snapshot {
                var needsRegen = false
                if let pv = item.previewVideoFileName {
                    let pvURL = pDir.appendingPathComponent(pv)
                    if !FileManager.default.fileExists(atPath: pvURL.path) {
                        needsRegen = true
                    } else {
                        let asset = AVURLAsset(url: pvURL)
                        if let track = asset.tracks(withMediaType: .video).first {
                            let transformed = track.naturalSize.applying(track.preferredTransform)
                            let pw = abs(transformed.width)
                            let ph = abs(transformed.height)
                            let lowRes = max(item.width, item.height) >= 1200 && max(pw, ph) < 900
                            let badRatio = (item.width > 0 && item.height > 0 && pw > 1 && ph > 1)
                                ? abs((pw / ph) - item.aspectRatio) > 0.16
                                : false
                            if lowRes || badRatio {
                                needsRegen = true
                                try? FileManager.default.removeItem(at: pvURL)
                            }
                        } else {
                            needsRegen = true
                            try? FileManager.default.removeItem(at: pvURL)
                        }
                    }
                } else {
                    needsRegen = true
                }
                if needsRegen {
                    let srcURL = mDir.appendingPathComponent(item.fileName)
                    if let clipName = await Self.generateLightweightVideoPreview(srcURL: srcURL, id: item.id, previewsDir: pDir) {
                        let itemId = item.id
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            if let idx = self.items.firstIndex(where: { $0.id == itemId }) {
                                self.items[idx].previewVideoFileName = clipName
                                self.saveCatalogDebounced()
                            }
                        }
                    }
                }
            }
        }
    }

    func toggleFavorite(_ item: VaultItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isFavorite.toggle()
        saveCatalogDebounced()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func setFavorite(ids: Set<String>, favorite: Bool) {
        var changed = false
        for idx in items.indices where ids.contains(items[idx].id) {
            if items[idx].isFavorite != favorite {
                items[idx].isFavorite = favorite
                changed = true
            }
        }
        if changed {
            saveCatalog()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast(favorite ? "已批量设为喜欢" : "已取消所选喜欢标记")
        }
    }

    func deleteItems(ids: Set<String>) {
        let toDelete = items.filter { ids.contains($0.id) }
        for item in toDelete {
            try? FileManager.default.removeItem(at: mediaURL(for: item))
            for extra in item.additionalFiles ?? [] {
                try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(extra))
            }
            if let t = thumbURL(for: item) {
                try? FileManager.default.removeItem(at: t)
            }
            if let pv = item.previewVideoFileName {
                try? FileManager.default.removeItem(at: previewsDir.appendingPathComponent(pv))
            }
            for track in item.audioTracks ?? [] {
                try? FileManager.default.removeItem(at: audioURL(for: track))
            }
            try? FileManager.default.removeItem(at: studioItemDir(for: item.id))
        }
        items.removeAll { ids.contains($0.id) }
        saveCatalog()
        onItemsDeleted?(ids)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func copyLosslessToClipboard(item: VaultItem, variantIndex: Int = 0) {
        let url = mediaURL(for: item, variantIndex: variantIndex)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("源文件已丢失", isError: true)
            return
        }
        guard item.mediaType == .image else {
            showToast("视频暂不支持直接复制到剪贴板，请点「存入相册」保存原视频", isError: false)
            return
        }
        do {
            let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
            let ext = url.pathExtension.lowercased()
            let uti: String = (ext == "png") ? UTType.png.identifier : UTType.jpeg.identifier
            if ext == "png" || ext == "jpg" || ext == "jpeg" {
                UIPasteboard.general.setItems([[uti: raw]])
            } else if let img = UIImage(data: raw), let png = img.pngData() {
                UIPasteboard.general.setItems([[UTType.png.identifier: png]])
            } else {
                UIPasteboard.general.setItems([[UTType.data.identifier: raw]])
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已无损复制原图，切去微信直接粘贴发送")
        } catch {
            showToast("读取原图失败：\(error.localizedDescription)", isError: true)
        }
    }

    func saveMediaURLToPhotos(_ fileURL: URL, isVideo: Bool) async {
        let authorized = await requestPhotoAddPermission()
        guard authorized else {
            showToast("请在系统设置中允许 WallPull 访问「照片」", isError: true)
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            showToast("源文件不存在", isError: true)
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: isVideo ? .video : .photo, fileURL: fileURL, options: nil)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已无损存入系统相册")
        } catch {
            showToast("存入相册失败：\(error.localizedDescription)", isError: true)
        }
    }

    func copyUIImageLosslessToClipboard(_ image: UIImage) {
        guard let png = image.pngData() else {
            showToast("编码透明 PNG 失败", isError: true)
            return
        }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast("已无损复制透明立绘到剪贴板，切去微信直接粘贴")
    }

    func copyIncomingBytesToClipboard(_ data: Data, fileName: String, senderAlias: String) {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let uti = (ext == "png") ? UTType.png.identifier : UTType.jpeg.identifier
        if ext == "png" || ext == "jpg" || ext == "jpeg" {
            UIPasteboard.general.setItems([[uti: data]])
        } else if let img = UIImage(data: data), let png = img.pngData() {
            UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        } else {
            UIPasteboard.general.setItems([[UTType.data.identifier: data]])
        }
        if clipboardHapticEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        showToast("已收到「\(senderAlias)」推送的图片至剪贴板 · 切去微信直接粘贴")
    }

    func importCutoutImage(_ image: UIImage, title: String, isTransparent: Bool) async -> VaultItem? {
        guard let png = image.pngData() else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wp_studio_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? png.write(to: tmp, options: [.atomic])) != nil else { return nil }
        let created = await importFile(
            from: tmp,
            suggestedFileName: "\(title).png",
            titleOverride: title,
            sourceDevice: "透视拆解台",
            isCutoutHint: isTransparent
        )
        if created != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已将拆图成品收入离线壁纸库")
        }
        return created
    }

    func saveToPhotos(items targets: [VaultItem]) async {
        guard !targets.isEmpty else { return }
        let authorized = await requestPhotoAddPermission()
        guard authorized else {
            showToast("请在系统设置中允许 WallPull 访问「照片」", isError: true)
            return
        }
        var saved = 0
        var lastError: String? = nil
        for item in targets {
            let fileURL = mediaURL(for: item)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    let resType: PHAssetResourceType = (item.mediaType == .video) ? .video : .photo
                    req.addResource(with: resType, fileURL: fileURL, options: nil)
                }
                saved += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        if saved > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast(saved == 1 ? "已无损存入系统相册" : "已无损存入 \(saved) 项到系统相册")
        } else {
            showToast("存入相册失败：\(lastError ?? "未知错误")", isError: true)
        }
    }

    func saveUIImageToPhotos(_ image: UIImage) async {
        let authorized = await requestPhotoAddPermission()
        guard authorized else {
            showToast("请在系统设置中允许 WallPull 访问「照片」", isError: true)
            return
        }
        guard let png = image.pngData() else {
            showToast("导出图片编码失败", isError: true)
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: png, options: nil)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已无损存入系统相册")
        } catch {
            showToast("存入相册失败：\(error.localizedDescription)", isError: true)
        }
    }

    func clearThumbCache() {
        RetinaThumbnailCache.shared.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            try? FileManager.default.removeItem(at: f)
        }
        let prevFiles = (try? FileManager.default.contentsOfDirectory(at: previewsDir, includingPropertiesForKeys: nil)) ?? []
        for f in prevFiles {
            try? FileManager.default.removeItem(at: f)
        }
        for idx in items.indices where items[idx].mediaType == .video {
            items[idx].previewVideoFileName = nil
        }
        saveCatalog()
        UserDefaults.standard.set(0, forKey: "wp_thumb_schema")
        UserDefaults.standard.set(0, forKey: "wp_preview_video_schema")
        migrateRetinaThumbnailsIfNeeded()
        upgradeLegacyAndMissingVideoPreviewsIfNeeded()
        showToast("已重建高清 Retina 缩略图与视频轻量预览流")
    }

    // MARK: - Duplicate Scanner (1:1 port of src/duplicates.rs)
    func scanDuplicates() async -> DuplicateScanReport {
        let snapshot = items
        let mDir = mediaDir
        let tDir = thumbsDir

        let (computedFPs, report) = await Task.detached(priority: .userInitiated) { () -> ([String: CachedVisualFingerprint], DuplicateScanReport) in
            var newFPs: [String: CachedVisualFingerprint] = [:]
            var entries: [(item: VaultItem, fp: CachedVisualFingerprint)] = []
            for item in snapshot {
                if let existing = item.visualFingerprint {
                    entries.append((item, existing))
                    continue
                }
                let thumbPath = item.thumbFileName.map { tDir.appendingPathComponent($0) }
                let mediaPath = mDir.appendingPathComponent(item.fileName)
                let probeImgURL: URL?
                if let tp = thumbPath, FileManager.default.fileExists(atPath: tp.path) {
                    probeImgURL = tp
                } else if item.mediaType == .image, FileManager.default.fileExists(atPath: mediaPath.path) {
                    probeImgURL = mediaPath
                } else {
                    probeImgURL = nil
                }
                guard let imgURL = probeImgURL,
                      let fp = Self.computeVisualFingerprint(imageURL: imgURL, sourceURL: mediaPath) else {
                    continue
                }
                newFPs[item.id] = fp
                entries.append((item, fp))
            }

            let n = entries.count
            guard n >= 2 else {
                return (newFPs, DuplicateScanReport(groups: [], scannedCount: n, totalRedundantCount: 0, totalReclaimableBytes: 0))
            }

            var parent = Array(0..<n)
            func find(_ x: Int) -> Int {
                var cur = x
                while parent[cur] != cur {
                    parent[cur] = parent[parent[cur]]
                    cur = parent[cur]
                }
                return cur
            }
            func unite(_ a: Int, _ b: Int) {
                let ra = find(a)
                let rb = find(b)
                if ra != rb { parent[rb] = ra }
            }

            for i in 0..<n {
                for j in (i + 1)..<n {
                    let a = entries[i]
                    let b = entries[j]
                    if a.item.fileSize > 0 && a.item.fileSize == b.item.fileSize,
                       let da = a.fp.prefixDigest, let db = b.fp.prefixDigest, !da.isEmpty, da == db {
                        unite(i, j)
                        continue
                    }
                    guard a.fp.lumaRange >= 14 && b.fp.lumaRange >= 14 else { continue }
                    let dDist = (a.fp.dHash ^ b.fp.dHash).nonzeroBitCount
                    if dDist > 8 { continue }
                    let aDist = (a.fp.aHash ^ b.fp.aHash).nonzeroBitCount
                    if aDist > 10 { continue }
                    let dr = a.fp.meanR - b.fp.meanR
                    let dg = a.fp.meanG - b.fp.meanG
                    let db = a.fp.meanB - b.fp.meanB
                    let rgbDist = sqrt(dr * dr + dg * dg + db * db)
                    if rgbDist < 42.0 {
                        unite(i, j)
                    }
                }
            }

            var clusters: [Int: [Int]] = [:]
            for idx in 0..<n {
                clusters[find(idx), default: []].append(idx)
            }

            var groups: [DuplicateGroup] = []
            var totalRedundant = 0
            var totalReclaimable: Int64 = 0

            for (_, memberIndices) in clusters where memberIndices.count > 1 {
                let sortedIndices = memberIndices.sorted { ia, ib in
                    let a = entries[ia].item
                    let b = entries[ib].item
                    if a.pixelCount != b.pixelCount { return a.pixelCount > b.pixelCount }
                    if a.hasMusic != b.hasMusic { return a.hasMusic }
                    if a.fileSize != b.fileSize { return a.fileSize > b.fileSize }
                    return a.addedAt < b.addedAt
                }

                let anchor = entries[sortedIndices[0]]
                var candidates: [DuplicateCandidateItem] = []
                var groupReclaim: Int64 = 0

                for (pos, idx) in sortedIndices.enumerated() {
                    let cand = entries[idx]
                    if pos == 0 {
                        candidates.append(DuplicateCandidateItem(
                            item: cand.item,
                            isRecommendedKeep: true,
                            similarityPercent: 100,
                            reason: "最高规格 · 推荐保留"
                        ))
                        continue
                    }
                    let exact = anchor.item.fileSize > 0
                        && anchor.item.fileSize == cand.item.fileSize
                        && anchor.fp.prefixDigest != nil
                        && anchor.fp.prefixDigest == cand.fp.prefixDigest

                    let sim: Int
                    let reason: String
                    if exact {
                        sim = 100
                        reason = "100% 完全一致（重复文件）"
                    } else {
                        let dDist = Double((anchor.fp.dHash ^ cand.fp.dHash).nonzeroBitCount)
                        let aDist = Double((anchor.fp.aHash ^ cand.fp.aHash).nonzeroBitCount)
                        let rawSim = Int((1.0 - (dDist * 0.65 + aDist * 0.35) / 64.0) * 100.0)
                        sim = min(99, max(75, rawSim))
                        if cand.item.pixelCount > 0 && anchor.item.pixelCount > cand.item.pixelCount {
                            reason = "疑似低清晰度版本（\(sim)% 相似）"
                        } else if anchor.item.mediaType != cand.item.mediaType {
                            reason = "动/静双版本近似（\(sim)% 相似）"
                        } else {
                            reason = "画面高度相似（\(sim)%）"
                        }
                    }
                    groupReclaim += max(0, cand.item.fileSize)
                    totalRedundant += 1
                    candidates.append(DuplicateCandidateItem(
                        item: cand.item,
                        isRecommendedKeep: false,
                        similarityPercent: sim,
                        reason: reason
                    ))
                }
                totalReclaimable += groupReclaim
                groups.append(DuplicateGroup(
                    id: anchor.item.id,
                    items: candidates,
                    reclaimableBytes: groupReclaim
                ))
            }

            groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
            return (newFPs, DuplicateScanReport(
                groups: groups,
                scannedCount: n,
                totalRedundantCount: totalRedundant,
                totalReclaimableBytes: totalReclaimable
            ))
        }.value

        if !computedFPs.isEmpty {
            for idx in items.indices {
                if let fp = computedFPs[items[idx].id] {
                    items[idx].visualFingerprint = fp
                }
            }
            saveCatalogDebounced()
        }
        return report
    }

    nonisolated private static func computeVisualFingerprint(imageURL: URL, sourceURL: URL) -> CachedVisualFingerprint? {
        guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let w = 9
        let h = 8
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &raw,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var luma = [Float](repeating: 0, count: w * h)
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
        var sumL: Float = 0
        var minL: Float = 255
        var maxL: Float = 0

        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let r = Float(raw[idx])
                let g = Float(raw[idx + 1])
                let b = Float(raw[idx + 2])
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luma[y * w + x] = lum
                if x < 8 {
                    sumR += r
                    sumG += g
                    sumB += b
                    sumL += lum
                    minL = min(minL, lum)
                    maxL = max(maxL, lum)
                }
            }
        }

        var dHash: UInt64 = 0
        var dBit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if luma[y * 9 + x] > luma[y * 9 + x + 1] {
                    dHash |= (1 << dBit)
                }
                dBit += 1
            }
        }

        let meanL = sumL / 64.0
        var aHash: UInt64 = 0
        var aBit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if luma[y * 9 + x] >= meanL {
                    aHash |= (1 << aBit)
                }
                aBit += 1
            }
        }

        var prefixDigest: String? = nil
        if let fh = try? FileHandle(forReadingFrom: sourceURL) {
            let chunk = fh.readData(ofLength: 65536)
            try? fh.close()
            if !chunk.isEmpty {
                prefixDigest = SHA256.hash(data: chunk).map { String(format: "%02x", $0) }.joined()
            }
        }

        return CachedVisualFingerprint(
            dHash: dHash,
            aHash: aHash,
            meanR: sumR / 64.0,
            meanG: sumG / 64.0,
            meanB: sumB / 64.0,
            lumaRange: UInt8(max(0, min(255, Int((maxL - minL).rounded())))),
            prefixDigest: prefixDigest
        )
    }

    // MARK: - GitHub Latest Release Check (zero API quota via 302 Location)
    func checkForAppUpdate() async -> (hasUpdate: Bool, latestTag: String, releaseURL: URL, errorMessage: String?) {
        let fallbackURL = AppInfoConstants.repoURL.appendingPathComponent("releases/latest")
        let delegate = NonRedirectUpdateDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var latestTag: String? = nil
        var req = URLRequest(url: fallbackURL)
        req.httpMethod = "HEAD"
        if let (_, resp) = try? await session.data(for: req),
           let http = resp as? HTTPURLResponse,
           let loc = http.value(forHTTPHeaderField: "Location"),
           let tagRange = loc.range(of: "/releases/tag/") {
            latestTag = String(loc[tagRange.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }

        if latestTag == nil {
            let apiURL = URL(string: "https://api.github.com/repos/XiaonanXY/WallPull/releases/latest")!
            var apiReq = URLRequest(url: apiURL, timeoutInterval: 10)
            apiReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await URLSession.shared.data(for: apiReq),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                latestTag = tag
            }
        }

        guard let tag = latestTag, !tag.isEmpty else {
            return (false, AppInfoConstants.version, fallbackURL, "无法连接 GitHub 检查更新，请检查网络或代理设置")
        }
        let hasNewer = Self.compareVersionStrings(remote: tag, local: AppInfoConstants.version) > 0
        let targetURL = AppInfoConstants.repoURL.appendingPathComponent("releases/tag/\(tag)")
        return (hasNewer, tag, targetURL, nil)
    }

    nonisolated private static func compareVersionStrings(remote: String, local: String) -> Int {
        func parse(_ s: String) -> [Int] {
            let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: "-").first.map(String.init) ?? ""
            return clean.split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = parse(remote)
        let l = parse(local)
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv ? 1 : -1 }
        }
        return 0
    }

    func requestPhotoAddPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited { return true }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status == .authorized || status == .limited)
            }
        }
    }

    nonisolated static func compositeOfflineStudioLayers(
        studioItemDir: URL,
        bundle: OfflineStudioBundle,
        visibleGroupKeys: Set<String>,
        trimBounds: Bool
    ) -> UIImage? {
        let selected = bundle.groups.filter { visibleGroupKeys.contains($0.key) }
        guard !selected.isEmpty else { return nil }

        var loadedImages: [CGImage] = []
        for g in selected {
            let url = studioItemDir.appendingPathComponent(g.pngFileName)
            if let data = try? Data(contentsOf: url),
               let ui = UIImage(data: data),
               let cg = ui.cgImage {
                loadedImages.append(cg)
            }
        }
        guard let first = loadedImages.first else { return nil }
        let w = first.width
        let h = first.height
        guard w > 0, h > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clear(rect)
        for cg in loadedImages {
            ctx.draw(cg, in: rect)
        }
        guard let composed = ctx.makeImage() else { return nil }
        if trimBounds, let trimmed = trimAlphaBounds(composed) {
            return UIImage(cgImage: trimmed)
        }
        return UIImage(cgImage: composed)
    }

    nonisolated static func trimAlphaBounds(_ cg: CGImage) -> CGImage? {
        let w = cg.width
        let h = cg.height
        guard w > 4, h > 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1
        for y in 0..<h {
            let rowStart = y * w * 4
            for x in 0..<w {
                if pixels[rowStart + x * 4 + 3] > 8 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 4
        let cx = max(0, minX - pad)
        let cy = max(0, minY - pad)
        let cw = min(w - cx, maxX - minX + 1 + pad * 2)
        let ch = min(h - cy, maxY - minY + 1 + pad * 2)
        return cg.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch))
    }

    nonisolated private static func detectMeaningfulAlpha(cgImage: CGImage) -> Bool {
        let alpha = cgImage.alphaInfo
        guard alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast else {
            return false
        }
        let w = 48
        let h = 48
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var transparentCount = 0
        for i in stride(from: 3, to: pixels.count, by: 4) {
            if pixels[i] < 220 { transparentCount += 1 }
        }
        return Double(transparentCount) / Double(w * h) >= 0.05
    }

    nonisolated private static func classifyColorBucket(cgImage: CGImage) -> String {
        let w = 24
        let h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "dark" }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rSum = 0.0, gSum = 0.0, bSum = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255.0
            if a < 0.25 { continue }
            rSum += Double(pixels[i]) * a
            gSum += Double(pixels[i + 1]) * a
            bSum += Double(pixels[i + 2]) * a
            weight += a
        }
        guard weight > 0 else { return "dark" }
        let r = rSum / weight / 255.0
        let g = gSum / weight / 255.0
        let b = bSum / weight / 255.0
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let l = (maxC + minC) * 0.5
        if l < 0.26 { return "dark" }
        if l > 0.78 && delta < 0.16 { return "light" }
        if delta < 0.10 { return l >= 0.5 ? "light" : "dark" }
        var hue: Double = 0
        if maxC == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) * 60
        } else if maxC == g {
            hue = (((b - r) / delta) + 2) * 60
        } else {
            hue = (((r - g) / delta) + 4) * 60
        }
        if hue < 0 { hue += 360 }
        if hue >= 180 && hue < 255 { return "blue" }
        if hue >= 255 && hue < 330 { return "purple" }
        if hue >= 75 && hue < 180 { return "green" }
        return "warm"
    }
}
