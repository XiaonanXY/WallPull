import ImageIO
import SwiftUI
import UIKit

private enum CropAspectPreset: String, CaseIterable, Identifiable {
    case free = "自由"
    case square = "1:1 头像"
    case ipad = "4:3 iPad"
    case desktop = "16:9 桌面"
    case phone = "9:19.5 手机"

    var id: String { rawValue }

    var baseRatio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1.0
        case .ipad: return 4.0 / 3.0
        case .desktop: return 16.0 / 9.0
        case .phone: return 9.0 / 19.5
        }
    }
}

private enum CropDragCorner {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct ImageCropSheetView: View {
    let sourceImage: UIImage
    let titleText: String
    let isTransparent: Bool
    let contentRating: String?
    let nativePixelSizeOverride: CGSize?
    let fullResImageProvider: (() async -> UIImage?)?
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var normalizedImage: UIImage
    @State private var preset: CropAspectPreset = .free
    @State private var swapped: Bool = false
    @State private var normRect: CGRect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
    @State private var dragStartRect: CGRect? = nil
    @State private var isExportingFullRes: Bool = false

    init(
        sourceImage: UIImage,
        titleText: String,
        isTransparent: Bool = false,
        contentRating: String? = nil,
        nativePixelSizeOverride: CGSize? = nil,
        fullResImageProvider: (() async -> UIImage?)? = nil,
        vault: LocalVaultStore,
        localSend: LocalSendService,
        onClose: @escaping () -> Void
    ) {
        self.sourceImage = sourceImage
        self.titleText = titleText
        self.isTransparent = isTransparent
        self.contentRating = contentRating
        self.nativePixelSizeOverride = nativePixelSizeOverride
        self.fullResImageProvider = fullResImageProvider
        self.vault = vault
        self.localSend = localSend
        self.onClose = onClose
        _normalizedImage = State(initialValue: Self.normalizeUpOrientation(sourceImage))
    }

    private var effectiveScheme: ColorScheme {
        vault.appearanceMode.colorScheme ?? colorScheme
    }

    private var activeRatio: CGFloat? {
        guard let base = preset.baseRatio else { return nil }
        return swapped ? (1.0 / base) : base
    }

    private var imagePixelSize: CGSize {
        if let override = nativePixelSizeOverride, override.width > 0, override.height > 0 {
            return override
        }
        if let cg = normalizedImage.cgImage {
            return CGSize(width: cg.width, height: cg.height)
        }
        return CGSize(
            width: max(1, normalizedImage.size.width * normalizedImage.scale),
            height: max(1, normalizedImage.size.height * normalizedImage.scale)
        )
    }

    private var outputPixelRect: CGRect {
        Self.pixelRect(for: normRect, in: imagePixelSize)
    }

    nonisolated private static func pixelRect(for normalized: CGRect, in px: CGSize) -> CGRect {
        let maxW = max(1, Int(px.width.rounded()))
        let maxH = max(1, Int(px.height.rounded()))
        let x = max(0, min(maxW - 1, Int((normalized.minX * CGFloat(maxW)).rounded())))
        let y = max(0, min(maxH - 1, Int((normalized.minY * CGFloat(maxH)).rounded())))
        let w = max(1, min(maxW - x, Int((normalized.width * CGFloat(maxW)).rounded())))
        let h = max(1, min(maxH - y, Int((normalized.height * CGFloat(maxH)).rounded())))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CropAspectPreset.allCases) { opt in
                            let selected = preset == opt
                            Button {
                                preset = opt
                                resetRectForCurrentPreset()
                            } label: {
                                Text(opt.rawValue)
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(selected ? .white : .primary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .background(selected ? vault.accentColor : WallPullPalette.track(effectiveScheme), in: Capsule())
                            }
                            .buttonStyle(StickerPressButtonStyle())
                        }

                        Button {
                            swapped.toggle()
                            resetRectForCurrentPreset()
                        } label: {
                            Label("横竖互换", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(WallPullPalette.track(effectiveScheme), in: Capsule())
                        }
                        .disabled(activeRatio == nil)
                        .opacity(activeRatio == nil ? 0.45 : 1.0)
                        .buttonStyle(StickerPressButtonStyle())
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 6)

                HStack {
                    let out = outputPixelRect
                    Text("原图 \(Int(imagePixelSize.width)) × \(Int(imagePixelSize.height))  →  裁切输出 \(Int(out.width)) × \(Int(out.height)) px")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    if isExportingFullRes {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在渲染原画…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(vault.accentColor)
                        }
                    }
                }
                .padding(.horizontal, 16)

