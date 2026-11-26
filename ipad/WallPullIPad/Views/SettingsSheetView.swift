import SwiftUI
import UIKit

struct SettingsSheetView: View {
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    let onClose: () -> Void
    let onOpenDuplicates: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var isCheckingUpdate: Bool = false
    @State private var updatePrompt: (tag: String, url: URL)? = nil

    private var appearanceSelection: Binding<AppearanceMode> {
        Binding(
            get: { vault.appearanceMode },
            set: { vault.appearanceMode = $0 }
        )
    }

    private var cardAspectSelection: Binding<CardAspectMode> {
        Binding(
            get: { vault.cardAspectMode },
            set: { vault.cardAspectMode = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
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
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                sectionsBody
            }
        }
        .alert("发现新版本 \(updatePrompt?.tag ?? "")", isPresented: Binding(
            get: { updatePrompt != nil },
            set: { if !$0 { updatePrompt = nil } }
        )) {
            Button("前往 GitHub 下载") {
                if let url = updatePrompt?.url {
                    openURL(url)
                }
                updatePrompt = nil
            }
            Button("暂不更新", role: .cancel) {
                updatePrompt = nil
            }
        } message: {
            Text("当前版本 v\(AppInfoConstants.version)，最新版本 \(updatePrompt?.tag ?? "")。")
        }
    }

    private var sectionsBody: some View {
        VStack(spacing: 8) {
            WallPullSectionCard(title: "外观与画廊", contentPadding: 12, contentSpacing: 8) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 12) {
                        Text("外观模式")
                            .font(.system(size: 14.5, weight: .semibold))
                        Spacer()
                        WallPullSegmentedPill(
                            options: AppearanceMode.allCases,
                            selection: appearanceSelection,
                            label: { $0.rawValue },
                            height: 32
                        )
                    }

                    HStack(spacing: 12) {
                        Text("画廊卡片比例")
                            .font(.system(size: 14.5, weight: .semibold))
                        Spacer()
                        WallPullSegmentedPill(
                            options: CardAspectMode.allCases,
                            selection: cardAspectSelection,
                            label: { $0.rawValue },
                            height: 32
                        )
                    }

                    HStack(spacing: 12) {
                        Text("界面主题色")
                            .font(.system(size: 14.5, weight: .semibold))
                        Spacer()
                        WallPullColorSwatchRow(
                            selectedHex: $vault.accentHex,
                            palette: AppInfoConstants.themePalette
                        )
                    }

                    Divider()

                    WallPullSwitchRow(
                        title: "画廊卡片自动静音循环播放视频",
                        isOn: $vault.autoPlayGalleryVideos,
                        accentColor: vault.accentColor
                    )

                    Divider()

                    WallPullSwitchRow(
                        title: "显示壁纸标题与分辨率",
                        isOn: $vault.showCardCaptions,
                        accentColor: vault.accentColor
                    )
                }
            }

            WallPullSectionCard(title: "跨端互联", icon: "ipad.and.iphone", contentPadding: 12, contentSpacing: 8) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 12) {
                        Text("本机显示名称")
                            .font(.system(size: 14.5, weight: .semibold))
                        Spacer()
                        TextField("WallPull iPad", text: $vault.deviceAlias)
                            .submitLabel(.done)
                            .frame(width: 240)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
                            )
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Text("未连接时顶栏按钮署名")
                            .font(.system(size: 14.5, weight: .semibold))
                        HStack(spacing: 5) {
                            Circle().fill(Color.orange).frame(width: 6.5, height: 6.5)
                            Text(vault.effectiveDisconnectedLabel)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))

                        Spacer()

                        ClampedBadgeTextField(
                            placeholder: "电脑互联",
                            text: $vault.customDisconnectedLabel
                        )
                        .frame(width: 180, height: 22)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(WallPullPalette.elevatedPill(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
                        )

                        if !vault.customDisconnectedLabel.isEmpty {
                            Button("恢复默认") {
                                vault.customDisconnectedLabel = ""
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(vault.accentColor)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                            .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                            .buttonStyle(StickerPressButtonStyle())
                        }
                    }

                    Divider()

                    WallPullSwitchRow(
                        title: "收到电脑剪贴板推送时震动提示",
                        isOn: $vault.clipboardHapticEnabled,
                        accentColor: vault.accentColor
                    )
                }
            }

            WallPullSectionCard(title: "离线存储与智能体检", contentPadding: 12, contentSpacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本机离线壁纸库")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("共 \(vault.items.count) 项 · \(formatFileSize(vault.totalStorageBytes))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        onClose()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            onOpenDuplicates()
                        }
                    } label: {
                        Label("查重体检", systemImage: "sparkles.rectangle.stack")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                            .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button {
                        vault.clearThumbCache()
                    } label: {
                        Text("重建缩略图")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                            .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                    }
                    .buttonStyle(StickerPressButtonStyle())
                }
            }

            WallPullSectionCard(
                title: "关于与反馈",
                icon: "info.circle",
                badge: "WallPull iPad v\(AppInfoConstants.version) · \(AppInfoConstants.license)",
                contentPadding: 12,
                contentSpacing: 8
            ) {
                HStack(spacing: 10) {
                    Text("作者：\(AppInfoConstants.author)")
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer()
                    Button {
                        openURL(AppInfoConstants.repoURL)
                    } label: {
                        Label("GitHub 链接", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                            .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button {
                        UIPasteboard.general.string = AppInfoConstants.feedbackGroupNumber
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        vault.showToast("已复制交流群号：\(AppInfoConstants.feedbackGroupNumber)")
                        openURL(AppInfoConstants.feedbackURL)
                    } label: {
                        Label("交流反馈", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 7)
                            .background(vault.accentColor, in: Capsule())
                    }
                    .buttonStyle(StickerPressButtonStyle())

                    Button {
                        guard !isCheckingUpdate else { return }
                        isCheckingUpdate = true
                        Task {
                            let res = await vault.checkForAppUpdate()
                            isCheckingUpdate = false
                            if let err = res.errorMessage {
                                vault.showToast(err, isError: true)
                            } else if res.hasUpdate {
                                updatePrompt = (res.latestTag, res.releaseURL)
                            } else {
                                vault.showToast("当前已是最新版本 (v\(AppInfoConstants.version))")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isCheckingUpdate {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(isCheckingUpdate ? "检查中…" : "检查更新")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                    }
                    .buttonStyle(StickerPressButtonStyle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}
