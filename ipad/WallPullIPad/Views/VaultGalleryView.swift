import SwiftUI
import UniformTypeIdentifiers

struct VaultGalleryView: View {
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    @ObservedObject var musicPlayer: MusicPlayerManager

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var showFilterPopover: Bool = false
    @State private var showLocalSendSheet: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var showDuplicateModal: Bool = false
    @State private var showPhotosPicker: Bool = false
    @State private var showFilesImporter: Bool = false
    @State private var selectedItemForDetail: VaultItem? = nil
    @State private var detailOriginRect: CGRect? = nil
    @State private var detailCoverImage: UIImage? = nil
    @State private var isClosingDetail: Bool = false
    @State private var frameTracker = CardFrameTracker()
    @State private var studioItem: VaultItem? = nil
    @State private var isSelecting: Bool = false
    @State private var selectedIDs: Set<String> = []
    @State private var pendingSendItems: [VaultItem]? = nil
    @State private var showPeerActionSheet: Bool = false
    @State private var pinchBaselineColumns: Int? = nil
    @State private var showBatchDeleteConfirm: Bool = false
    @State private var pendingSingleDeleteItem: VaultItem? = nil
    @State private var catalogFrameTracker = CardFrameTracker()
    @State private var catalogPreviewSession: PCCatalogPreviewSession? = nil
    @State private var catalogPreviewOriginRect: CGRect? = nil
    @State private var catalogPreviewCover: UIImage? = nil
    @State private var isClosingCatalogPreview: Bool = false

    private var effectiveScheme: ColorScheme {
        vault.appearanceMode.colorScheme ?? colorScheme
    }

    private var squareMinTileWidth: CGFloat {
        switch vault.columnsCount {
        case 2: return 240
        case 3: return 185
        case 4: return 160
        case 5: return 140
        default: return 122
        }
    }

