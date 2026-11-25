import SwiftUI

enum WallPullPalette {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#111117") : Color.white
    }

    static func cardSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#1A1A23") : Color(hex: "#F6F6FA")
    }

    static func elevatedPill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#252533") : Color.white
    }

    static func track(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.12 : 0.085)
    }
}

struct WallPullSegmentedPill<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var height: CGFloat = 34
    var lightOnDarkBackdrop: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pillNS

    private var trackColor: Color {
        if lightOnDarkBackdrop { return Color.white.opacity(0.14) }
        return WallPullPalette.track(colorScheme)
    }

    private var borderColor: Color {
        if lightOnDarkBackdrop { return Color.white.opacity(0.18) }
        return WallPullPalette.hairline(colorScheme)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { opt in
                let isSelected = opt == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        selection = opt
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(label(opt))
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundColor(
                            lightOnDarkBackdrop
                            ? (isSelected ? Color(hex: "#18181B") : Color.white.opacity(0.78))
                            : (isSelected ? Color.primary : Color.secondary)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 13)
                        .frame(height: height - 6)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(lightOnDarkBackdrop ? Color.white : WallPullPalette.elevatedPill(colorScheme))
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "wp_seg_pill", in: pillNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(height: height)
        .background(trackColor, in: Capsule())
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
    }
}

struct WallPullUtilityIsland<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(3)
        .frame(height: 36)
        .background(WallPullPalette.track(colorScheme), in: Capsule())
        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
    }
}

struct WallPullIslandDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }
}

struct WallPullSectionCard<Content: View>: View {
    let title: String
    var icon: String? = nil
    var badge: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                }
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(WallPullPalette.cardSurface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
        )
    }
}

struct WallPullSwitchRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let accentColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 10)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(accentColor)
        }
    }
}

struct WallPullColorSwatchRow: View {
    @Binding var selectedHex: String
    let palette: [String]
    @Environment(\.colorScheme) private var colorScheme
    @State private var hexInput: String = ""

    var body: some View {
        HStack(spacing: 12) {
            ForEach(palette, id: \.self) { hex in
                let active = selectedHex.caseInsensitiveCompare(hex) == .orderedSame
                Button {
                    selectedHex = hex
                    hexInput = hex
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .strokeBorder(WallPullPalette.canvas(colorScheme), lineWidth: 2.5)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(active ? Color(hex: hex) : WallPullPalette.hairline(colorScheme), lineWidth: active ? 2.5 : 1)
                                .scaleEffect(active ? 1.24 : 1.04)
                        )
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 22).padding(.horizontal, 2)

            HStack(spacing: 7) {
                Circle()
                    .fill(Color(hex: selectedHex))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
                TextField("#7C3AED", text: $hexInput)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .frame(width: 78)
                    .onChange(of: hexInput) { raw in
                        if let valid = normalizeHexColor(raw) {
                            selectedHex = valid
                        }
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(WallPullPalette.elevatedPill(colorScheme), in: Capsule())
            .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
        }
        .onAppear { hexInput = selectedHex }
        .onChange(of: selectedHex) { newHex in
            if normalizeHexColor(hexInput) != newHex {
                hexInput = newHex
            }
        }
    }
}

struct WallPullCenteredModal<Content: View>: View {
    var maxWidth: CGFloat = 960
    var maxHeight: CGFloat = 720
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = min(maxWidth, max(320, geo.size.width - 44))
            let h = min(maxHeight, max(360, geo.size.height - 48))
            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.56 : 0.34)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                content()
                    .frame(width: w, height: h)
                    .background(WallPullPalette.canvas(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 34, y: 14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct WallPullToastCapsule: View {
    let toast: ToastBannerState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(toast.isError ? .orange : .green)
            Text(toast.message)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}

struct WallPullTransferProgressCapsule: View {
    let progress: TransferProgressState
    let accentColor: Color
    let canCancel: Bool
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: min(1.0, max(0.03, progress.fraction)))
                .progressViewStyle(.linear)
                .tint(accentColor)
                .frame(width: 90)

            VStack(alignment: .leading, spacing: 1) {
                Text(progress.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if progress.totalFiles > 0 {
                    Text("\(progress.currentFileIndex) / \(progress.totalFiles) · \(Int((progress.fraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if canCancel {
                Button(action: onCancel) {
                    Text("停止")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}

struct FloatingMusicCapsule: View {
    @ObservedObject var musicPlayer: MusicPlayerManager
    @ObservedObject var vault: LocalVaultStore
    @Environment(\.colorScheme) private var colorScheme

    private func fmtClock(_ s: Double) -> String {
        guard s.isFinite && s > 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        if let track = musicPlayer.activeTrack {
            HStack(spacing: 12) {
                Image(systemName: musicPlayer.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(vault.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let itemTitle = musicPlayer.activeItem?.title {
                            Text(itemTitle)
                                .lineLimit(1)
                        }
                        Text("·")
                        Text("\(fmtClock(musicPlayer.currentTime)) / \(fmtClock(musicPlayer.duration))")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: 210, alignment: .leading)

                HStack(spacing: 4) {
                    Button { musicPlayer.prevTrack() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    Button { musicPlayer.togglePlayPause() } label: {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(vault.accentColor, in: Circle())
                    }
                    Button { musicPlayer.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            musicPlayer.stop()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 26, height: 26)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
    }
}

struct WallPullFeedbackOverlayModifier: ViewModifier {
    @ObservedObject var vault: LocalVaultStore
    @ObservedObject var localSend: LocalSendService
    var bottomPadding: CGFloat

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            VStack(spacing: 8) {
                if let progress = localSend.transferProgress {
                    WallPullTransferProgressCapsule(
                        progress: progress,
                        accentColor: vault.accentColor,
                        canCancel: localSend.canCancelTransfer,
                        onCancel: { localSend.cancelActiveTransfer() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let toast = vault.toast {
                    WallPullToastCapsule(toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomPadding)
            .allowsHitTesting(localSend.canCancelTransfer && localSend.transferProgress != nil)
            .zIndex(999)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: vault.toast)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: localSend.transferProgress != nil)
    }
}

extension View {
    func wallPullFeedbackOverlay(
        vault: LocalVaultStore,
        localSend: LocalSendService,
        bottomPadding: CGFloat = 22
    ) -> some View {
        modifier(WallPullFeedbackOverlayModifier(
            vault: vault,
            localSend: localSend,
            bottomPadding: bottomPadding
        ))
    }
}
