import SwiftUI
import UIKit

struct ShadowRoundedPlate: UIViewRepresentable {
    let fillColor: Color
    var cornerRadius: CGFloat = 16
    var shadowOpacity: Float = 0.08
    var shadowRadius: CGFloat = 5
    var shadowOffsetY: CGFloat = 2.5

    final class PlateView: UIView {
        var radius: CGFloat = 16
        private var lastSize: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.cornerCurve = .continuous
            layer.masksToBounds = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize {
                lastSize = bounds.size
                layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
            }
        }
    }

    func makeUIView(context: Context) -> PlateView {
        let v = PlateView()
        apply(to: v)
        return v
    }

    func updateUIView(_ uiView: PlateView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to v: PlateView) {
        v.radius = cornerRadius
        v.backgroundColor = UIColor(fillColor)
        v.layer.cornerRadius = cornerRadius
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = shadowOpacity
        v.layer.shadowRadius = shadowRadius
        v.layer.shadowOffset = CGSize(width: 0, height: shadowOffsetY)
    }
}

struct WallpaperCardView: View, Equatable {
    static func == (lhs: WallpaperCardView, rhs: WallpaperCardView) -> Bool {
        lhs.item == rhs.item
            && lhs.thumbURL == rhs.thumbURL
            && lhs.mediaURL == rhs.mediaURL
            && lhs.previewVideoURL == rhs.previewVideoURL
            && lhs.accentColor == rhs.accentColor
            && lhs.aspectMode == rhs.aspectMode
            && lhs.showCaption == rhs.showCaption
            && lhs.showFileSizeInSubtitle == rhs.showFileSizeInSubtitle
            && lhs.autoPlayVideo == rhs.autoPlayVideo
            && lhs.isGalleryPaused == rhs.isGalleryPaused
            && lhs.thumbRevision == rhs.thumbRevision
            && lhs.isSelecting == rhs.isSelecting
            && lhs.isSelected == rhs.isSelected
            && lhs.isNewlyLanded == rhs.isNewlyLanded
            && lhs.colorScheme == rhs.colorScheme
    }
    let item: VaultItem
    let thumbURL: URL?
    let mediaURL: URL
    let previewVideoURL: URL
    let accentColor: Color
    let aspectMode: CardAspectMode
    let showCaption: Bool
    let showFileSizeInSubtitle: Bool
    let autoPlayVideo: Bool
    let isGalleryPaused: Bool
    let thumbRevision: Int
    let frameTracker: CardFrameTracker
    let isSelecting: Bool
    let isSelected: Bool
    let isNewlyLanded: Bool
    let colorScheme: ColorScheme
    let onSettledLanding: () -> Void
    let onTap: () -> Void
    let onToggleSelectItem: () -> Void
    let onCopyClipboard: () -> Void
    let onSavePhotos: () -> Void
    let onOpenStudio: () -> Void
    let onPlayMusic: () -> Void
    let onSendLocalSend: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var cardRatio: CGFloat {
        switch aspectMode {
        case .widescreen:
            return 16.0 / 10.0
        case .square:
            return 1.0
        case .adaptive:
            return max(0.56, min(2.40, item.aspectRatio))
        }
    }

