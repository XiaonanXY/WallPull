import Foundation
import SwiftUI

enum VaultMediaType: String, Codable, Hashable {
    case image
    case video
}

enum ColorBucketKind: String, Codable, CaseIterable, Identifiable {
    case dark
    case light
    case blue
    case purple
    case green
    case warm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: return "曜石暗色"
        case .light: return "纯净浅白"
        case .blue: return "冰川冷蓝"
        case .purple: return "赛博紫粉"
        case .green: return "森系青绿"
        case .warm: return "落日暖色"
        }
    }

    var swatchColor: Color {
        switch self {
        case .dark: return Color(hex: "#23232F")
        case .light: return Color(hex: "#F1F1F7")
        case .blue: return Color(hex: "#3B82F6")
        case .purple: return Color(hex: "#A855F7")
        case .green: return Color(hex: "#10B981")
        case .warm: return Color(hex: "#F97316")
        }
    }
}

enum VaultCategoryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case image = "图片"
    case video = "视频"
    case favorite = "♥ 收藏"

    var id: String { rawValue }
}

enum VaultSortMode: String, CaseIterable, Identifiable {
    case newest = "最近入库"
    case title = "名称 A–Z"
    case size = "占用空间优先"
    case resolution = "分辨率优先"

    var id: String { rawValue }
}

enum ContentRatingFilter: String, CaseIterable, Identifiable {
    case all = "全部分级"
    case everyone = "全年龄安全"
    case mature = "擦边 / 限制级"

    var id: String { rawValue }
}

enum SpecFilter: String, CaseIterable, Identifiable {
    case all = "全部规格"
    case uhd4k = "4K+ 超清"
    case landscape = "横屏宽幅"
    case portrait = "竖屏立绘"
    case audio = "♪ 含配乐"
    case layered = "✦ 可拆图层"

    var id: String { rawValue }
}

enum CardAspectMode: String, Codable, CaseIterable, Identifiable {
    case widescreen = "16:10 横屏"
    case adaptive = "原图比例"
    case square = "1:1 方形"

    var id: String { rawValue }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色白纸"
    case dark = "曜石暗夜"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct CachedVisualFingerprint: Codable, Hashable {
    var dHash: UInt64
    var aHash: UInt64
    var meanR: Float
    var meanG: Float
    var meanB: Float
    var lumaRange: UInt8
    var prefixDigest: String?
}

struct DuplicateCandidateItem: Identifiable, Hashable {
    var id: String { item.id }
    let item: VaultItem
    let isRecommendedKeep: Bool
    let isExactMatch: Bool
    let similarityPercent: Int
    let reason: String
}

struct TrustedLanPeerRecord: Codable, Hashable {
    let fingerprint: String
    var alias: String
    var incomingToken: String
    var outgoingToken: String
}

struct DuplicateGroup: Identifiable, Hashable {
    let id: String
    let items: [DuplicateCandidateItem]
    let reclaimableBytes: Int64
}

struct DuplicateScanReport {
    let groups: [DuplicateGroup]
    let scannedCount: Int
    let totalRedundantCount: Int
    let totalReclaimableBytes: Int64
}

struct VaultAudioTrack: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var fileName: String
    var durationSeconds: Double?
}

struct OfflineStudioGroupLayer: Codable, Hashable, Identifiable {
    let key: String
    var title: String
    var role: String
    var defaultVisible: Bool
    var pngFileName: String

    var id: String { key }
}

struct OfflineStudioBundle: Codable, Hashable {
    var canvasWidth: Int
    var canvasHeight: Int
    var groups: [OfflineStudioGroupLayer]
}

struct VaultItem: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var mediaType: VaultMediaType
    var fileName: String
    var thumbFileName: String?
    var previewVideoFileName: String?
    var width: Int
    var height: Int
    var durationSeconds: Double?
    var fileSize: Int64
    var isTransparentCutout: Bool
    var colorBucket: String?
    var contentRating: String?
    var isFavorite: Bool
    var addedAt: Date
    var sourceDevice: String
    var sha256: String?
    var remoteID: String?
    var audioTracks: [VaultAudioTrack]?
    var additionalFiles: [String]?
    var hasSceneLayers: Bool?
    var hasOfflineStudioBundle: Bool?
    var hasEmbeddedAudio: Bool? = nil
    var visualFingerprint: CachedVisualFingerprint?

    var resolutionText: String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    var durationText: String? {
        guard let sec = durationSeconds, sec > 0 else { return nil }
        let total = Int(sec.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 16.0 / 10.0 }
        return CGFloat(width) / CGFloat(height)
    }

    var pixelCount: Int64 {
        Int64(max(0, width)) * Int64(max(0, height))
    }

    var allMediaFileNames: [String] {
        [fileName] + (additionalFiles ?? [])
    }

    var contentRatingLabel: String {
        switch (contentRating ?? "Everyone").lowercased() {
        case "mature": return "限制级 18+"
        case "questionable": return "擦边 / 轻微敏感"
        default: return "全年龄安全"
        }
    }

    var hasMusic: Bool {
        if !(audioTracks ?? []).isEmpty { return true }
        if mediaType == .video { return hasEmbeddedAudio == true }
        return false
    }

    var supportsLayerStudio: Bool {
        hasSceneLayers == true || hasOfflineStudioBundle == true
    }
}

