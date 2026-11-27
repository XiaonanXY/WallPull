import ImageIO
import SwiftUI
import UIKit

enum StudioLayerBackdrop: String, CaseIterable, Identifiable {
    case checker = "透明棋盘"
    case dark = "纯黑底"
    case light = "纯白底"
    var id: String { rawValue }
}

struct SceneLayerStudioView: View {
    let item: VaultItem
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var onlineManifest: StudioManifestDTO? = nil
    @State private var offlineBundle: OfflineStudioBundle? = nil
    @State private var visibleLayerIndices: Set<Int> = []
    @State private var visibleOfflineKeys: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @State private var compositedImage: UIImage? = nil
    @State private var originalImage: UIImage? = nil
    @State private var compareMode: Bool = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var isRendering: Bool = true
    @State private var statusMessage: String? = nil
    @State private var backdrop: StudioLayerBackdrop = .checker
    @State private var trimBounds: Bool = true
    @State private var isZoomed: Bool = false
    @State private var showSidebarInspector: Bool = true
    @State private var showCompactInspectorSheet: Bool = false
    @State private var isCompositedTrimmed: Bool = false
    @State private var isBatchExportingCharacters: Bool = false
    @State private var renderTask: Task<Void, Never>? = nil
    @State private var showCropSheet: Bool = false

    private var effectiveScheme: ColorScheme {
        vault.appearanceMode.colorScheme ?? colorScheme
    }

    private var chromeForeground: Color {
        .primary
    }

    private var chromePillFill: Color {
        WallPullPalette.track(effectiveScheme)
    }

