import SwiftUI

enum LocalSendSheetTab: String, CaseIterable, Identifiable {
    case devices = "跨端连接"
    case catalog = "从电脑挑图"
    var id: String { rawValue }
}

struct LocalSendSheetView: View {
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    let catalogFrameTracker: CardFrameTracker
    let onOpenCatalogPreview: (PCCatalogItem, [PCCatalogItem], LocalSendPeer, CGRect?, UIImage?) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var tab: LocalSendSheetTab = .devices
    @State private var manualIP: String = ""
    @State private var catalogQuery: String = ""
    @State private var selectedCatalogIDs: Set<String> = []
    @State private var showPullAllConfirm: Bool = false
    @State private var pairingPinInput: String = ""
    @State private var isSubmittingPair: Bool = false
    @State private var pairingErrorText: String = ""
    @State private var pairingShakeCount: Int = 0

    private enum CatalogTypeOpt: String, CaseIterable, Identifiable {
        case all = "全部"
        case image = "图片"
        case video = "视频"
        var id: String { rawValue }
        var key: String {
            switch self {
            case .all: return "all"
            case .image: return "image"
            case .video: return "video"
            }
        }
    }

    private enum CatalogRatingOpt: String, CaseIterable, Identifiable {
        case all = "全部分级"
        case everyone = "全年龄"
        case mature = "擦边/18+"
        var id: String { rawValue }

        func matches(_ rawRating: String?) -> Bool {
            let normalized = (rawRating ?? "Everyone").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch self {
            case .all:
                return true
            case .everyone:
                return normalized.isEmpty || normalized == "everyone"
            case .mature:
                return normalized == "questionable" || normalized == "mature"
            }
        }
    }

    @State private var catalogTypeOpt: CatalogTypeOpt = .all
    @State private var catalogRatingOpt: CatalogRatingOpt = .all

    private var filteredCatalog: [PCCatalogItem] {
        let q = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return localSend.pcCatalog.filter { item in
            if catalogTypeOpt != .all && item.mediaType != catalogTypeOpt.key { return false }
            if !catalogRatingOpt.matches(item.contentRating) { return false }
            if !q.isEmpty && !item.title.lowercased().contains(q) { return false }
            return true
        }
    }

    private var unimportedFilteredCatalog: [PCCatalogItem] {
        filteredCatalog.filter { !vault.hasImportedCatalogItem($0) }
    }

    private var unimportedTotalBytes: Int64 {
        unimportedFilteredCatalog.reduce(0) { $0 + max(0, $1.fileSize) }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                sheetHeader

                WallPullSegmentedPill(
                    options: LocalSendSheetTab.allCases,
                    selection: $tab,
                    label: { $0.rawValue },
                    height: 36
                )
                .padding(.bottom, 12)

                if tab == .devices {
                    devicesTab
                } else {
                    pcCatalogTab
                }
            }