    private var gridColumns: [GridItem] {
        if vault.cardAspectMode == .square {
            return [GridItem(.adaptive(minimum: squareMinTileWidth, maximum: squareMinTileWidth + 60), spacing: 18, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: vault.columnsCount)
    }

    private var filtered: [VaultItem] {
        vault.filteredItems
    }

    private var isFullscreenModalOpen: Bool {
        selectedItemForDetail != nil || studioItem != nil || catalogPreviewSession != nil
    }

    private var feedbackBottomPadding: CGFloat {
        let hasBatch = isSelecting && !selectedIDs.isEmpty
        if hasBatch && !showLocalSendSheet && !showSettingsSheet { return 86 }
        return 20
    }

    private var selectedTotalBytes: Int64 {
        vault.items
            .filter { selectedIDs.contains($0.id) }
            .reduce(0) { $0 + max(0, $1.fileSize) }
    }

    private var allSelectedAreFavorite: Bool {
        let chosen = vault.items.filter { selectedIDs.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy(\.isFavorite)
    }

    private var cardAspectBinding: Binding<CardAspectMode> {
        Binding(
            get: { vault.cardAspectMode },
            set: { vault.cardAspectMode = $0 }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            WallPullPalette.canvas(colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerToolbar

                if filtered.isEmpty {
                    emptyStateView
                } else {
                    galleryGrid
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            VStack(spacing: 10) {
                if isSelecting && !selectedIDs.isEmpty {
                    batchActionDock
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 18)

            if showLocalSendSheet {
                WallPullCenteredModal(maxWidth: 960, maxHeight: 748, onDismiss: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showLocalSendSheet = false
                    }
                }) {
                    LocalSendSheetView(
                        vault: vault,
                        localSend: localSend,
                        catalogFrameTracker: catalogFrameTracker,
                        onOpenCatalogPreview: { item, list, peer, rect, cover in
                            if item.isVideo && musicPlayer.isPlaying {
                                musicPlayer.pausePlayback()
                            }
                            catalogPreviewOriginRect = rect
                            catalogPreviewCover = cover
                            isClosingCatalogPreview = false
                            catalogPreviewSession = PCCatalogPreviewSession(
                                id: item.id,
                                catalogList: list,
                                peer: peer
                            )
                        },
                        onClose: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showLocalSendSheet = false
                            }
                        }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(40)
            }

            if showSettingsSheet {
                WallPullCenteredModal(maxWidth: 740, maxHeight: 696, hugContentHeight: false, onDismiss: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showSettingsSheet = false
                    }
                }) {
                    SettingsSheetView(
                        vault: vault,
                        localSend: localSend,
                        onClose: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showSettingsSheet = false
                            }
                        },
                        onOpenDuplicates: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showDuplicateModal = true
                            }
                        }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(45)
            }

            if showDuplicateModal {
                WallPullCenteredModal(maxWidth: 920, maxHeight: 720, onDismiss: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showDuplicateModal = false
                    }
                }) {
                    DuplicateInspectorView(vault: vault, onClose: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            showDuplicateModal = false
                        }
                    })
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(48)
            }

        }
        .overlay(
            Group {
                if let detailItem = selectedItemForDetail {
                    DetailFlipModalContainer(
                        originRect: detailOriginRect,
                        coverImage: detailCoverImage,
                        isClosing: isClosingDetail,
                        onDismissAnimationComplete: {
                            selectedItemForDetail = nil
                            isClosingDetail = false
                            detailCoverImage = nil
                        }
                    ) {
                        WallpaperDetailView(
                            vault: vault,
                            localSend: localSend,
                            musicPlayer: musicPlayer,
                            allItems: filtered,
                            currentID: detailItem.id,
                            isClosing: isClosingDetail,
                            onOpenStudio: { targetItem in
                                selectedItemForDetail = nil
                                isClosingDetail = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    studioItem = targetItem
                                }
                            },
                            onCurrentIDChanged: { newID in
                                if let matched = filtered.first(where: { $0.id == newID }) {
                                    let thumb = vault.thumbURL(for: matched) ?? vault.mediaURL(for: matched)
                                    let key = RetinaThumbnailCache.cacheKey(url: thumb, revision: vault.thumbRevision, maxPixelSize: 720)
                                    detailCoverImage = RetinaThumbnailCache.shared.image(forKey: key)
                                    detailOriginRect = frameTracker.rect(for: newID)
                                }
                            },
                            onClose: {
                                isClosingDetail = true
                            }
                        )
                    }
                    .ignoresSafeArea(.all)
                    .zIndex(80)
                }
                if let pcSession = catalogPreviewSession {
                    DetailFlipModalContainer(
                        originRect: catalogPreviewOriginRect,
                        coverImage: catalogPreviewCover,
                        isClosing: isClosingCatalogPreview,
                        onDismissAnimationComplete: {
                            catalogPreviewSession = nil
                            isClosingCatalogPreview = false
                            catalogPreviewCover = nil
                        }
                    ) {
                        PCCatalogPreviewView(
                            vault: vault,
                            localSend: localSend,
                            musicPlayer: musicPlayer,
                            peer: pcSession.peer,
                            catalogList: pcSession.catalogList,
                            currentID: pcSession.id,
                            isClosing: isClosingCatalogPreview,
                            onCurrentIDChanged: { newID in
                                catalogPreviewOriginRect = catalogFrameTracker.rect(for: "cat_\(newID)")
                                if let matched = pcSession.catalogList.first(where: { $0.id == newID }) {
                                    catalogPreviewCover = localSend.cachedThumbImage(for: matched, peer: pcSession.peer)
                                }
                            },
                            onClose: {
                                isClosingCatalogPreview = true
                            }
                        )
                    }
                    .ignoresSafeArea(.all)
                    .zIndex(90)
                }
            }
        )
        .onChange(of: isFullscreenModalOpen) { paused in
            GalleryVideoPreviewCoordinator.shared.setGloballyPaused(paused)
        }
        .onChange(of: localSend.pairingRequiredPeer?.fingerprint) { fp in
            if fp != nil && !showLocalSendSheet {
                if !isFullscreenModalOpen {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showLocalSendSheet = true
                    }
                } else {
                    vault.showToast("电脑端连接需要重新配对，请关闭当前预览后在「跨端互联」完成配对", isError: true)
                }
            }
        }
        .wallPullFeedbackOverlay(
            vault: vault,
            localSend: localSend,
            musicPlayer: musicPlayer,
            bottomPadding: feedbackBottomPadding,
            hideFloatingOverlap: showSettingsSheet || isFullscreenModalOpen || showLocalSendSheet
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isSelecting)
        .preferredColorScheme(vault.appearanceMode.colorScheme)
        .sheet(isPresented: $showPhotosPicker) {
            PhotoLibraryPicker { urls, names in
                Task {
                    var imported = 0
                    for (idx, u) in urls.enumerated() {
                        let name = idx < names.count ? names[idx] : u.lastPathComponent
                        if await vault.importFile(
                            from: u,
                            suggestedFileName: name,
                            sourceDevice: "系统相册",
                            batchIndex: idx,
                            batchTotal: urls.count
                        ) != nil {
                            imported += 1
                        }
                        try? FileManager.default.removeItem(at: u)
                    }
                    if imported > 0 {
                        vault.showToast("已导入 \(imported) 项到离线壁纸库")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilesImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task {
                    var imported = 0
                    for url in urls {
                        let ok = url.startAccessingSecurityScopedResource()
                        defer { if ok { url.stopAccessingSecurityScopedResource() } }
                        if await vault.importFile(from: url, suggestedFileName: url.lastPathComponent, sourceDevice: "文件 App") != nil {
                            imported += 1
                        }
                    }
                    if imported > 0 {
                        vault.showToast("已导入 \(imported) 项到离线壁纸库")
                    }
                }
            }
        }
        .fullScreenCover(item: $studioItem) { item in
            SceneLayerStudioView(
                item: item,
                vault: vault,
                localSend: localSend,
                onClose: { studioItem = nil }
            )
        }
        .confirmationDialog("发送到同网段设备", isPresented: $showPeerActionSheet, titleVisibility: .visible) {
            let targets = pendingSendItems ?? []
            ForEach(localSend.peers) { peer in
                Button("发送原文件到「\(peer.alias)」(\(peer.ip))") {
                    Task { await localSend.sendVaultItems(targets, to: peer, targetMode: "vault") }
                }
                if targets.count == 1 && targets.first?.mediaType == .image {
                    Button("推至「\(peer.alias)」剪贴板") {
                        Task { await localSend.sendVaultItems(targets, to: peer, targetMode: "clipboard") }
                    }
                }
            }
            if localSend.peers.isEmpty {
                Button("刷新扫描局域网设备") {
                    Task { await localSend.scanNetwork() }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("确认删除所选壁纸", isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除 (\(selectedIDs.count) 项)", role: .destructive) {
                vault.deleteItems(ids: selectedIDs)
                selectedIDs.removeAll()
                isSelecting = false
            }
        } message: {
            Text("确定从 iPad 本地离线库中移除选中的 \(selectedIDs.count) 项壁纸吗？该操作无法撤销（不会影响电脑原库）。")
        }
        .alert("确认删除此壁纸？", isPresented: Binding(
            get: { pendingSingleDeleteItem != nil },
            set: { if !$0 { pendingSingleDeleteItem = nil } }
        ), presenting: pendingSingleDeleteItem) { target in
            Button("取消", role: .cancel) {
                pendingSingleDeleteItem = nil
            }
            Button("确认删除", role: .destructive) {
                selectedIDs.remove(target.id)
                vault.deleteItems(ids: [target.id])
                pendingSingleDeleteItem = nil
            }
        } message: { target in
            Text("将从 iPad 本地离线库中移除「\(target.title)」，该操作无法撤销。")
        }
    }

    private func openItemWithFlip(_ item: VaultItem) {
        if item.mediaType == .video && musicPlayer.isPlaying {
            musicPlayer.pausePlayback()
        }
        let thumb = vault.thumbURL(for: item) ?? vault.mediaURL(for: item)
        let key = RetinaThumbnailCache.cacheKey(url: thumb, revision: vault.thumbRevision, maxPixelSize: 720)
        detailCoverImage = RetinaThumbnailCache.shared.image(forKey: key)
        detailOriginRect = frameTracker.rect(for: item.id)
        isClosingDetail = false
        selectedItemForDetail = item
    }

    private var headerToolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    ShinyTextTitle(text: "WallPull")
                    RollingCounterText(value: (vault.activeFilterCount > 0 || vault.categoryFilter != .all) ? filtered.count : vault.items.count)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(WallPullPalette.track(colorScheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                }

                if hSizeClass == .regular {
                    categoryPicker
                }

                Spacer(minLength: 4)

                WallPullUtilityIsland {
                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("从系统相册导入", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFilesImporter = true
                        } label: {
                            Label("从「文件」导入", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 30, height: 30)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: Circle())
                    }

                    if vault.hasAnyMusic {
                        Button {
                            if musicPlayer.activeTrack != nil {
                                musicPlayer.togglePlayPause()
                            } else {
                                let pool = filtered.contains(where: \.hasMusic)
                                    ? filtered
                                    : (vault.categoryFilter == .all ? vault.items : filtered)
                                musicPlayer.playAllAvailable(from: pool, vault: vault)
                            }
                        } label: {
                            Image(systemName: musicPlayer.isPlaying ? "waveform" : "music.note")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(musicPlayer.activeTrack != nil ? .white : .primary)
                                .frame(width: 30, height: 30)
                                .background(
                                    musicPlayer.activeTrack != nil
                                    ? vault.accentColor
                                    : WallPullPalette.elevatedPill(colorScheme),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(StickerPressButtonStyle())
                    }

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            showDuplicateModal = true
                        }
                    } label: {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 30, height: 30)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: Circle())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button {
                        showFilterPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showFilterPopover || vault.activeFilterCount > 0
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 14.5, weight: .semibold))
                            if vault.activeFilterCount > 0 {
                                Text("\(vault.activeFilterCount)")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            }
                        }
                        .foregroundColor(showFilterPopover || vault.activeFilterCount > 0 ? vault.accentColor : .primary)
                        .padding(.horizontal, vault.activeFilterCount > 0 ? 8 : 0)
                        .frame(minWidth: 30)
                        .frame(height: 30)
                        .background(
                            (showFilterPopover || vault.activeFilterCount > 0)
                            ? vault.accentColor.opacity(0.14)
                            : WallPullPalette.elevatedPill(colorScheme),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(StickerPressButtonStyle())
                    .popover(isPresented: $showFilterPopover, arrowEdge: .top) {
                        filterPopoverContent
                            .preferredColorScheme(vault.appearanceMode.colorScheme)
                    }

                    Button {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs.removeAll() }
                    } label: {
                        Text(isSelecting ? "完成" : "选择")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isSelecting ? .white : .primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(isSelecting ? vault.accentColor : WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    WallPullIslandDivider()

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            showLocalSendSheet = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(localSend.primaryPCPeer == nil ? Color.orange : Color.green)
                                .frame(width: 7, height: 7)
                            Text(localSend.primaryPCPeer?.alias ?? vault.effectiveDisconnectedLabel)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            showSettingsSheet = true
                        }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 30, height: 30)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: Circle())
                    }
                    .buttonStyle(StickerPressButtonStyle())
                }
            }

            if hSizeClass != .regular {
                ScrollView(.horizontal, showsIndicators: false) {
                    categoryPicker
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var categoryPicker: some View {
        WallPullSegmentedPill(
            options: VaultCategoryFilter.allCases,
            selection: $vault.categoryFilter,
            label: { $0.rawValue },
            height: 36
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    // Windows-parity structured Filter & Sort Popover (A1-A4)
    private var filterPopoverContent: some View {
        let colorCounts = vault.colorBucketCounts()
        let scheme = effectiveScheme
        let primaryText = scheme == .dark ? Color.white : Color(hex: "#18181B")
        let secondaryText = scheme == .dark ? Color.white.opacity(0.62) : Color(hex: "#71717A")

        let contentBody = VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("筛选与排序")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(primaryText)
                Spacer()
                if vault.activeFilterCount > 0 {
                    Button {
                        vault.resetAllFilters()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label("重置全部筛选", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(vault.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(secondaryText)
                TextField("搜索壁纸名称或文件名…", text: $vault.searchText)
                    .foregroundColor(primaryText)
                if !vault.searchText.isEmpty {
                    Button { vault.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(secondaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(WallPullPalette.cardSurface(scheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(WallPullPalette.hairline(scheme), lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                Text("排序方式")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(secondaryText)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(VaultSortMode.allCases) { mode in
                        filterChip(title: mode.rawValue, active: vault.sortMode == mode) {
                            vault.sortMode = mode
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("内容年龄分级")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(secondaryText)
                HStack(spacing: 7) {
                    ForEach(ContentRatingFilter.allCases) { opt in
                        filterChip(title: opt.rawValue, active: vault.ratingFilter == opt) {
                            vault.ratingFilter = opt
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("规格与特性筛选")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(secondaryText)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(SpecFilter.allCases) { spec in
                        filterChip(title: spec.rawValue, active: vault.specFilter == spec) {
                            vault.specFilter = spec
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("主色调色板")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(secondaryText)
                    Spacer()
                    if let activeColor = vault.colorFilter {
                        Text("\(activeColor.label) · \(colorCounts[activeColor] ?? 0) 项")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(vault.accentColor)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(ColorBucketKind.allCases) { bucket in
                        let count = colorCounts[bucket] ?? 0
                        let active = vault.colorFilter == bucket
                        Button {
                            vault.colorFilter = active ? nil : bucket
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(bucket.swatchColor)
                                    .frame(width: 13, height: 13)
                                    .overlay(Circle().strokeBorder(primaryText.opacity(0.22), lineWidth: 0.8))
                                Text(bucket.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(primaryText)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(secondaryText)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 31)
                            .background(
                                active ? vault.accentColor.opacity(0.16) : WallPullPalette.cardSurface(scheme),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(active ? vault.accentColor : WallPullPalette.hairline(scheme), lineWidth: active ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("卡片画幅与网格列数")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(secondaryText)
                WallPullSegmentedPill(
                    options: CardAspectMode.allCases,
                    selection: cardAspectBinding,
                    label: { $0.rawValue },
                    height: 32
                )

                HStack(spacing: 8) {
                    Text(vault.cardAspectMode == .square ? "方块密度" : "每行显示列数")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(primaryText)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(2...6, id: \.self) { cols in
                            let active = vault.columnsCount == cols
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    vault.columnsCount = cols
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Text(vault.cardAspectMode == .square ? "\(cols - 1)档" : "\(cols)列")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(active ? .white : primaryText)
                                    .padding(.horizontal, 9)
                                    .frame(height: 28)
                                    .background(
                                        active ? vault.accentColor : WallPullPalette.cardSurface(scheme),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(
                                            active ? vault.accentColor : WallPullPalette.hairline(scheme),
                                            lineWidth: 1
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)

        return Group {
            if #available(iOS 16.0, *) {
                ViewThatFits(in: .vertical) {
                    contentBody
                    ScrollView(.vertical, showsIndicators: true) {
                        contentBody
                    }
                    .frame(maxHeight: 620)
                }
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    contentBody
                }
                .frame(maxHeight: 620)
            }
        }
        .frame(width: 420)
        .background(WallPullPalette.canvas(scheme))
    }

    private func filterChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        let scheme = effectiveScheme
        let primaryText = scheme == .dark ? Color.white : Color(hex: "#18181B")
        return Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(active ? .white : primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(active ? vault.accentColor : WallPullPalette.cardSurface(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? vault.accentColor : WallPullPalette.hairline(scheme), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func galleryCardCell(for item: VaultItem) -> some View {
        WallpaperCardView(
            item: item,
            thumbURL: vault.thumbURL(for: item),
            mediaURL: vault.mediaURL(for: item),
            previewVideoURL: vault.galleryPreviewVideoURL(for: item),
            accentColor: vault.accentColor,
            aspectMode: vault.cardAspectMode,
            showCaption: vault.showCardCaptions,
            showFileSizeInSubtitle: vault.sortMode == .size,
            autoPlayVideo: vault.autoPlayGalleryVideos,
            isGalleryPaused: isFullscreenModalOpen,
            thumbRevision: vault.thumbRevision,
            frameTracker: frameTracker,
            isSelecting: isSelecting,
            isSelected: selectedIDs.contains(item.id),
            isNewlyLanded: vault.newlyLandedIDs.contains(item.id),
            colorScheme: colorScheme,
            onSettledLanding: { vault.markLandedCompleted(item.id) },
            onTap: {
                if isSelecting {
                    if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                    else { selectedIDs.insert(item.id) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    openItemWithFlip(item)
                }
            },
            onToggleSelectItem: {
                if !isSelecting { isSelecting = true }
                if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                else { selectedIDs.insert(item.id) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            },
            onCopyClipboard: { vault.copyLosslessToClipboard(item: item) },
            onSavePhotos: { Task { await vault.saveToPhotos(items: [item]) } },
            onOpenStudio: { studioItem = item },
            onPlayMusic: { musicPlayer.play(item: item, trackIndex: 0, pool: filtered, vault: vault) },
            onSendLocalSend: {
                pendingSendItems = [item]
                if localSend.peers.isEmpty {
                    Task { await localSend.scanNetwork() }
                }
                showPeerActionSheet = true
            },
            onToggleFavorite: { vault.toggleFavorite(item) },
            onDelete: {
                pendingSingleDeleteItem = item
            }
        )
        .equatable()
    }

    private var galleryGrid: some View {
        let gap: CGFloat = 18
        let bottomPad: CGFloat = (musicPlayer.activeTrack != nil && isSelecting && !selectedIDs.isEmpty) ? 162 : ((isSelecting || musicPlayer.activeTrack != nil) ? 102 : 34)
        return ZStack(alignment: .top) {
            ScrollView {
                Group {
                    if vault.cardAspectMode == .adaptive {
                        let cols = vault.cachedWaterfallColumns
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(Array(cols.enumerated()), id: \.offset) { _, colItems in
                                LazyVStack(spacing: gap) {
                                    ForEach(colItems) { item in
                                        galleryCardCell(for: item)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: gap) {
                            ForEach(filtered) { item in
                                galleryCardCell(for: item)
                            }
                        }
                    }
                }
                .padding(.horizontal, gap)
                .padding(.top, 10)
                .padding(.bottom, bottomPad)
            }
            .simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0.08)
                    .onChanged { mag in
                        if pinchBaselineColumns == nil {
                            pinchBaselineColumns = vault.columnsCount
                        }
                        guard let base = pinchBaselineColumns else { return }
                        let next: Int
                        if mag > 1.24 {
                            next = max(2, base - 1)
                        } else if mag < 0.78 {
                            next = min(6, base + 1)
                        } else {
                            next = base
                        }
                        if next != vault.columnsCount {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                vault.columnsCount = next
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        pinchBaselineColumns = nil
                    }
            )

            LinearGradient(
                colors: [WallPullPalette.canvas(colorScheme), WallPullPalette.canvas(colorScheme).opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 14)
            .allowsHitTesting(false)
        }
    }

    private var batchActionDock: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                RollingCounterText(value: selectedIDs.count, prefix: "已选 ", suffix: " 项")
                Text("· \(formatFileSize(selectedTotalBytes))")
            }
            .font(.system(size: 13.5, weight: .bold))
            .foregroundColor(vault.accentColor)
            .fixedSize(horizontal: true, vertical: false)

            Divider().frame(height: 18)

            let filteredIDs = Set(filtered.map { $0.id })
            let allFilteredSelected = !filteredIDs.isEmpty && filteredIDs.isSubset(of: selectedIDs)
            Button {
                if allFilteredSelected { selectedIDs.subtract(filteredIDs) }
                else { selectedIDs.formUnion(filteredIDs) }
            } label: {
                Text(allFilteredSelected ? "全不选" : "全选")
                    .font(.system(size: 13.5, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                vault.setFavorite(ids: selectedIDs, favorite: !allSelectedAreFavorite)
            } label: {
                Label(allSelectedAreFavorite ? "取消喜欢" : "批量喜欢", systemImage: allSelectedAreFavorite ? "heart.slash" : "heart.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#FF4D6D"))
                    .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                let chosen = vault.items.filter { selectedIDs.contains($0.id) }
                Task { await vault.saveToPhotos(items: chosen) }
            } label: {
                Label("存入相册", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13.5, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                let chosen = vault.items.filter { selectedIDs.contains($0.id) }
                pendingSendItems = chosen
                if localSend.peers.isEmpty {
                    Task { await localSend.scanNetwork() }
                }
                showPeerActionSheet = true
            } label: {
                Label("发到设备", systemImage: "paperplane")
                    .font(.system(size: 13.5, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }

            HoldToConfirmCapsule(
                title: "按住删除",
                icon: "trash.fill",
                duration: 0.85,
                tint: .red
            ) {
                vault.deleteItems(ids: selectedIDs)
                selectedIDs.removeAll()
                isSelecting = false
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }

    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: vault.items.isEmpty ? "tray.and.arrow.down.fill" : "sparkle.magnifyingglass")
                .font(.system(size: 46))
                .foregroundColor(vault.accentColor)
            Text(vault.items.isEmpty ? "你的 iPad 离线壁纸库还是空的" : "没有符合当前筛选的壁纸")
                .font(.title3.weight(.bold))
            Text(vault.items.isEmpty
                 ? "这里只保存你真正收进平板的原画、动态视频与背景音乐——断掉电脑照样离线秒开。现在就可以从已连接的电脑端一键挑图入库，或在电脑端右键「发到平板」。"
                 : "换个分类、清空搜索词或重置全部筛选试试。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 12) {
                if vault.activeFilterCount > 0 {
                    Button {
                        vault.resetAllFilters()
                    } label: {
                        Label("重置全部筛选", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vault.accentColor)
                } else {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            showLocalSendSheet = true
                        }
                    } label: {
                        Label(
                            localSend.primaryPCPeer.map { "从「\($0.alias)」挑壁纸入库" } ?? "连接电脑 / 跨端传输",
                            systemImage: "desktopcomputer"
                        )
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vault.accentColor)

                    Button {
                        showPhotosPicker = true
                    } label: {
                        Label("从相册导入", systemImage: "photo.on.rectangle")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(32)
    }
}