    private var subtitleLine: String {
        let kind = item.mediaType == .video ? "视频" : "图片"
        if let res = item.resolutionText {
            if showFileSizeInSubtitle {
                return "\(kind) · \(res) · \(formatFileSize(item.fileSize))"
            }
            return "\(kind) · \(res)"
        }
        return "\(kind) · \(formatFileSize(item.fileSize))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTap) {
                    Color.clear
                        .aspectRatio(cardRatio, contentMode: .fit)
                        .overlay(
                            ZStack {
                                if item.isTransparentCutout {
                                    CheckerboardView(squareSize: 12)
                                } else {
                                    WallPullPalette.cardSurface(colorScheme)
                                }

                                RetinaCardImageView(
                                    url: thumbURL ?? mediaURL,
                                    isCutout: item.isTransparentCutout,
                                    revision: thumbRevision,
                                    fallbackSymbol: item.mediaType == .video ? "film" : "photo"
                                )

                                if item.mediaType == .video && autoPlayVideo && !isGalleryPaused {
                                    GalleryInlineVideoView(
                                        id: item.id,
                                        url: previewVideoURL,
                                        fallbackURL: mediaURL,
                                        isActive: !isGalleryPaused
                                    )
                                }

                                cardOverlays
                            }
                        )
                        .clipShape(cardShape)
                        .background(
                            ShadowRoundedPlate(
                                fillColor: WallPullPalette.cardSurface(colorScheme),
                                cornerRadius: 16,
                                shadowOpacity: colorScheme == .dark ? 0.28 : 0.08,
                                shadowRadius: 5,
                                shadowOffsetY: 2.5
                            )
                        )
                        .overlay(
                            Group {
                                if isSelected {
                                    BorderGlowOverlay(
                                        accentColor: accentColor,
                                        cornerRadius: 16,
                                        lineWidth: 3.2
                                    )
                                } else {
                                    cardShape
                                        .strokeBorder(
                                            Color.white.opacity(colorScheme == .dark ? 0.10 : 0.35),
                                            lineWidth: 0.8
                                        )
                                }
                            }
                        )
                        .overlay(
                            cardShape
                                .strokeBorder(
                                    Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                    lineWidth: isSelected ? 0 : 0.5
                                )
                        )
                }
                .buttonStyle(StickerPressButtonStyle())
                .background(CardAnchorView(id: item.id, tracker: frameTracker))
                .overlay(alignment: .topTrailing) {
                    if !isSelecting {
                        PulseHeartButton(isFavorite: item.isFavorite, onToggle: onToggleFavorite)
                            .wallPullMinimumHitArea(28)
                            .padding(9)
                    }
                }
            .contentShape(.contextMenuPreview, cardShape)
            .contextMenu {
                Button(action: onToggleSelectItem) {
                    Label(
                        isSelected ? "取消多选此项" : "加入多选",
                        systemImage: isSelected ? "minus.circle" : "checkmark.circle"
                    )
                }
                Divider()
                if item.mediaType == .image {
                    Button(action: onCopyClipboard) {
                        Label("复制原图（直接贴微信）", systemImage: "doc.on.doc")
                    }
                }
                Button(action: onSavePhotos) {
                    Label("无损存入相册", systemImage: "square.and.arrow.down")
                }
                if item.supportsLayerStudio {
                    Button(action: onOpenStudio) {
                        Label("打开 2D 透视拆图", systemImage: "square.3.layers.3d")
                    }
                }
                if item.hasMusic {
                    Button(action: onPlayMusic) {
                        Label("播放壁纸配乐", systemImage: "music.note")
                    }
                }
                Button(action: onSendLocalSend) {
                    Label("发到其他设备", systemImage: "paperplane")
                }
                Button(action: onToggleFavorite) {
                    Label(item.isFavorite ? "取消收藏" : "加入收藏", systemImage: item.isFavorite ? "heart.slash" : "heart")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("从本地库删除", systemImage: "trash")
                }
            }

            if showCaption {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(item.title)
                            .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(subtitleLine)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(
            NewlyLandedFlipBounceModifier(
                isNewlyLanded: isNewlyLanded,
                accentColor: accentColor,
                onSettled: onSettledLanding
            )
        )
    }

    private var cardOverlays: some View {
        VStack {
            HStack {
                if isSelecting {
                    SpringCheckBadge(checked: isSelected, accentColor: accentColor, size: 25)
                        .padding(9)
                }
                Spacer()
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 6) {
                HStack(spacing: 5) {
                    if item.allMediaFileNames.count > 1 {
                        HStack(spacing: 3) {
                            Image(systemName: "square.stack")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("\(item.allMediaFileNames.count) 张")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                    }
                    if item.supportsLayerStudio {
                        HStack(spacing: 3) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("可拆图层")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accentColor.opacity(0.88), in: Capsule())
                    }
                    if item.hasMusic {
                        HStack(spacing: 3) {
                            Image(systemName: "music.note")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("配乐")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.50), in: Capsule())
                    }
                }
                Spacer(minLength: 4)
                if item.mediaType == .video {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(autoPlayVideo && !isGalleryPaused ? Color.green : Color.white.opacity(0.75))
                            .frame(width: 5.5, height: 5.5)
                        Text(item.durationText ?? "视频")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundColor(.white.opacity(0.96))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.52), in: Capsule())
                }
            }
            .padding(9)
        }
    }
}