            if let targetPeer = localSend.pairingRequiredPeer {
                pairingPromptOverlay(for: targetPeer)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: localSend.pairingRequiredPeer?.fingerprint)
        .onAppear {
            if let pc = localSend.primaryPCPeer, pc.isWallPullPC {
                if tab == .devices && !localSend.pcCatalog.isEmpty {
                    tab = .catalog
                } else if localSend.pcCatalog.isEmpty {
                    Task { await localSend.fetchPCCatalog(from: pc) }
                }
            }
        }
        .onChange(of: tab) { newTab in
            if newTab == .catalog, let pc = localSend.primaryPCPeer, pc.isWallPullPC {
                Task { await localSend.fetchPCCatalog(from: pc) }
            }
        }
        .onChange(of: localSend.pairingRequiredPeer?.fingerprint) { _ in
            pairingPinInput = ""
            pairingErrorText = ""
            isSubmittingPair = false
        }
        .onChange(of: catalogQuery) { _ in
            let validIDs = Set(filteredCatalog.map(\.id))
            selectedCatalogIDs.formIntersection(validIDs)
        }
        .onChange(of: catalogTypeOpt) { _ in
            let validIDs = Set(filteredCatalog.map(\.id))
            selectedCatalogIDs.formIntersection(validIDs)
        }
        .onChange(of: catalogRatingOpt) { _ in
            let validIDs = Set(filteredCatalog.map(\.id))
            selectedCatalogIDs.formIntersection(validIDs)
        }
        .alert("确认一键全部收入", isPresented: $showPullAllConfirm) {
            Button("立即全部收入 (\(unimportedFilteredCatalog.count) 项)") {
                if let pc = localSend.primaryPCPeer {
                    let list = unimportedFilteredCatalog
                    startPullAndReturnToGallery(list, from: pc)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(unimportedFilteredCatalog.count) 项未入库，约 \(formatFileSize(unimportedTotalBytes))。")
        }
    }

    @ViewBuilder
    private func pairingPromptOverlay(for peer: LocalSendPeer) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    if !isSubmittingPair {
                        localSend.pairingRequiredPeer = nil
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("配对「\(peer.alias)」")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Button {
                        localSend.pairingRequiredPeer = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(WallPullPalette.track(colorScheme), in: Circle())
                    }
                    .disabled(isSubmittingPair)
                }

                Text("输入电脑「跨端互联」中显示的 4 位配对码")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                SegmentedPinInputView(
                    pin: $pairingPinInput,
                    isDisabled: isSubmittingPair,
                    shakeTrigger: pairingShakeCount,
                    hasError: !pairingErrorText.isEmpty,
                    accentColor: vault.accentColor,
                    onComplete: { _ in
                        submitPairing(with: peer)
                    }
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

                if !pairingErrorText.isEmpty {
                    Text(pairingErrorText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.red)
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        localSend.pairingRequiredPeer = nil
                    } label: {
                        Text("取消")
                            .font(.system(size: 13.5, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(WallPullPalette.track(colorScheme), in: Capsule())
                    }
                    .disabled(isSubmittingPair)

                    Button {
                        submitPairing(with: peer)
                    } label: {
                        HStack(spacing: 6) {
                            if isSubmittingPair {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text("确认配对")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(pairingPinInput.count == 4 ? vault.accentColor : Color.gray, in: Capsule())
                    }
                    .disabled(isSubmittingPair || pairingPinInput.count != 4)
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(WallPullPalette.cardSurface(colorScheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
        }
    }

    private func submitPairing(with peer: LocalSendPeer) {
        guard !isSubmittingPair, pairingPinInput.count == 4 else { return }
        isSubmittingPair = true
        pairingErrorText = ""
        let pin = pairingPinInput
        Task {
            let (ok, msg) = await localSend.pair(with: peer, pin: pin)
            await MainActor.run {
                isSubmittingPair = false
                if ok {
                    if tab == .catalog {
                        Task { await localSend.fetchPCCatalog(from: peer) }
                    }
                } else {
                    pairingErrorText = msg
                    pairingShakeCount += 1
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func startPullAndReturnToGallery(_ list: [PCCatalogItem], from pc: LocalSendPeer) {
        onClose()
        Task {
            await localSend.pullCatalogItemsToVault(list, from: pc)
        }
    }

    private var sheetHeader: some View {
        HStack {
            Text("跨端互联")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Spacer()
            HStack(spacing: 8) {
                Button {
                    Task { await localSend.scanNetwork() }
                } label: {
                    HStack(spacing: 5) {
                        if localSend.isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        Text("刷新扫描")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(WallPullPalette.track(colorScheme), in: Capsule())
                    .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                }
                .buttonStyle(StickerPressButtonStyle())

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                        .background(WallPullPalette.track(colorScheme), in: Circle())
                }
                .buttonStyle(StickerPressButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var devicesTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                WallPullSectionCard(
                    title: "本机接收服务",
                    icon: "dot.radiowaves.left.and.right",
                    badge: "\(localSend.localIP):\(String(localSend.listeningPort))"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(vault.deviceAlias)
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            HStack(spacing: 6) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("待命中")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                        }
                        Divider()
                        HStack(spacing: 10) {
                            Text("配对码")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(localSend.pairPin)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(vault.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(vault.accentColor.opacity(0.12), in: Capsule())
                            Button {
                                localSend.rotatePairPin()
                            } label: {
                                Text("换码")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(WallPullPalette.track(colorScheme), in: Capsule())
                            }
                            .buttonStyle(StickerPressButtonStyle())
                            Spacer()
                            if !localSend.trustedPeers.isEmpty {
                                Button {
                                    localSend.clearTrustedPeers()
                                } label: {
                                    Text("解除配对 (\(localSend.trustedPeers.count))")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.red)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.10), in: Capsule())
                                }
                                .buttonStyle(StickerPressButtonStyle())
                            }
                        }
                    }
                }

                WallPullSectionCard(
                    title: "同网段在线设备（\(localSend.peers.count)）",
                    icon: "desktopcomputer"
                ) {
                    if localSend.peers.isEmpty {
                        Text("暂未发现电脑端设备，请确认电脑与平板处于同一局域网。")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(localSend.peers) { peer in
                                HStack(spacing: 12) {
                                    Image(systemName: peer.isWallPullPC ? "desktopcomputer" : "arrow.triangle.2.circlepath.circle")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(peer.isWallPullPC ? vault.accentColor : .secondary)
                                        .frame(width: 36, height: 36)
                                        .background(WallPullPalette.elevatedPill(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(peer.alias)
                                                .font(.system(size: 15, weight: .semibold))
                                            Text(peer.isWallPullPC ? "WallPull 电脑" : (peer.deviceModel ?? "WallPull"))
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background((peer.isWallPullPC ? vault.accentColor : Color.secondary).opacity(0.14), in: Capsule())
                                        }
                                        Text("\(peer.scheme.uppercased()) · \(peer.ip):\(String(peer.port))")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if peer.isWallPullPC {
                                        Button {
                                            localSend.selectPeer(peer)
                                            tab = .catalog
                                        } label: {
                                            Text("挑图入库")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 7)
                                                .background(vault.accentColor, in: Capsule())
                                        }
                                        .buttonStyle(StickerPressButtonStyle())
                                    }
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(WallPullPalette.elevatedPill(colorScheme))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
                                )
                            }
                        }
                    }
                }

                WallPullSectionCard(title: "手动输入 IP 直连", icon: "link") {
                    HStack(spacing: 10) {
                        TextField("如 192.168.1.8", text: $manualIP)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
                            )

                        Button {
                            Task {
                                if await localSend.connectManualIP(manualIP) {
                                    manualIP = ""
                                }
                            }
                        } label: {
                            Text("连接")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(WallPullPalette.track(colorScheme), in: Capsule())
                                .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(StickerPressButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func catalogToolbar(for pc: LocalSendPeer) -> some View {
        let searchBox = HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索壁纸名称…", text: $catalogQuery)
                .frame(width: 168)
            if !catalogQuery.isEmpty {
                Button {
                    catalogQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(WallPullPalette.cardSurface(colorScheme), in: Capsule())
        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))

        let typePill = WallPullSegmentedPill(
            options: CatalogTypeOpt.allCases,
            selection: $catalogTypeOpt,
            label: { $0.rawValue },
            height: 34
        )
        .fixedSize(horizontal: true, vertical: false)

        let ratingPill = WallPullSegmentedPill(
            options: CatalogRatingOpt.allCases,
            selection: $catalogRatingOpt,
            label: { $0.rawValue },
            height: 34
        )
        .fixedSize(horizontal: true, vertical: false)

        let pendingList = unimportedFilteredCatalog
        let pendingIDs = Set(pendingList.map(\.id))
        let allPendingSelected = !pendingIDs.isEmpty && pendingIDs.isSubset(of: selectedCatalogIDs)

        let selectAllButton = Button {
            if allPendingSelected {
                selectedCatalogIDs.subtract(pendingIDs)
            } else {
                selectedCatalogIDs.formUnion(pendingIDs)
            }
        } label: {
            Text(allPendingSelected ? "取消全选" : "全选未入库")
                .font(.system(size: 12.5, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(WallPullPalette.track(colorScheme), in: Capsule())
                .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
        }
        .buttonStyle(StickerPressButtonStyle())

        let isBusyPulling = !localSend.activePullIDs.isEmpty
        let pullAllButton = Button {
            if pendingList.count > 30 {
                showPullAllConfirm = true
            } else {
                startPullAndReturnToGallery(pendingList, from: pc)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(
                    isBusyPulling
                        ? "传输中…"
                        : (pendingList.isEmpty
                            ? "已全部入库"
                            : "一键全部收入 (\(pendingList.count) · \(formatFileSize(unimportedTotalBytes)))")
                )
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(pendingList.isEmpty || isBusyPulling ? .secondary : .white)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background((pendingList.isEmpty || isBusyPulling) ? WallPullPalette.track(colorScheme) : vault.accentColor, in: Capsule())
        }
        .disabled(pendingList.isEmpty || isBusyPulling)
        .buttonStyle(StickerPressButtonStyle())

        let refreshButton = Button {
            Task { await localSend.fetchPCCatalog(from: pc) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13.5, weight: .bold))
                .frame(width: 34, height: 34)
                .background(WallPullPalette.track(colorScheme), in: Circle())
        }
        .buttonStyle(StickerPressButtonStyle())

        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    searchBox
                    typePill
                    ratingPill
                    Spacer(minLength: 4)
                    selectAllButton
                    pullAllButton
                    refreshButton
                }
                .padding(.horizontal, 24)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        searchBox
                        typePill
                        Spacer(minLength: 4)
                        refreshButton
                    }
                    HStack(spacing: 8) {
                        ratingPill
                        Spacer(minLength: 4)
                        selectAllButton
                        pullAllButton
                    }
                }
                .padding(.horizontal, 24)
            }
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    searchBox
                    typePill
                    Spacer(minLength: 4)
                    refreshButton
                }
                HStack(spacing: 8) {
                    ratingPill
                    Spacer(minLength: 4)
                    selectAllButton
                    pullAllButton
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var pcCatalogTab: some View {
        Group {
            if let pc = localSend.primaryPCPeer, pc.isWallPullPC {
                VStack(spacing: 12) {
                    catalogToolbar(for: pc)

                    if localSend.isLoadingCatalog && localSend.pcCatalog.isEmpty {
                        Spacer()
                        ProgressView("正在读取电脑端壁纸目录…")
                        Spacer()
                    } else if let errMsg = localSend.catalogErrorMessage, localSend.pcCatalog.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 38))
                                .foregroundColor(.secondary)
                            Text(errMsg)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            Button {
                                Task { await localSend.fetchPCCatalog(from: pc) }
                            } label: {
                                Text("重试")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .background(vault.accentColor, in: Capsule())
                            }
                            .buttonStyle(StickerPressButtonStyle())
                        }
                        .padding(24)
                        Spacer()
                    } else if localSend.pcCatalog.isEmpty && !localSend.isPeerTrusted(pc) {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 38))
                                .foregroundColor(vault.accentColor)
                            Text("需要输入配对码连接「\(pc.alias)」")
                                .font(.headline)
                            Button {
                                localSend.pairingRequiredPeer = pc
                            } label: {
                                Text("输入配对码")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .background(vault.accentColor, in: Capsule())
                            }
                            .buttonStyle(StickerPressButtonStyle())
                        }
                        Spacer()
                    } else if filteredCatalog.isEmpty && !localSend.pcCatalog.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 38))
                                .foregroundColor(.secondary)
                            Text("当前筛选条件下没有匹配的电脑壁纸")
                                .font(.headline)
                            Button {
                                catalogQuery = ""
                                catalogTypeOpt = .all
                                catalogRatingOpt = .all
                            } label: {
                                Text("重置筛选条件")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(vault.accentColor, in: Capsule())
                            }
                            .buttonStyle(StickerPressButtonStyle())
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            let filterSig = "\(catalogTypeOpt.rawValue)|\(catalogRatingOpt.rawValue)|\(catalogQuery)|\(filteredCatalog.count)".hashValue
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 16) {
                                ForEach(filteredCatalog) { item in
                                    let isSel = selectedCatalogIDs.contains(item.id)
                                    let owned = vault.hasImportedCatalogItem(item)
                                    let isPullingThis = localSend.activePullIDs.contains(item.id)
                                    let anyPullActive = !localSend.activePullIDs.isEmpty
                                    let req = localSend.makePCThumbRequest(for: item, peer: pc)
                                    PCCatalogCardCell(
                                        item: item,
                                        thumbCacheKey: "\(pc.ip):\(item.id)",
                                        thumbRequest: req,
                                        thumbSession: localSend.lanURLSession,
                                        filterSignature: filterSig,
                                        isSelected: isSel,
                                        owned: owned,
                                        isPullingThis: isPullingThis,
                                        anyPullActive: anyPullActive,
                                        accentColor: vault.accentColor,
                                        colorScheme: colorScheme,
                                        catalogFrameTracker: catalogFrameTracker,
                                        onToggleSelect: {
                                            if isSel { selectedCatalogIDs.remove(item.id) }
                                            else { selectedCatalogIDs.insert(item.id) }
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        },
                                        onPreview: {
                                            let rect = catalogFrameTracker.rect(for: "cat_\(item.id)")
                                            let cover = localSend.cachedThumbImage(for: item, peer: pc)
                                            onOpenCatalogPreview(item, filteredCatalog, pc, rect, cover)
                                        },
                                        onPullSingle: {
                                            Task { await localSend.pullCatalogItemsToVault([item], from: pc) }
                                        },
                                        onUnauthorized: {
                                            if localSend.pairingRequiredPeer == nil {
                                                localSend.pairingRequiredPeer = pc
                                            }
                                        }
                                    )
                                    .equatable()
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 6)
                            .padding(.bottom, selectedCatalogIDs.isEmpty ? 20 : 88)
                        }

                        if !selectedCatalogIDs.isEmpty {
                            HStack(spacing: 12) {
                                Text("已选 \(selectedCatalogIDs.count) 项")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(vault.accentColor)
                                Spacer()
                                Button {
                                    selectedCatalogIDs.removeAll()
                                } label: {
                                    Text("清空")
                                        .font(.system(size: 13.5, weight: .medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(WallPullPalette.track(colorScheme), in: Capsule())
                                }
                                Button {
                                    let chosen = filteredCatalog.filter { selectedCatalogIDs.contains($0.id) && !vault.hasImportedCatalogItem($0) }
                                    selectedCatalogIDs.removeAll()
                                    startPullAndReturnToGallery(chosen, from: pc)
                                } label: {
                                    Text("批量收入平板 (\(selectedCatalogIDs.count))")
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 7)
                                        .background(vault.accentColor, in: Capsule())
                                }
                                .disabled(!localSend.activePullIDs.isEmpty)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 14)
                        }
                    }
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.system(size: 42))
                        .foregroundColor(.secondary)
                    Text("尚未连接电脑端 WallPull")
                        .font(.headline)
                    Text("请先在「跨端连接」里确认检测到你的 Windows 电脑端，即可直接从电脑挑图或一键全量收入本机离线库。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        tab = .devices
                    } label: {
                        Text("前往设备连接")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(vault.accentColor, in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())
                }
                .padding(32)
                Spacer()
            }
        }
    }
}

private struct PCCatalogCardCell: View, Equatable {
    let item: PCCatalogItem
    let thumbCacheKey: String
    let thumbRequest: URLRequest?
    let thumbSession: URLSession
    let filterSignature: Int
    let isSelected: Bool
    let owned: Bool
    let isPullingThis: Bool
    let anyPullActive: Bool
    let accentColor: Color
    let colorScheme: ColorScheme
    let catalogFrameTracker: CardFrameTracker
    let onToggleSelect: () -> Void
    let onPreview: () -> Void
    let onPullSingle: () -> Void
    let onUnauthorized: () -> Void

