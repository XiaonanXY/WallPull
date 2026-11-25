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
    @State private var isRendering: Bool = true
    @State private var statusMessage: String? = nil
    @State private var backdrop: StudioLayerBackdrop = .checker
    @State private var trimBounds: Bool = true
    @State private var isZoomed: Bool = false
    @State private var showInspector: Bool = true
    @State private var isBatchExportingCharacters: Bool = false
    @State private var renderTask: Task<Void, Never>? = nil

    private var usesLightChrome: Bool {
        backdrop == .light
    }

    private var chromeForeground: Color {
        usesLightChrome ? Color(hex: "#18181B") : .white
    }

    private var chromePillFill: Color {
        usesLightChrome ? Color.black.opacity(0.08) : Color.white.opacity(0.14)
    }

    private var isOnlineMode: Bool {
        onlineManifest != nil && localSend.primaryPCPeer != nil && item.remoteID != nil
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
            backdropView.ignoresSafeArea()

            HStack(spacing: 0) {
                stageCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector && hSizeClass == .regular {
                    inspectorPanel
                        .frame(width: 310)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            VStack {
                topBar
                Spacer()
                bottomDock
            }
        }
        .preferredColorScheme(backdrop == .light ? .light : .dark)
        .wallPullFeedbackOverlay(vault: vault, localSend: localSend, bottomPadding: 84)
        .sheet(isPresented: Binding(
            get: { showInspector && hSizeClass != .regular },
            set: { if !$0 { showInspector = false } }
        )) {
            NavigationView {
                inspectorPanel
                    .navigationTitle("图层拆解清单")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showInspector = false }
                        }
                    }
            }
            .navigationViewStyle(.stack)
        }
        .task(id: item.id) {
            await loadStudioSession()
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
            if let compositedImage {
                ZoomableScrollImageView(
                    image: compositedImage,
                    isZoomed: $isZoomed,
                    fillMode: false
                )
            } else if isRendering {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(usesLightChrome ? .primary : .white)
                    Text("正在解析 2D 角色与背景图层…")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(chromeForeground)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let statusMessage {
                VStack(spacing: 10) {
                    Image(systemName: "square.3.layers.3d.slash")
                        .font(.system(size: 36))
                        .foregroundColor(chromeForeground.opacity(0.7))
                    Text(statusMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(chromeForeground)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(.top, 64)
        .padding(.bottom, 76)
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
                        .foregroundColor(chromeForeground.opacity(0.7))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(chromePillFill, in: Capsule())

            Spacer()

            WallPullSegmentedPill(
                options: StudioLayerBackdrop.allCases,
                selection: $backdrop,
                label: { $0.rawValue },
                height: 34,
                lightOnDarkBackdrop: !usesLightChrome
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
            .buttonStyle(StickerPressButtonStyle())

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showInspector.toggle()
                }
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "list.bullet.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(chromeForeground)
                    .frame(width: 34, height: 34)
                    .background(chromePillFill, in: Circle())
            }
            .buttonStyle(StickerPressButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("图层分组")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Button("恢复默认") {
                    restoreDefaults()
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(vault.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if let manifest = onlineManifest {
                        ForEach(manifest.groups) { group in
                            onlineGroupRow(group: group, manifest: manifest)
                        }
                    } else if let bundle = offlineBundle {
                        ForEach(bundle.groups) { group in
                            offlineGroupRow(group: group)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
        )
        .padding(.top, 60)
        .padding(.trailing, 14)
        .padding(.bottom, 84)
    }

    private func roleBadge(_ role: String) -> (String, Color) {
        switch role {
        case "background": return ("背景", .blue)
        case "character": return ("角色立绘", vault.accentColor)
        case "effect": return ("光效氛围", .orange)
        default: return ("主体图层", .green)
        }
    }

    private func onlineGroupRow(group: StudioGroupDTO, manifest: StudioManifestDTO) -> some View {
        let onCount = group.layerIndices.filter { visibleLayerIndices.contains($0) }.count
        let anyOn = onCount > 0
        let isExpanded = expandedGroups.contains(group.key)
        let badge = roleBadge(group.role)
        let layers = manifest.layers.filter { group.layerIndices.contains($0.index) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if anyOn {
                        group.layerIndices.forEach { visibleLayerIndices.remove($0) }
                    } else {
                        group.layerIndices.forEach { visibleLayerIndices.insert($0) }
                    }
                    triggerRecomposite()
                } label: {
                    Image(systemName: anyOn ? "eye.fill" : "eye.slash")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(anyOn ? vault.accentColor : .secondary)
                        .frame(width: 28, height: 28)
                        .background(WallPullPalette.track(colorScheme), in: Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.system(size: 13.5, weight: .semibold))
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

                Button("独显") {
                    visibleLayerIndices = Set(group.layerIndices)
                    triggerRecomposite()
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(WallPullPalette.track(colorScheme), in: Capsule())
                .buttonStyle(.plain)

                if layers.count > 1 {
                    Button {
                        if isExpanded { expandedGroups.remove(group.key) }
                        else { expandedGroups.insert(group.key) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                    }
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
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(10)
        .background(WallPullPalette.cardSurface(colorScheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
        )
    }

    private func offlineGroupRow(group: OfflineStudioGroupLayer) -> some View {
        let isOn = visibleOfflineKeys.contains(group.key)
        let badge = roleBadge(group.role)
        return HStack(spacing: 8) {
            Button {
                if isOn { visibleOfflineKeys.remove(group.key) }
                else { visibleOfflineKeys.insert(group.key) }
                triggerRecomposite()
            } label: {
                Image(systemName: isOn ? "eye.fill" : "eye.slash")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(isOn ? vault.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .background(WallPullPalette.track(colorScheme), in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(badge.0)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(badge.1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(badge.1.opacity(0.14), in: Capsule())
            }

            Spacer(minLength: 4)

            Button("独显") {
                visibleOfflineKeys = [group.key]
                triggerRecomposite()
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(WallPullPalette.track(colorScheme), in: Capsule())
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(WallPullPalette.cardSurface(colorScheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
        )
    }

    private var bottomDock: some View {
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
                        isTransparent: !includeBackground
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                usesLightChrome ? Color.black.opacity(0.10) : Color.white.opacity(0.14),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .padding(.bottom, 16)
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
                if let img = await localSend.renderStudioFrame(
                    remoteID: rid,
                    visibleLayers: g.layerIndices,
                    maxDimension: 2048,
                    preserveTransparency: true,
                    trimBounds: true,
                    peer: peer
                ) {
                    if await vault.importCutoutImage(img, title: "\(item.title) · \(g.title)", isTransparent: true) != nil {
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
                   await vault.importCutoutImage(img, title: "\(item.title) · \(g.title)", isTransparent: true) != nil {
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

        let existingOffline = vault.loadOfflineStudioBundle(for: item.id)
        if let existingOffline {
            offlineBundle = existingOffline
        }

        if let peer = localSend.primaryPCPeer, let rid = item.remoteID,
           let manifest = await localSend.fetchStudioManifest(remoteID: rid, peer: peer) {
            onlineManifest = manifest
            visibleLayerIndices = Set(manifest.layers.filter(\.defaultVisible).map(\.index))
            if let existingOffline {
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
            let bgOrFx = Set(
                m.groups
                    .filter { $0.role == "background" || $0.role == "effect" }
                    .flatMap(\.layerIndices)
            )
            visibleLayerIndices = Set(
                m.layers
                    .filter { !bgOrFx.contains($0.index) && ($0.defaultVisible || $0.role == "character") }
                    .map(\.index)
            )
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
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 55_000_000)
            guard !Task.isCancelled else { return }

            if let manifest = onlineManifest, let peer = localSend.primaryPCPeer, let rid = item.remoteID {
                let keepBG = includeBackground
                let img = await localSend.renderStudioFrame(
                    remoteID: rid,
                    visibleLayers: Array(visibleLayerIndices),
                    maxDimension: 2048,
                    preserveTransparency: !keepBG,
                    trimBounds: !keepBG && trimBounds,
                    peer: peer
                )
                guard !Task.isCancelled else { return }
                if let img {
                    await MainActor.run {
                        self.compositedImage = img
                        self.isRendering = false
                    }
                    return
                }
                // PC dropped mid-session or render timed out: fall back gracefully to offline bundle if available
                let bundleFallback = offlineBundle ?? vault.loadOfflineStudioBundle(for: item.id)
                if let bundleFallback {
                    let activeGroups = Set(
                        manifest.groups
                            .filter { grp in grp.layerIndices.contains { visibleLayerIndices.contains($0) } }
                            .map(\.key)
                    )
                    let dir = vault.studioItemDir(for: item.id)
                    let offlineImg = await Task.detached(priority: .userInitiated) {
                        LocalVaultStore.compositeOfflineStudioLayers(
                            studioItemDir: dir,
                            bundle: bundleFallback,
                            visibleGroupKeys: activeGroups,
                            trimBounds: !keepBG && trimBounds
                        )
                    }.value
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.onlineManifest = nil
                        self.offlineBundle = bundleFallback
                        self.visibleOfflineKeys = activeGroups
                        if let offlineImg {
                            self.compositedImage = offlineImg
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
                let shouldTrim = !includeBackground && trimBounds
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
                    self.isRendering = false
                }
            }
        }
    }
}
