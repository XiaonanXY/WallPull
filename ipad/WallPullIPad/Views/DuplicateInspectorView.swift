import ImageIO
import SwiftUI
import UIKit

struct DuplicateInspectorView: View {
    @ObservedObject var vault: LocalVaultStore
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isScanning: Bool = true
    @State private var report: DuplicateScanReport? = nil
    @State private var selectedDeleteIDs: Set<String> = []
    @State private var expandedCompareGroupID: String? = nil
    @State private var compareCandidateIndex: Int = 0
    @State private var comparePairImages: (keep: UIImage, candidate: UIImage)? = nil

    private var selectedDeleteBytes: Int64 {
        guard let report else { return 0 }
        var total: Int64 = 0
        for grp in report.groups {
            for cand in grp.items where selectedDeleteIDs.contains(cand.id) {
                total += max(0, cand.item.fileSize)
            }
        }
        return total
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(vault.accentColor)
                    .frame(width: 38, height: 38)
                    .background(vault.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("相似与重复壁纸智能体检")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(headerSubtitle)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    Task { await runScan() }
                } label: {
                    HStack(spacing: 5) {
                        if isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        Text("重新体检")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(WallPullPalette.track(colorScheme), in: Capsule())
                    .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                }
                .disabled(isScanning)
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
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            if isScanning {
                Spacer()
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(vault.accentColor)
                    Text("正在扫描相似壁纸…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if let report, report.groups.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 46))
                        .foregroundColor(.green)
                    Text("离线壁纸库非常干净")
                        .font(.title3.weight(.bold))
                    Text("已体检 \(report.scannedCount) 项壁纸，未发现完全重复或低清近似版本。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if let report {
                HStack(spacing: 12) {
                    Text("已自动勾选 \(selectedDeleteIDs.count) 项低规格 / 重复副本 · 预计释放 \(formatFileSize(selectedDeleteBytes))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        let redundant = report.groups.flatMap(\.items).filter { !$0.isRecommendedKeep }.map(\.id)
                        selectedDeleteIDs = Set(redundant)
                    } label: {
                        Text("全选冗余副本")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(WallPullPalette.track(colorScheme), in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button {
                        selectedDeleteIDs.removeAll()
                    } label: {
                        Text("清空勾选")
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(WallPullPalette.track(colorScheme), in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    HoldToConfirmCapsule(
                        title: "按住清理 (\(selectedDeleteIDs.count))",
                        icon: "trash.fill",
                        duration: 0.85,
                        tint: .red,
                        isDisabled: selectedDeleteIDs.isEmpty
                    ) {
                        let targetIDs = selectedDeleteIDs
                        let freed = selectedDeleteBytes
                        vault.deleteItems(ids: targetIDs)
                        selectedDeleteIDs.removeAll()
                        expandedCompareGroupID = nil
                        comparePairImages = nil
                        vault.showToast("已清理 \(targetIDs.count) 项重复壁纸，释放 \(formatFileSize(freed))")
                        Task { await runScan() }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(WallPullPalette.cardSurface(colorScheme))

                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(report.groups.enumerated()), id: \.element.id) { gIdx, group in
                            let imageCandidates = group.items.filter { $0.item.mediaType == .image }
                            let keepCand = imageCandidates.first(where: \.isRecommendedKeep) ?? imageCandidates.first
                            let otherCands = imageCandidates.filter { $0.id != keepCand?.id }
                            let canCompare = keepCand != nil && !otherCands.isEmpty
                            let isComparing = expandedCompareGroupID == group.id && canCompare
                            let safeIdx = otherCands.isEmpty ? 0 : min(compareCandidateIndex, otherCands.count - 1)

                            WallPullSectionCard(
                                title: "相似组 #\(gIdx + 1) · 共 \(group.items.count) 项",
                                icon: "square.on.square",
                                badge: "可释放 \(formatFileSize(group.reclaimableBytes))"
                            ) {
                                if canCompare, let keepCand {
                                    HStack(spacing: 8) {
                                        Button {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                                if isComparing {
                                                    expandedCompareGroupID = nil
                                                    comparePairImages = nil
                                                } else {
                                                    expandedCompareGroupID = group.id
                                                    compareCandidateIndex = 0
                                                    loadCompareImages(keep: keepCand.item, candidate: otherCands[0].item)
                                                }
                                            }
                                        } label: {
                                            Label(isComparing ? "收起对比" : "左右像素对比", systemImage: "square.split.2x1")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(isComparing ? .white : vault.accentColor)
                                                .padding(.horizontal, 11)
                                                .padding(.vertical, 5)
                                                .background(
                                                    isComparing ? vault.accentColor : vault.accentColor.opacity(0.12),
                                                    in: Capsule()
                                                )
                                        }
                                        .buttonStyle(StickerPressButtonStyle())

                                        if isComparing && otherCands.count > 1 {
                                            ScrollView(.horizontal, showsIndicators: false) {
                                                HStack(spacing: 6) {
                                                    ForEach(Array(otherCands.enumerated()), id: \.element.id) { idx, c in
                                                        Button {
                                                            compareCandidateIndex = idx
                                                            loadCompareImages(keep: keepCand.item, candidate: c.item)
                                                        } label: {
                                                            Text(c.item.title)
                                                                .font(.system(size: 11, weight: .medium))
                                                                .lineLimit(1)
                                                                .frame(maxWidth: 120)
                                                                .padding(.horizontal, 9)
                                                                .padding(.vertical, 4)
                                                                .background(
                                                                    idx == safeIdx ? vault.accentColor.opacity(0.16) : WallPullPalette.elevatedPill(colorScheme),
                                                                    in: Capsule()
                                                                )
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                }
                                            }
                                        }
                                        Spacer()
                                    }

                                    if isComparing, let pair = comparePairImages {
                                        let chosenCand = otherCands[safeIdx]
                                        TouchCompareSliderView(
                                            beforeImage: pair.keep,
                                            afterImage: pair.candidate,
                                            beforeLabel: "保留 · \(keepCand.item.resolutionText ?? "")",
                                            afterLabel: "候选 · \(chosenCand.item.resolutionText ?? "")",
                                            accentColor: vault.accentColor
                                        )
                                        .frame(height: 250)
                                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                                    }
                                }

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 230), spacing: 14)], spacing: 14) {
                                    ForEach(group.items) { cand in
                                        let isChecked = selectedDeleteIDs.contains(cand.id)
                                        let thumb = vault.thumbURL(for: cand.item) ?? vault.mediaURL(for: cand.item)
                                        VStack(alignment: .leading, spacing: 7) {
                                            ZStack(alignment: .topLeading) {
                                                Color.clear
                                                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                                                    .overlay(
                                                        RetinaCardImageView(
                                                            url: thumb,
                                                            isCutout: cand.item.isTransparentCutout,
                                                            revision: vault.thumbRevision
                                                        )
                                                    )
                                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                                HStack {
                                                    if cand.isRecommendedKeep {
                                                        Text("最高规格 · 推荐保留")
                                                            .font(.system(size: 10.5, weight: .bold))
                                                            .foregroundColor(.white)
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 3.5)
                                                            .background(Color.green.opacity(0.9), in: Capsule())
                                                    } else {
                                                        SpringCheckBadge(checked: isChecked, accentColor: .red, size: 22)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(7)
                                            }

                                            Text(cand.item.title)
                                                .font(.system(size: 13, weight: .semibold))
                                                .lineLimit(1)

                                            Text("\(cand.item.resolutionText ?? "") · \(formatFileSize(cand.item.fileSize))")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)

                                            Text(cand.reason)
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .foregroundColor(cand.isRecommendedKeep ? .green : .orange)
                                                .lineLimit(1)
                                        }
                                        .padding(9)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(WallPullPalette.elevatedPill(colorScheme))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(
                                                    cand.isRecommendedKeep
                                                    ? Color.green.opacity(0.65)
                                                    : (isChecked ? Color.red : WallPullPalette.hairline(colorScheme)),
                                                    lineWidth: cand.isRecommendedKeep || isChecked ? 2 : 1
                                                )
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            guard !cand.isRecommendedKeep else { return }
                                            if isChecked { selectedDeleteIDs.remove(cand.id) }
                                            else { selectedDeleteIDs.insert(cand.id) }
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task {
            await runScan()
        }
    }

    private var headerSubtitle: String {
        guard let report else {
            return "自动识别重复或低清近似壁纸"
        }
        if report.groups.isEmpty {
            return "已扫描 \(report.scannedCount) 项 · 未检测到重复副本"
        }
        return "已扫描 \(report.scannedCount) 项 · 发现 \(report.groups.count) 组共 \(report.totalRedundantCount) 项冗余副本"
    }

    private func runScan() async {
        isScanning = true
        let res = await vault.scanDuplicates()
        report = res
        let safeExactIDs = res.groups.flatMap(\.items)
            .filter { !$0.isRecommendedKeep && $0.isExactMatch && !$0.item.hasMusic }
            .map(\.id)
        selectedDeleteIDs = Set(safeExactIDs)
        isScanning = false
    }

    private func loadCompareImages(keep: VaultItem, candidate: VaultItem) {
        let keepURL = vault.mediaURL(for: keep)
        let candURL = vault.mediaURL(for: candidate)
        let keepThumb = vault.thumbURL(for: keep)
        let candThumb = vault.thumbURL(for: candidate)
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        func decode(_ primary: URL, _ fallback: URL?) -> UIImage? {
            for u in [primary, fallback].compactMap({ $0 }) {
                if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    return UIImage(cgImage: cg)
                }
                if let ui = UIImage(contentsOfFile: u.path) {
                    return ui
                }
            }
            return nil
        }
        if let kImg = decode(keepURL, keepThumb), let cImg = decode(candURL, candThumb) {
            comparePairImages = (kImg, cImg)
        }
    }
}