    static func == (lhs: PCCatalogCardCell, rhs: PCCatalogCardCell) -> Bool {
        lhs.item == rhs.item
            && lhs.thumbCacheKey == rhs.thumbCacheKey
            && lhs.thumbRequest == rhs.thumbRequest
            && lhs.filterSignature == rhs.filterSignature
            && lhs.isSelected == rhs.isSelected
            && lhs.owned == rhs.owned
            && lhs.isPullingThis == rhs.isPullingThis
            && lhs.anyPullActive == rhs.anyPullActive
            && lhs.accentColor == rhs.accentColor
            && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        let crLower = (item.contentRating ?? "everyone").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay(
                        LANThumbView(
                            cacheKey: thumbCacheKey,
                            request: thumbRequest,
                            session: thumbSession,
                            isVideo: item.isVideo,
                            onUnauthorized: onUnauthorized
                        )
                    )
                    .background(CardAnchorView(id: "cat_\(item.id)", tracker: catalogFrameTracker))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack {
                    HStack(alignment: .top) {
                        Button(action: onToggleSelect) {
                            SpringCheckBadge(checked: isSelected, accentColor: accentColor, size: 22)
                                .wallPullMinimumHitArea(22)
                                .padding(2)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        HStack(spacing: 4) {
                            if item.isPCFavorite {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(5)
                                    .background(Color(hex: "#FF4D6D").opacity(0.92), in: Circle())
                            }
                            if owned {
                                Text("✓ 已入库")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.88), in: Capsule())
                            }
                        }
                    }
                    Spacer()
                    HStack {
                        HStack(spacing: 4) {
                            if (item.assetCount ?? 1) > 1 {
                                Text("\(item.assetCount ?? 1) 张")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Color.black.opacity(0.6), in: Capsule())
                            }
                            if item.supportsStudio {
                                Text("✦ 可拆")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(accentColor.opacity(0.9), in: Capsule())
                            }
                            if crLower == "mature" {
                                Text("18+")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Color(hex: "#EF4444").opacity(0.92), in: Capsule())
                            } else if crLower == "questionable" {
                                Text("擦边")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Color.orange.opacity(0.92), in: Capsule())
                            }
                            if item.hasMusic {
                                Image(systemName: "music.note")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(5)
                                    .background(Color.black.opacity(0.55), in: Circle())
                            }
                        }
                        Spacer()
                        if item.isVideo {
                            Text(item.duration ?? "视频")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.6), in: Capsule())
                        }
                    }
                }
                .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPreview)

            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .frame(height: 17, alignment: .leading)
            HStack {
                Text("\(item.resolution ?? "") · \(formatFileSize(item.fileSize))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: onPullSingle) {
                    Text(owned ? "已存在" : (isPullingThis ? "传输中" : "收入平板"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(owned || isPullingThis ? .secondary : .white)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((owned || isPullingThis) ? WallPullPalette.track(colorScheme) : accentColor, in: Capsule())
                }
                .disabled(owned || isPullingThis || anyPullActive)
                .buttonStyle(StickerPressButtonStyle())
            }
            .frame(height: 24)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WallPullPalette.cardSurface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? accentColor : WallPullPalette.hairline(colorScheme), lineWidth: isSelected ? 2.5 : 1)
        )
    }
}