                GeometryReader { outerGeo in
                    let fitSize = aspectFitSize(for: imagePixelSize, inside: outerGeo.size)
                    let originX = (outerGeo.size.width - fitSize.width) / 2.0
                    let originY = (outerGeo.size.height - fitSize.height) / 2.0

                    ZStack(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            if isTransparent {
                                CheckerboardView(squareSize: 12)
                                    .frame(width: fitSize.width, height: fitSize.height)
                            }

                            Image(uiImage: normalizedImage)
                                .resizable()
                                .frame(width: fitSize.width, height: fitSize.height)

                            cropDimMask(canvasSize: fitSize)
                        }
                        .frame(width: fitSize.width, height: fitSize.height)
                        .clipped()

                        cropHandlesOverlay(canvasSize: fitSize)
                    }
                    .frame(width: fitSize.width, height: fitSize.height)
                    .offset(x: originX, y: originY)
                }
                .padding(18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button {
                            Task {
                                guard let cropped = await renderFullResolutionCroppedImage() else { return }
                                vault.copyUIImageLosslessToClipboard(
                                    cropped,
                                    toastMessage: isTransparent
                                        ? "已无损复制透明裁切图到剪贴板，切去微信直接粘贴"
                                        : "已无损复制裁切图片到剪贴板，切去微信直接粘贴"
                                )
                            }
                        } label: {
                            Label("复制裁切图（贴微信）", systemImage: "doc.on.doc.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(vault.accentColor, in: Capsule())
                        }
                        .disabled(isExportingFullRes)
                        .buttonStyle(StickerPressButtonStyle())

                        Button {
                            Task {
                                guard let cropped = await renderFullResolutionCroppedImage() else { return }
                                await vault.saveUIImageToPhotos(cropped)
                            }
                        } label: {
                            Label("存入相册", systemImage: "square.and.arrow.down.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(WallPullPalette.track(effectiveScheme), in: Capsule())
                        }
                        .disabled(isExportingFullRes)
                        .buttonStyle(StickerPressButtonStyle())

                        Button {
                            Task {
                                guard let cropped = await renderFullResolutionCroppedImage() else { return }
                                _ = await vault.importCutoutImage(
                                    cropped,
                                    title: "\(titleText) · 裁切",
                                    isTransparent: isTransparent,
                                    contentRating: contentRating,
                                    sourceDevice: isTransparent ? "透视拆解台 · 裁切" : "智能比例裁切台",
                                    toastMessage: "已将裁切成品收入离线壁纸库"
                                )
                            }
                        } label: {
                            Label("保存到壁纸库", systemImage: "tray.and.arrow.down.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(WallPullPalette.track(effectiveScheme), in: Capsule())
                        }
                        .disabled(isExportingFullRes)
                        .buttonStyle(StickerPressButtonStyle())
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 12)
            }
            .background(WallPullPalette.canvas(effectiveScheme).ignoresSafeArea())
            .navigationTitle("智能比例裁切台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose)
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(vault.appearanceMode.colorScheme)
        .wallPullFeedbackOverlay(vault: vault, localSend: localSend, bottomPadding: 76)
    }

    @ViewBuilder
    private func cropDimMask(canvasSize: CGSize) -> some View {
        let rx = normRect.minX * canvasSize.width
        let ry = normRect.minY * canvasSize.height
        let rw = normRect.width * canvasSize.width
        let rh = normRect.height * canvasSize.height

        Path { path in
            path.addRect(CGRect(origin: .zero, size: canvasSize))
            path.addRect(CGRect(x: rx, y: ry, width: rw, height: rh))
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cropHandlesOverlay(canvasSize: CGSize) -> some View {
        let rx = normRect.minX * canvasSize.width
        let ry = normRect.minY * canvasSize.height
        let rw = normRect.width * canvasSize.width
        let rh = normRect.height * canvasSize.height

        ZStack(alignment: .topLeading) {
            ZStack {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                VStack {
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.32)).frame(height: 0.75)
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.32)).frame(height: 0.75)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.32)).frame(width: 0.75)
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.32)).frame(width: 0.75)
                    Spacer()
                }
            }
            .frame(width: max(12, rw), height: max(12, rh))
            .contentShape(Rectangle())
            .offset(x: rx, y: ry)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStartRect ?? normRect
                        if dragStartRect == nil { dragStartRect = base }
                        let dx = value.translation.width / max(1, canvasSize.width)
                        let dy = value.translation.height / max(1, canvasSize.height)
                        normRect = CGRect(
                            x: min(max(0, base.minX + dx), 1.0 - base.width),
                            y: min(max(0, base.minY + dy), 1.0 - base.height),
                            width: base.width,
                            height: base.height
                        )
                    }
                    .onEnded { _ in dragStartRect = nil }
            )

            cornerHandle(corner: .topLeft, x: rx, y: ry, canvasSize: canvasSize)
            cornerHandle(corner: .topRight, x: rx + rw, y: ry, canvasSize: canvasSize)
            cornerHandle(corner: .bottomLeft, x: rx, y: ry + rh, canvasSize: canvasSize)
            cornerHandle(corner: .bottomRight, x: rx + rw, y: ry + rh, canvasSize: canvasSize)
        }
    }

    private func cornerHandle(
        corner: CropDragCorner,
        x: CGFloat,
        y: CGFloat,
        canvasSize: CGSize
    ) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(vault.accentColor, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStartRect ?? normRect
                        if dragStartRect == nil { dragStartRect = base }
                        let dx = value.translation.width / max(1, canvasSize.width)
                        let dy = value.translation.height / max(1, canvasSize.height)
                        normRect = resizeRect(base: base, corner: corner, dx: dx, dy: dy)
                    }
                    .onEnded { _ in dragStartRect = nil }
            )
    }

    private func resizeRect(base: CGRect, corner: CropDragCorner, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minFrac: CGFloat = 0.08
        var x = base.minX
        var y = base.minY
        var w = base.width
        var h = base.height

        switch corner {
        case .topLeft:
            let nx = min(max(0, base.minX + dx), base.maxX - minFrac)
            let ny = min(max(0, base.minY + dy), base.maxY - minFrac)
            w = base.maxX - nx
            h = base.maxY - ny
            x = nx
            y = ny
        case .topRight:
            let ny = min(max(0, base.minY + dy), base.maxY - minFrac)
            w = min(max(minFrac, base.width + dx), 1.0 - base.minX)
            h = base.maxY - ny
            y = ny
        case .bottomLeft:
            let nx = min(max(0, base.minX + dx), base.maxX - minFrac)
            w = base.maxX - nx
            h = min(max(minFrac, base.height + dy), 1.0 - base.minY)
            x = nx
        case .bottomRight:
            w = min(max(minFrac, base.width + dx), 1.0 - base.minX)
            h = min(max(minFrac, base.height + dy), 1.0 - base.minY)
        }

        if let targetRatio = activeRatio {
            let px = imagePixelSize
            let imgRatio = px.width / max(1, px.height)
            let normRatio = targetRatio / max(0.01, imgRatio)
            if abs(dx) >= abs(dy) {
                h = w / normRatio
                if corner == .topLeft || corner == .topRight {
                    y = base.maxY - h
                    if y < 0 {
                        h = base.maxY
                        y = 0
                        w = h * normRatio
                        if corner == .topLeft { x = base.maxX - w }
                    }
                } else if y + h > 1.0 {
                    h = 1.0 - y
                    w = h * normRatio
                    if corner == .bottomLeft { x = base.maxX - w }
                }
            } else {
                w = h * normRatio
                if corner == .topLeft || corner == .bottomLeft {
                    x = base.maxX - w
                    if x < 0 {
                        w = base.maxX
                        x = 0
                        h = w / normRatio
                        if corner == .topLeft { y = base.maxY - h }
                    }
                } else if x + w > 1.0 {
                    w = 1.0 - x
                    h = w / normRatio
                    if corner == .topRight { y = base.maxY - h }
                }
            }
        }

        guard w >= minFrac, h >= minFrac else { return base }
        return CGRect(x: max(0, x), y: max(0, y), width: min(1.0 - max(0, x), w), height: min(1.0 - max(0, y), h))
    }

    private func resetRectForCurrentPreset() {
        guard let targetRatio = activeRatio else {
            normRect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
            return
        }
        let px = imagePixelSize
        let imgRatio = px.width / max(1, px.height)
        if imgRatio > targetRatio {
            let h: CGFloat = 1.0
            let w = min(1.0, max(0.08, targetRatio / imgRatio))
            normRect = CGRect(x: (1.0 - w) / 2.0, y: 0.0, width: w, height: h)
        } else {
            let w: CGFloat = 1.0
            let h = min(1.0, max(0.08, imgRatio / targetRatio))
            normRect = CGRect(x: 0.0, y: (1.0 - h) / 2.0, width: w, height: h)
        }
    }

    private func aspectFitSize(for imageSize: CGSize, inside boxSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, boxSize.width > 0, boxSize.height > 0 else {
            return CGSize(width: 240, height: 180)
        }
        let scale = min(boxSize.width / imageSize.width, boxSize.height / imageSize.height)
        return CGSize(
            width: max(40, imageSize.width * scale),
            height: max(40, imageSize.height * scale)
        )
    }

    private func renderFullResolutionCroppedImage() async -> UIImage? {
        if isExportingFullRes { return nil }
        isExportingFullRes = true
        defer { isExportingFullRes = false }

        let target: UIImage?
        if let provider = fullResImageProvider {
            let fetched = await provider()
            if fetched == nil {
                vault.showToast("未能获取原图，已按本地预览分辨率裁切")
            }
            target = fetched
        } else {
            target = nil
        }

        let currentNormRect = normRect
        let fallbackPreview = normalizedImage
        return await Task.detached(priority: .userInitiated) {
            let baseImage = target ?? fallbackPreview
            return Self.cropFullResolutionImage(baseImage, normRect: currentNormRect)
        }.value
    }

    nonisolated static func cropFullResolutionImage(_ image: UIImage, normRect: CGRect) -> UIImage? {
        let base = normalizeUpOrientation(image)
        guard let cg = base.cgImage else { return nil }
        let pxRect = pixelRect(
            for: normRect,
            in: CGSize(width: cg.width, height: cg.height)
        )
        guard let cropped = cg.cropping(to: pxRect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1.0, orientation: .up)
    }

    nonisolated static func loadPreviewAndPixelSize(from url: URL, maxPixelSize: Int = 2048) -> (UIImage, CGSize)? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            return nil
        }
        var pixelSize = CGSize.zero
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
           w > 0, h > 0 {
            let orient = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
            let swapped = (5...8).contains(orient)
            pixelSize = swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        let preview = UIImage(cgImage: cgThumb, scale: 1.0, orientation: .up)
        if pixelSize.width <= 0 || pixelSize.height <= 0 {
            pixelSize = CGSize(width: cgThumb.width, height: cgThumb.height)
        }
        return (preview, pixelSize)
    }

    nonisolated static func loadFullResolutionImage(from url: URL) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
        else {
            return nil
        }
        var orientation: UIImage.Orientation = .up
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let rawExif = props[kCGImagePropertyOrientation] as? UInt32 {
            orientation = uiImageOrientation(fromExif: rawExif)
        }
        return normalizeUpOrientation(UIImage(cgImage: cg, scale: 1.0, orientation: orientation))
    }

    nonisolated private static func uiImageOrientation(fromExif v: UInt32) -> UIImage.Orientation {
        switch v {
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    nonisolated private static func normalizeUpOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, let cg = image.cgImage {
            if abs(image.scale - 1.0) < 0.001 {
                return image
            }
            return UIImage(cgImage: cg, scale: 1.0, orientation: .up)
        }
        let pxW = max(1, image.size.width * image.scale)
        let pxH = max(1, image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: pxW, height: pxH), format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: pxW, height: pxH)))
        }
    }
}
