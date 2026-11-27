import Foundation
import SwiftUI
import UIKit

struct VideoFramePreviewSheetView: View {
    let image: UIImage
    let titleText: String
    let timestampSeconds: Double
    let contentRating: String?
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    let onOpenCrop: (UIImage) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var effectiveScheme: ColorScheme {
        vault.appearanceMode.colorScheme ?? colorScheme
    }

    private var pixelSizeText: String {
        let w = Int((image.size.width * image.scale).rounded())
        let h = Int((image.size.height * image.scale).rounded())
        return "\(w) × \(h)"
    }

    private var timestampText: String {
        let safe = max(0.0, timestampSeconds.isFinite ? timestampSeconds : 0.0)
        let whole = Int(floor(safe))
        let tenths = Int(floor((safe - Double(whole)) * 10.0))
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(vault.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleText)
                            .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text("原生高清帧 \(pixelSizeText) · 时间点 \(timestampText)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                ZStack {
                    Color.black.opacity(effectiveScheme == .dark ? 0.45 : 0.08)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button {
                            vault.copyUIImageLosslessToClipboard(
                                image,
                                toastMessage: "已无损复制高清截帧到剪贴板，切去微信直接粘贴"
                            )
                        } label: {
                            Label("复制原图（贴微信）", systemImage: "doc.on.doc.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(vault.accentColor, in: Capsule())
                        }
                        .buttonStyle(StickerPressButtonStyle())

                        Button {
                            onOpenCrop(image)
                        } label: {
                            Label("进入比例裁切", systemImage: "crop")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(WallPullPalette.track(effectiveScheme), in: Capsule())
                        }
                        .buttonStyle(StickerPressButtonStyle())

                        Button {
                            Task { await vault.saveUIImageToPhotos(image) }
                        } label: {
                            Label("存入相册", systemImage: "square.and.arrow.down.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(WallPullPalette.track(effectiveScheme), in: Capsule())
                        }
                        .buttonStyle(StickerPressButtonStyle())

                        Button {
                            Task {
                                _ = await vault.importCutoutImage(
                                    image,
                                    title: "\(titleText) · 截帧",
                                    isTransparent: false,
                                    contentRating: contentRating,
                                    sourceDevice: "视频高清截帧",
                                    toastMessage: "已将视频截帧收入离线壁纸库"
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
                        .buttonStyle(StickerPressButtonStyle())
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 14)
            }
            .background(WallPullPalette.canvas(effectiveScheme).ignoresSafeArea())
            .navigationTitle("视频高清截帧")
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
}
