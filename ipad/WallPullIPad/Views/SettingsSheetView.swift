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
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("外观风格、画廊预览、跨端互联与离线存储选项都保存在本地。")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
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
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 16) {
                    WallPullSectionCard(title: "外观与画廊") {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("外观模式")
                                    .font(.system(size: 14.5, weight: .semibold))
                                WallPullSegmentedPill(
                                    options: AppearanceMode.allCases,
                                    selection: appearanceSelection,
                                    label: { $0.rawValue },
                                    height: 34
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("画廊卡片比例（选择「原图比例」将按同画幅数量从多到少聚类对齐）")
                                    .font(.system(size: 14.5, weight: .semibold))
                                WallPullSegmentedPill(
                                    options: CardAspectMode.allCases,
                                    selection: cardAspectSelection,
                                    label: { $0.rawValue },
                                    height: 34
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("界面主题色（支持预设或自定义 #RRGGBB 色号）")
                                    .font(.system(size: 14.5, weight: .semibold))
                                WallPullColorSwatchRow(
                                    selectedHex: $vault.accentHex,
                                    palette: AppInfoConstants.themePalette
                                )
                            }

                            Divider()

                            WallPullSwitchRow(
                                title: "画廊卡片自动静音循环播放视频",
                                subtitle: "主界面采用轻量高清预览流实时播放，打开全屏详情或离开画面时自动暂停省电。",
                                isOn: $vault.autoPlayGalleryVideos,
                                accentColor: vault.accentColor
                            )

                            Divider()

                            WallPullSwitchRow(
                                title: "显示壁纸标题与分辨率",
                                subtitle: "在画廊卡片下方展示标题、类型与像素尺寸铭牌。",
                                isOn: $vault.showCardCaptions,
                                accentColor: vault.accentColor
                            )
                        }
                    }

                    WallPullSectionCard(title: "跨端互联", icon: "ipad.and.iphone") {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("本机显示名称")
                                    .font(.system(size: 14.5, weight: .semibold))
                                TextField("WallPull iPad", text: $vault.deviceAlias)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(WallPullPalette.elevatedPill(colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
                                    )
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                let stats = LocalVaultStore.disconnectedBadgeWeight(vault.customDisconnectedLabel)
                                let remBytes = max(0, stats.maxWeight - stats.weight)
                                HStack(spacing: 8) {
                                    Text("未连接时顶栏按钮署名")
                                        .font(.system(size: 14.5, weight: .semibold))
                                    Spacer()
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
                                }

                                HStack(spacing: 8) {
                                    ClampedBadgeTextField(
                                        placeholder: "电脑互联（留空使用默认）",
                                        text: $vault.customDisconnectedLabel
                                    )
                                    .frame(height: 22)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(WallPullPalette.elevatedPill(colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
                                    )

                                    if !vault.customDisconnectedLabel.isEmpty {
                                        Button("恢复默认") {
                                            vault.customDisconnectedLabel = ""
                                        }
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(vault.accentColor)
                                        .padding(.horizontal, 11)
                                        .frame(height: 36)
                                        .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                                        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                                        .buttonStyle(StickerPressButtonStyle())
                                    }
                                }

                                Text("上限英文 10 字符 / 中文 7 字符（当前还可输入 \(remBytes / 7) 英文或 \(remBytes / 10) 汉字）")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            WallPullSwitchRow(
                                title: "收到电脑剪贴板推送时震动提示",
                                subtitle: "配合「推至 iPad 剪贴板」使用，轻震后可直接切去微信粘贴发送。",
                                isOn: $vault.clipboardHapticEnabled,
                                accentColor: vault.accentColor
                            )
                        }
                    }

                    WallPullSectionCard(title: "离线存储与智能体检") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("本机离线壁纸库")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("当前共 \(vault.items.count) 项 · 占用 \(formatFileSize(vault.totalStorageBytes))")
                                    .font(.system(size: 12.5))
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
                        badge: "WallPull iPad v\(AppInfoConstants.version) · \(AppInfoConstants.license)"
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("WallPull iPad · 作者：\(AppInfoConstants.author) · 开源免费的离线壁纸随身库")
                                .font(.system(size: 14, weight: .semibold))
                            Text("PC 负责创意工坊拆包与转码，iPad 专注离线珍藏、配乐电台、2D 透视拆图与微信无损秒发。基于 GNU GPL-3.0 协议永久免费开源，严禁倒卖。")
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)

                            HStack(spacing: 10) {
                                Button {
                                    openURL(AppInfoConstants.repoURL)
                                } label: {
                                    Label("GitHub 链接", systemImage: "chevron.left.forwardslash.chevron.right")
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
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
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
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
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                                    .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                                }
                                .buttonStyle(StickerPressButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
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
            Text("当前本地版本为 v\(AppInfoConstants.version)，GitHub 已发布 \(updatePrompt?.tag ?? "")。可前往 Release 页面获取新版安装包。")
        }
    }
}