    private var windowSafeInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 20, left: 0, bottom: 16, right: 0)
    }

    private var isOnlineMode: Bool {
        onlineManifest != nil && localSend.primaryPCPeer != nil && item.remoteID != nil
    }

    private var isAllLayersHidden: Bool {
        if let m = onlineManifest, !m.layers.isEmpty {
            return visibleLayerIndices.isEmpty
        }
        if let b = offlineBundle, !b.groups.isEmpty {
            return visibleOfflineKeys.isEmpty
        }
        return false
    }

    private var includeBackground: Bool {
        if let m = onlineManifest {
            let bgIndices = m.groups.filter { $0.role == "background" }.flatMap(\.layerIndices)
            return bgIndices.contains { visibleLayerIndices.contains($0) }
        }
        if let b = offlineBundle {
            return b.groups.filter { $0.role == "background" }.contains { visibleOfflineKeys.contains($0.key) }
        }
        return true
    }

    var body: some View {
        ZStack {
            WallPullPalette.canvas(effectiveScheme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .background(WallPullPalette.canvas(effectiveScheme))

                Divider()

                HStack(spacing: 0) {
                    stageCanvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    if showSidebarInspector && hSizeClass == .regular {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(WallPullPalette.hairline(effectiveScheme))
                                .frame(width: 1)
                            inspectorPanel
                                .frame(width: 320)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(vault.appearanceMode.colorScheme)
        .wallPullFeedbackOverlay(vault: vault, localSend: localSend, bottomPadding: 84)
        .sheet(isPresented: $showCompactInspectorSheet) {
            NavigationView {
                inspectorPanel
                    .navigationTitle("图层拆解清单")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showCompactInspectorSheet = false }
                        }
                    }
            }
            .navigationViewStyle(.stack)
            .preferredColorScheme(vault.appearanceMode.colorScheme)
        }
        .sheet(isPresented: $showCropSheet) {
            if let img = compositedImage {
                let activeLayersSnapshot = Array(visibleLayerIndices)
                let keepBG = includeBackground
                let trimmed = isCompositedTrimmed
                let nativeOverride: CGSize? = {
                    guard let m = onlineManifest, m.canvasWidth > 0, m.canvasHeight > 0 else {
                        return nil
                    }
                    if !trimmed {
                        return CGSize(width: m.canvasWidth, height: m.canvasHeight)
                    }
                    if let cg = img.cgImage {
                        let scale = max(1.0, CGFloat(max(m.canvasWidth, m.canvasHeight)) / 2048.0)
                        return CGSize(
                            width: (CGFloat(cg.width) * scale).rounded(),
                            height: (CGFloat(cg.height) * scale).rounded()
                        )
                    }
                    return nil
                }()
                let fullResFetcher: (() async -> UIImage?)? = {
                    guard onlineManifest != nil, let peer = localSend.primaryPCPeer, let rid = item.remoteID else {
                        return nil
                    }
                    return {
                        await localSend.renderStudioFrame(
                            remoteID: rid,
                            visibleLayers: activeLayersSnapshot,
                            maxDimension: 0,
                            preserveTransparency: !keepBG,
                            trimBounds: trimmed,
                            peer: peer
                        )
                    }
                }()
                ImageCropSheetView(
                    sourceImage: img,
                    titleText: "\(item.title) · 拆图",
                    isTransparent: !includeBackground,
                    contentRating: item.contentRating,
                    nativePixelSizeOverride: nativeOverride,
                    fullResImageProvider: fullResFetcher,
                    vault: vault,
                    localSend: localSend,
                    onClose: { showCropSheet = false }
                )
            }
        }
        .task(id: item.id) {
            await loadStudioSession()
        }
        .onChange(of: hSizeClass) { nextClass in
            if nextClass == .regular && showCompactInspectorSheet {
                showCompactInspectorSheet = false
            }
        }
        .onChange(of: compareMode) { _ in
            if !includeBackground && trimBounds {
                triggerRecomposite()
            }
        }
        .onDisappear {
            renderTask?.cancel()
        }
    }

    @ViewBuilder
    private var backdropView: some View {
        switch backdrop {
        case .checker:
            CheckerboardView(squareSize: 18)
        case .dark:
            Color(hex: "#101016")
        case .light:
            Color.white
        }
    }

    private var stageCanvas: some View {
        ZStack {
            backdropView

            if compareMode && !isCompositedTrimmed, let orig = originalImage, let comp = compositedImage {
                TouchCompareSliderView(
                    beforeImage: orig,
                    afterImage: comp,
                    beforeLabel: "原图",
                    afterLabel: "当前拆解",
                    accentColor: vault.accentColor,
                    showsDarkBackdrop: false
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 82)
            } else if let compositedImage {
                ZoomableScrollImageView(
                    image: compositedImage,
                    isZoomed: $isZoomed,
                    fillMode: false,
                    externalZoomScale: $zoomScale
                )
                .padding(.bottom, 72)
            } else if isAllLayersHidden {
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("所有图层均已关闭，请在右侧点击图层或「恢复默认」")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Button("恢复默认图层") {
                        restoreDefaults()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(vault.accentColor, in: Capsule())
                    .buttonStyle(StickerPressButtonStyle())
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(WallPullPalette.canvas(effectiveScheme).opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
            } else if isRendering {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在解析 2D 角色与背景图层…")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(WallPullPalette.canvas(effectiveScheme).opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            } else if let statusMessage {
                VStack(spacing: 10) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.65))
                    Text(statusMessage)
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(WallPullPalette.canvas(effectiveScheme).opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1)
                )
            }

            VStack {
                HStack {
                    if isRendering && compositedImage != nil {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在重绘图层…")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(WallPullPalette.canvas(effectiveScheme).opacity(0.92), in: Capsule())
                        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.leading, 16)
                .allowsHitTesting(false)

                Spacer()

                VStack(spacing: 8) {
                    if !compareMode && compositedImage != nil {
                        HStack(spacing: 8) {
                            TactileRulerSliderView(
                                value: Binding(
                                    get: { Double(zoomScale * 100.0) },
                                    set: { nextPct in
                                        zoomScale = CGFloat(max(1.0, min(4.0, nextPct / 100.0)))
                                        isZoomed = zoomScale > 1.04
                                    }
                                ),
                                range: 100...400,
                                step: 10,
                                majorEvery: 5,
                                spacing: 8,
                                title: "缩放",
                                accentColor: vault.accentColor,
                                formatValue: { "\(Int($0.rounded()))%" }
                            )
                            if zoomScale > 1.05 {
                                Button {
                                    zoomScale = 1.0
                                    isZoomed = false
                                } label: {
                                    Text("1:1")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 10)
                                        .frame(height: 34)
                                        .background(WallPullPalette.canvas(effectiveScheme).opacity(0.92), in: Capsule())
                                        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1))
                                }
                                .buttonStyle(StickerPressButtonStyle())
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    bottomDock
                }
                .padding(.bottom, max(windowSafeInsets.bottom, 10))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundColor(chromeForeground)
                    .frame(width: 36, height: 36)
                    .background(chromePillFill, in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                        .foregroundColor(chromeForeground)
                        .lineLimit(1)
                    Text(isOnlineMode ? "实时直连" : "离线图层")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(isOnlineMode ? Color.green.opacity(0.85) : vault.accentColor, in: Capsule())
                }
                if let w = onlineManifest?.canvasWidth ?? offlineBundle?.canvasWidth,
                   let h = onlineManifest?.canvasHeight ?? offlineBundle?.canvasHeight {
                    Text("2D 透视拆解台 · 画布 \(w) × \(h)")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(chromePillFill, in: Capsule())

            Spacer()

            if originalImage != nil && compositedImage != nil {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        compareMode.toggle()
                    }
                } label: {
                    Label(compareMode ? "退出对比" : "原图对比", systemImage: "square.split.2x1")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(compareMode ? .white : chromeForeground)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(compareMode ? vault.accentColor : chromePillFill, in: Capsule())
                }
                .buttonStyle(StickerPressButtonStyle())
            }

            WallPullSegmentedPill(
                options: StudioLayerBackdrop.allCases,
                selection: $backdrop,
                label: { $0.rawValue },
                height: 34,
                lightOnDarkBackdrop: false
            )

            Button {
                trimBounds.toggle()
                triggerRecomposite()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: trimBounds ? "crop" : "square.dashed")
                        .font(.system(size: 13, weight: .bold))
                    Text("自动裁边")
                        .font(.system(size: 12.5, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(trimBounds ? .white : chromeForeground)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(trimBounds ? vault.accentColor : chromePillFill, in: Capsule())
            }
            .disabled((onlineManifest == nil && offlineBundle == nil) || isRendering)
            .buttonStyle(StickerPressButtonStyle())

            Button {
                stripBackgroundAndEffects()
            } label: {
                Label("一键抠立绘", systemImage: "wand.and.stars")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(vault.accentColor, in: Capsule())
            }
            .disabled((onlineManifest == nil && offlineBundle == nil) || isRendering)
            .buttonStyle(StickerPressButtonStyle())

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    if hSizeClass == .regular {
                        showSidebarInspector.toggle()
                    } else {
                        showCompactInspectorSheet.toggle()
                    }
                }
            } label: {
                let isInspectorOpen = hSizeClass == .regular ? showSidebarInspector : showCompactInspectorSheet
                Image(systemName: isInspectorOpen ? "sidebar.right" : "list.bullet.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(chromeForeground)
                    .frame(width: 34, height: 34)
                    .background(chromePillFill, in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, max(windowSafeInsets.top, 20) + 6)
        .padding(.bottom, 10)
    }

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("图层分组")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
                Button("恢复默认") {
                    restoreDefaults()
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(vault.accentColor)
                .disabled(onlineManifest == nil && offlineBundle == nil)

                Button("全关") {
                    clearAllLayers()
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.secondary)
                .disabled(onlineManifest == nil && offlineBundle == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    if isOnlineMode, let manifest = onlineManifest {
                        ForEach(manifest.groups) { group in
                            onlineGroupRow(group: group, manifest: manifest)
                        }
                    } else if let bundle = offlineBundle {
                        ForEach(bundle.groups) { group in
                            offlineGroupRow(group: group)
                        }
                    }
                }
                .id(onlineManifest != nil ? "online_groups" : "offline_groups")
                .padding(12)
            }
        }
        .background(WallPullPalette.canvas(effectiveScheme))
    }

    private func roleBadge(_ role: String) -> (String, Color) {
        switch role {
        case "background": return ("背景", .blue)
        case "character": return ("角色立绘", vault.accentColor)
        case "effect": return ("光效氛围", .orange)
        default: return ("主体图层", .green)
        }
    }

    private func defaultLayerIndices(for group: StudioGroupDTO, in manifest: StudioManifestDTO) -> [Int] {
        let defaultSet = Set(manifest.layers.filter(\.defaultVisible).map(\.index))
        let defs = group.layerIndices.filter { defaultSet.contains($0) }
        return defs.isEmpty ? group.layerIndices : defs
    }

    private func toggleOnlineGroup(_ group: StudioGroupDTO, in manifest: StudioManifestDTO) {
        let anyOn = group.layerIndices.contains { visibleLayerIndices.contains($0) }
        if anyOn {
            group.layerIndices.forEach { visibleLayerIndices.remove($0) }
        } else {
            defaultLayerIndices(for: group, in: manifest).forEach { visibleLayerIndices.insert($0) }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        triggerRecomposite()
    }

    private func toggleOfflineGroup(_ group: OfflineStudioGroupLayer) {
        if visibleOfflineKeys.contains(group.key) {
            visibleOfflineKeys.remove(group.key)
        } else {
            visibleOfflineKeys.insert(group.key)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        triggerRecomposite()
    }

    private func clearAllLayers() {
        visibleLayerIndices.removeAll()
        visibleOfflineKeys.removeAll()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        triggerRecomposite()
    }

    private func onlineGroupRow(group: StudioGroupDTO, manifest: StudioManifestDTO) -> some View {
        let onCount = group.layerIndices.filter { visibleLayerIndices.contains($0) }.count
        let anyOn = onCount > 0
        let groupSet = Set(group.layerIndices)
        let isSoloed = anyOn && visibleLayerIndices.isSubset(of: groupSet)
        let isExpanded = expandedGroups.contains(group.key)
        let badge = roleBadge(group.role)
        let layers = manifest.layers.filter { group.layerIndices.contains($0.index) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    toggleOnlineGroup(group, in: manifest)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: anyOn ? "eye.fill" : "eye.slash")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(anyOn ? vault.accentColor : .secondary)
                            .frame(width: 28, height: 28)
                            .background(WallPullPalette.track(effectiveScheme), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text(badge.0)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(badge.1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(badge.1.opacity(0.14), in: Capsule())
                                Text("\(onCount)/\(group.layerIndices.count)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    if isSoloed {
                        restoreDefaults()
                    } else {
                        visibleLayerIndices = Set(defaultLayerIndices(for: group, in: manifest))
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        triggerRecomposite()
                    }
                } label: {
                    Text(isSoloed ? "还原" : "独显")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isSoloed ? .white : .primary)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(isSoloed ? vault.accentColor : WallPullPalette.track(effectiveScheme), in: Capsule())
                }
                .wallPullMinimumHitArea(32)
                .buttonStyle(.plain)

                if layers.count > 1 {
                    Button {
                        if isExpanded { expandedGroups.remove(group.key) }
                        else { expandedGroups.insert(group.key) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .wallPullMinimumHitArea(32)
                    .buttonStyle(.plain)
                }
            }

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(layers) { layer in
                        let isOn = visibleLayerIndices.contains(layer.index)
                        Button {
                            if isOn { visibleLayerIndices.remove(layer.index) }
                            else { visibleLayerIndices.insert(layer.index) }
                            triggerRecomposite()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(isOn ? vault.accentColor : .secondary)
                                Text(layer.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(isOn ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(10)
        .background(WallPullPalette.cardSurface(effectiveScheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1)
        )
        .opacity(anyOn ? 1.0 : 0.65)
    }

    private func offlineGroupRow(group: OfflineStudioGroupLayer) -> some View {
        let isOn = visibleOfflineKeys.contains(group.key)
        let isSoloed = isOn && visibleOfflineKeys == [group.key]
        let badge = roleBadge(group.role)
        return HStack(spacing: 8) {
            Button {
                toggleOfflineGroup(group)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isOn ? "eye.fill" : "eye.slash")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(isOn ? vault.accentColor : .secondary)
                        .frame(width: 28, height: 28)
                        .background(WallPullPalette.track(effectiveScheme), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(badge.0)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(badge.1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(badge.1.opacity(0.14), in: Capsule())
                    }

                    Spacer(minLength: 4)
                }
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if isSoloed {
                    restoreDefaults()
                } else {
                    visibleOfflineKeys = [group.key]
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    triggerRecomposite()
                }
            } label: {
                Text(isSoloed ? "还原" : "独显")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(isSoloed ? .white : .primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(isSoloed ? vault.accentColor : WallPullPalette.track(effectiveScheme), in: Capsule())
            }
            .wallPullMinimumHitArea(32)
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(WallPullPalette.cardSurface(effectiveScheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1)
        )
        .opacity(isOn ? 1.0 : 0.65)
    }

    private var bottomDock: some View {
        CenteredAdaptiveDock {
            HStack(spacing: 10) {
                Button {
                    guard let compositedImage else { return }
                    vault.copyUIImageLosslessToClipboard(compositedImage)
                } label: {
                    Label("复制透明图（贴微信）", systemImage: "doc.on.doc.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(vault.accentColor, in: Capsule())
                }
                .disabled(compositedImage == nil)
                .buttonStyle(StickerPressButtonStyle())

                Button {
                    guard let compositedImage else { return }
                    Task {
                        await vault.importCutoutImage(
                            compositedImage,
                            title: "\(item.title) · 拆图",
                            isTransparent: !includeBackground,
                            contentRating: item.contentRating
                        )
                    }
                } label: {
                    Label("保存拆图入库", systemImage: "tray.and.arrow.down.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(chromeForeground)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(chromePillFill, in: Capsule())
                }
                .disabled(compositedImage == nil)
                .buttonStyle(StickerPressButtonStyle())

                Button {
                    guard let compositedImage else { return }
                    Task { await vault.saveUIImageToPhotos(compositedImage) }
                } label: {
                    Label("存入相册", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(chromeForeground)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(chromePillFill, in: Capsule())
                }
                .disabled(compositedImage == nil)
                .buttonStyle(StickerPressButtonStyle())

                Button {
                    showCropSheet = true
                } label: {
                    Label("比例裁切", systemImage: "crop")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(chromeForeground)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(chromePillFill, in: Capsule())
                }
                .disabled(compositedImage == nil || isRendering)
                .buttonStyle(StickerPressButtonStyle())

                if characterGroupsCount > 0 {
                    Button {
                        Task { await exportAllCharacterCutouts() }
                    } label: {
                        HStack(spacing: 5) {
                            if isBatchExportingCharacters {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "person.2.crop.square.stack")
                            }
                            Text(isBatchExportingCharacters ? "正在导出…" : "导出全部角色立绘 (\(characterGroupsCount))")
                        }
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(chromeForeground)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(chromePillFill, in: Capsule())
                    }
                    .disabled(isBatchExportingCharacters)
                    .buttonStyle(StickerPressButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(WallPullPalette.canvas(effectiveScheme).opacity(0.92), in: Capsule())
            .overlay(
                Capsule().strokeBorder(WallPullPalette.hairline(effectiveScheme), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var characterGroupsCount: Int {
        if let m = onlineManifest {
            return m.groups.filter { $0.role == "character" || $0.role == "subject" }.count
        }
        if let b = offlineBundle {
            return b.groups.filter { $0.role == "character" || $0.role == "subject" }.count
        }
        return 0
    }

    private func exportAllCharacterCutouts() async {
        guard !isBatchExportingCharacters else { return }
        isBatchExportingCharacters = true
        defer { isBatchExportingCharacters = false }

        var exported = 0
        if let m = onlineManifest, let peer = localSend.primaryPCPeer, let rid = item.remoteID {
            let targets = m.groups.filter { $0.role == "character" || $0.role == "subject" }
            for g in targets {
                let activeInGroup = g.layerIndices.filter { visibleLayerIndices.contains($0) }
                let exportLayers = activeInGroup.isEmpty ? defaultLayerIndices(for: g, in: m) : activeInGroup
                if let img = await localSend.renderStudioFrame(
                    remoteID: rid,
                    visibleLayers: exportLayers,
                    maxDimension: 2048,
                    preserveTransparency: true,
                    trimBounds: true,
                    peer: peer
                ) {
                    if await vault.importCutoutImage(
                        img,
                        title: "\(item.title) · \(g.title)",
                        isTransparent: true,
                        contentRating: item.contentRating
                    ) != nil {
                        exported += 1
                    }
                }
            }
        } else if let b = offlineBundle {
            let dir = vault.studioItemDir(for: item.id)
            let targets = b.groups.filter { $0.role == "character" || $0.role == "subject" }
            for g in targets {
                let img = await Task.detached(priority: .userInitiated) {
                    LocalVaultStore.compositeOfflineStudioLayers(
                        studioItemDir: dir,
                        bundle: b,
                        visibleGroupKeys: [g.key],
                        trimBounds: true
                    )
                }.value
                if let img,
                   await vault.importCutoutImage(
                       img,
                       title: "\(item.title) · \(g.title)",
                       isTransparent: true,
                       contentRating: item.contentRating
                   ) != nil {
                    exported += 1
                }
            }
        }
        if exported > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            vault.showToast("已批量导出 \(exported) 组透明角色立绘至离线壁纸库")
        } else {
            vault.showToast("未能导出有效角色立绘", isError: true)
        }
    }

    private func loadStudioSession() async {
        isRendering = true
        statusMessage = nil

        if originalImage == nil {
            let srcURL = vault.mediaURL(for: item)
            let thumbFallback = vault.thumbURL(for: item)
            let loadedOrig: UIImage? = await Task.detached(priority: .userInitiated) {
                let opts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                for u in [srcURL, thumbFallback].compactMap({ $0 }) {
                    if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                       let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                        return UIImage(cgImage: cg)
                    }
                }
                return nil
            }.value
            self.originalImage = loadedOrig
        }

        let existingOffline = vault.loadOfflineStudioBundle(for: item.id)

        if let peer = localSend.primaryPCPeer, let rid = item.remoteID,
           let manifest = await localSend.fetchStudioManifest(remoteID: rid, peer: peer) {
            onlineManifest = manifest
            visibleLayerIndices = Set(manifest.layers.filter(\.defaultVisible).map(\.index))
            if let existingOffline {
                offlineBundle = existingOffline
                visibleOfflineKeys = Set(existingOffline.groups.filter(\.defaultVisible).map(\.key))
            }
            if manifest.groups.count <= 3 {
                expandedGroups = Set(manifest.groups.map(\.key))
            }
            triggerRecomposite()
            // Cache offline group PNGs in background so future offline opens or mid-session drops keep working
            if existingOffline == nil {
                Task {
                    if let cached = await localSend.fetchAndCacheOfflineBundle(remoteID: rid, localItemID: item.id, peer: peer) {
                        await MainActor.run {
                            self.offlineBundle = cached
                            self.visibleOfflineKeys = Set(cached.groups.filter(\.defaultVisible).map(\.key))
                        }
                    }
                }
            }
            return
        }

        if let bundle = existingOffline {
            offlineBundle = bundle
            visibleOfflineKeys = Set(bundle.groups.filter(\.defaultVisible).map(\.key))
            triggerRecomposite()
            return
        }

        isRendering = false
        statusMessage = "请连接同一 Wi-Fi 下的电脑端 WallPull 以首次加载 2D 透视图层（加载后将自动缓存在平板本地支持离线拆图）"
    }

    private func restoreDefaults() {
        if let m = onlineManifest {
            visibleLayerIndices = Set(m.layers.filter(\.defaultVisible).map(\.index))
        }
        if let b = offlineBundle {
            visibleOfflineKeys = Set(b.groups.filter(\.defaultVisible).map(\.key))
        }
        triggerRecomposite()
    }

    private func stripBackgroundAndEffects() {
        trimBounds = true
        if let m = onlineManifest {
            var nextSet = Set<Int>()
            for group in m.groups where group.role != "background" && group.role != "effect" {
                defaultLayerIndices(for: group, in: m).forEach { nextSet.insert($0) }
            }
            visibleLayerIndices = nextSet
        }
        if let b = offlineBundle {
            visibleOfflineKeys = Set(
                b.groups
                    .filter { $0.role != "background" && $0.role != "effect" && ($0.defaultVisible || $0.role == "character") }
                    .map(\.key)
            )
        }
        triggerRecomposite()
    }

    private func triggerRecomposite() {
        renderTask?.cancel()
        if isAllLayersHidden {
            compositedImage = nil
            isRendering = false
            compareMode = false
            return
        }
        isRendering = true
        let activeLayersSnapshot = Array(visibleLayerIndices)
        let keepBGSnapshot = includeBackground
        let trimSnapshot = !compareMode && !keepBGSnapshot && trimBounds
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard !Task.isCancelled else { return }

            if onlineManifest != nil, let peer = localSend.primaryPCPeer, let rid = item.remoteID {
                let img = await localSend.renderStudioFrame(
                    remoteID: rid,
                    visibleLayers: activeLayersSnapshot,
                    maxDimension: 2048,
                    preserveTransparency: !keepBGSnapshot,
                    trimBounds: trimSnapshot,
                    peer: peer
                )
                guard !Task.isCancelled else { return }
                if let img {
                    await MainActor.run {
                        self.compositedImage = img
                        self.isCompositedTrimmed = trimSnapshot
                        self.isRendering = false
                    }
                    return
                }
                // PC dropped mid-session or render timed out: fall back gracefully to offline bundle if available
                let bundleFallback = offlineBundle ?? vault.loadOfflineStudioBundle(for: item.id)
                if let bundleFallback, let manifest = onlineManifest {
                    let activeGroups = Set(
                        manifest.groups
                            .filter { grp in grp.layerIndices.contains { visibleLayerIndices.contains($0) } }
                            .map(\.key)
                    )
                    let dir = vault.studioItemDir(for: item.id)
                    let trimFlag = !compareMode && !keepBGSnapshot && trimBounds
                    let offlineImg = await Task.detached(priority: .userInitiated) {
                        LocalVaultStore.compositeOfflineStudioLayers(
                            studioItemDir: dir,
                            bundle: bundleFallback,
                            visibleGroupKeys: activeGroups,
                            trimBounds: trimFlag
                        )
                    }.value
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.onlineManifest = nil
                        self.offlineBundle = bundleFallback
                        self.visibleOfflineKeys = activeGroups
                        if let offlineImg {
                            self.compositedImage = offlineImg
                            self.isCompositedTrimmed = trimFlag
                        }
                        self.isRendering = false
                        self.vault.showToast("电脑连接已断开，已平滑切换为本地离线图层模式")
                    }
                    return
                }
                await MainActor.run {
                    self.isRendering = false
                    if self.compositedImage == nil {
                        self.statusMessage = "与电脑端渲染连接中断，请刷新连接后重试"
                    } else {
                        self.vault.showToast("与电脑端实时渲染连接中断，已保留当前画面", isError: true)
                    }
                }
                return
            }

            if let bundle = offlineBundle {
                let dir = vault.studioItemDir(for: item.id)
                let keys = visibleOfflineKeys
                let shouldTrim = !compareMode && !includeBackground && trimBounds
                let img = await Task.detached(priority: .userInitiated) {
                    LocalVaultStore.compositeOfflineStudioLayers(
                        studioItemDir: dir,
                        bundle: bundle,
                        visibleGroupKeys: keys,
                        trimBounds: shouldTrim
                    )
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.compositedImage = img
                    self.isCompositedTrimmed = shouldTrim
                    self.isRendering = false
                }
            } else if let bundleFallback = vault.loadOfflineStudioBundle(for: item.id) {
                let activeGroups = Set(
                    bundleFallback.groups
                        .filter { g in g.defaultVisible || g.role == "character" }
                        .map(\.key)
                )
                let dir = vault.studioItemDir(for: item.id)
                let trimFlag = !compareMode && !keepBGSnapshot && trimSnapshot
                let offlineImg = await Task.detached(priority: .userInitiated) {
                    LocalVaultStore.compositeOfflineStudioLayers(
                        studioItemDir: dir,
                        bundle: bundleFallback,
                        visibleGroupKeys: activeGroups,
                        trimBounds: trimFlag
                    )
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.onlineManifest = nil
                    self.offlineBundle = bundleFallback
                    self.visibleOfflineKeys = activeGroups
                    if let offlineImg {
                        self.compositedImage = offlineImg
                        self.isCompositedTrimmed = trimFlag
                    }
                    self.isRendering = false
                }
            } else {
                await MainActor.run {
                    self.onlineManifest = nil
                    self.isRendering = false
                    if self.compositedImage == nil {
                        self.statusMessage = "与电脑端连接已断开，且本地暂无离线图层缓存"
                    }
                }
            }
        }
    }
}