struct LocalSendDeviceInfo: Codable, Hashable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let port: Int?
    let protocolName: String?
    let download: Bool?
    let announce: Bool?
    let wallpullChannel: String?

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce, wallpullChannel
        case protocolName = "protocol"
    }

    var isWallPullDevice: Bool {
        if wallpullChannel == "wallpull-lan-v2" { return true }
        return (deviceModel ?? "").lowercased().contains("wallpull")
    }
}

struct LocalSendPeer: Identifiable, Hashable {
    var id: String { fingerprint }
    let fingerprint: String
    var alias: String
    var deviceModel: String?
    var deviceType: String?
    var ip: String
    var port: Int
    var scheme: String
    var supportsWallPullCatalog: Bool
    var lastSeen: Date
    var missedHeartbeats: Int = 0

    var isWallPullPC: Bool {
        let model = (deviceModel ?? "").lowercased()
        let dtype = (deviceType ?? "").lowercased()
        if dtype == "mobile" || model.contains("ipad") || model.contains("iphone") {
            return false
        }
        return supportsWallPullCatalog || model.contains("windows") || dtype == "desktop"
    }
}

struct CatalogAudioTrackDTO: Codable, Hashable, Identifiable {
    let index: Int
    let name: String
    let fileName: String
    let mimeType: String
    let size: Int64
    let isEmbedded: Bool?

    var id: Int { index }
}

struct PCCatalogItem: Identifiable, Codable, Hashable {
    let id: String
    let workshopId: String
    let title: String
    let mediaType: String
    let resolution: String?
    let duration: String?
    let fileSize: Int64
    let colorBucket: String?
    let fileName: String
    let mimeType: String
    let contentRating: String?
    let hasPreviewVideo: Bool?
    let hasSceneLayers: Bool?
    let assetCount: Int?
    let audioTracks: [CatalogAudioTrackDTO]?
    let isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id, workshopId, title, resolution, duration, fileSize, colorBucket, fileName, mimeType
        case contentRating, hasPreviewVideo, hasSceneLayers, assetCount, audioTracks, isFavorite
        case mediaType = "type"
    }

    var isVideo: Bool { mediaType == "video" }
    var hasMusic: Bool { !(audioTracks ?? []).isEmpty }
    var supportsStudio: Bool { hasSceneLayers == true }
    var isPCFavorite: Bool { isFavorite == true }
}

struct StudioLayerDTO: Codable, Hashable, Identifiable {
    let index: Int
    let nodeId: Int
    let name: String
    let groupKey: String
    let groupTitle: String
    let role: String
    let defaultVisible: Bool
    let hasPuppetMesh: Bool
    let blendMode: String

    var id: Int { index }
}

struct StudioGroupDTO: Codable, Hashable, Identifiable {
    let key: String
    let title: String
    let role: String
    let layerIndices: [Int]
    let defaultVisible: Bool

    var id: String { key }
}

struct StudioManifestDTO: Codable, Hashable {
    let canvasWidth: Int
    let canvasHeight: Int
    let layers: [StudioLayerDTO]
    let groups: [StudioGroupDTO]
}

struct OfflineBundleGroupDTO: Codable {
    let key: String
    let title: String
    let role: String
    let defaultVisible: Bool
    let pngBase64: String
}

struct OfflineBundleResponseDTO: Codable {
    let manifest: StudioManifestDTO
    let groups: [OfflineBundleGroupDTO]
}

struct TransferProgressState: Equatable {
    var title: String
    var currentFileIndex: Int
    var totalFiles: Int
    var fraction: Double
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var stageHint: String? = nil
}

struct ToastBannerState: Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

enum AppInfoConstants {
    static let version = "1.0.4"
    static let author = "Xiaonan"
    static let license = "GNU GPL-3.0"
    static let repoURL = URL(string: "https://github.com/XiaonanXY/WallPull")!
    static let feedbackURL = URL(string: "https://qm.qq.com/q/aYrBqaDlDi")!
    static let feedbackGroupNumber = "471426180"

    static let themePalette: [String] = [
        "#7C3AED",
        "#2563EB",
        "#00BFE8",
        "#FF1744",
        "#FF2D8D",
        "#F59E0B",
    ]
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        if cleaned.count == 6 {
            (r, g, b) = (int >> 16, (int >> 8) & 0xFF, int & 0xFF)
        } else {
            (r, g, b) = (124, 58, 237)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }
}

func normalizeHexColor(_ raw: String) -> String? {
    let cleaned = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    guard cleaned.count == 6,
          cleaned.allSatisfy({ $0.isHexDigit }) else {
        return nil
    }
    return "#\(cleaned)"
}

func formatFileSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 MB" }
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}
