import SwiftUI
import UIKit

// MARK: - 1. astryx 触控热区 & 系统降透明玻璃材质自适应
extension View {
    func wallPullMinimumHitArea(_ side: CGFloat = 28) -> some View {
        let inset = max(0, (44.0 - side) / 2.0)
        return self
            .padding(inset)
            .contentShape(Rectangle())
            .padding(-inset)
    }

    @ViewBuilder
    func wallPullNumericContentTransition() -> some View {
        if #available(iOS 16.0, *) {
            self.contentTransition(.numericText())
        } else {
            self
        }
    }
}

struct WallPullFloatingSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(WallPullPalette.elevatedPill(colorScheme), in: shape)
                .overlay(shape.strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(WallPullPalette.hairline(colorScheme), lineWidth: 1))
        }
    }
}

extension View {
    func wallPullFloatingSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(WallPullFloatingSurfaceModifier(shape: shape))
    }
}

// MARK: - 2. 4 格独立配对码输入 + 滑动焦点框 + 输错抖动 (OtpInput)
private struct HorizontalShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let xOffset = sin(animatableData * .pi * 4) * 7.0
        return ProjectionTransform(CGAffineTransform(translationX: xOffset, y: 0))
    }
}

struct SegmentedPinInputView: View {
    @Binding var pin: String
    var length: Int = 4
    var isDisabled: Bool = false
    var shakeTrigger: Int = 0
    var hasError: Bool = false
    var accentColor: Color
    var onComplete: ((String) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @Namespace private var slotNS

    private var activeIndex: Int {
        min(length - 1, pin.count)
    }

    var body: some View {
        ZStack {
            TextField("", text: Binding(
                get: { pin },
                set: { raw in
                    let digits = String(raw.filter(\.isNumber).prefix(length))
                    if digits != pin {
                        pin = digits
                        if digits.count == length {
                            onComplete?(digits)
                        }
                    }
                }
            ))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($isFocused)
            .disabled(isDisabled)
            .frame(width: 1, height: 1)
            .opacity(0.015)

            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { idx in
                    let ch = idx < pin.count ? String(pin[pin.index(pin.startIndex, offsetBy: idx)]) : ""
                    let isSlotActive = isFocused && activeIndex == idx && pin.count < length
                    let isFilled = !ch.isEmpty
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(hasError ? Color.red.opacity(0.09) : WallPullPalette.elevatedPill(colorScheme))

                        if isSlotActive {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(accentColor, lineWidth: 2.2)
                                .matchedGeometryEffect(id: "wp_pin_focus", in: slotNS)
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    hasError ? Color.red.opacity(0.75)
                                    : (isFilled ? accentColor.opacity(0.5) : WallPullPalette.hairline(colorScheme)),
                                    lineWidth: isFilled || hasError ? 1.5 : 1
                                )
                        }

                        if !ch.isEmpty {
                            Text(ch)
                                .font(.system(size: 25, weight: .bold, design: .monospaced))
                                .foregroundColor(.primary)
                                .wallPullNumericContentTransition()
                                .transition(.scale(scale: 0.78).combined(with: .opacity))
                        } else {
                            Circle()
                                .fill(Color.secondary.opacity(0.28))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 54, height: 60)
                    .animation(.spring(response: 0.24, dampingFraction: 0.8), value: pin)
                    .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isSlotActive)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isDisabled {
                    isFocused = true
                }
            }
        }
        .modifier(HorizontalShakeEffect(animatableData: CGFloat(shakeTrigger)))
        .animation(.easeOut(duration: 0.34), value: shakeTrigger)
        .onAppear {
            if !isDisabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isFocused = true
                }
            }
        }
    }
}

// MARK: - 3. 触控级前后像素对比滑块 (ImageCompare)
struct TouchCompareSliderView: View {
    let beforeImage: UIImage
    let afterImage: UIImage
    var beforeLabel: String = "保留最优"
    var afterLabel: String = "候选副本"
    var accentColor: Color
    var showsDarkBackdrop: Bool = true

    @State private var fraction: CGFloat = 0.5
    @State private var isDragging: Bool = false
    @State private var crossedHalfOnce: Bool = false

    private func rubberOffset(raw: CGFloat, limit: CGFloat = 0.03) -> CGFloat {
        if raw < 0 {
            let d = -raw
            return -limit * (1 - 1 / (d * 20 + 1))
        }
        if raw > 1 {
            let d = raw - 1
            return 1 + limit * (1 - 1 / (d * 20 + 1))
        }
        return raw
    }

    var body: some View {
        GeometryReader { geo in
            let maxW = max(1, geo.size.width)
            let maxH = max(1, geo.size.height)
            let imgRatio = max(0.05, beforeImage.size.width / max(1, beforeImage.size.height))
            let boxRatio = maxW / maxH
            let fitW = boxRatio > imgRatio ? (maxH * imgRatio) : maxW
            let fitH = boxRatio > imgRatio ? maxH : (maxW / imgRatio)
            let clamped = max(0, min(1, fraction))
            let splitX = fitW * clamped
            let beforeAlpha = max(0, min(1, (splitX - 90) / 28))
            let afterAlpha = max(0, min(1, (fitW - 90 - splitX) / 28))

            ZStack {
                if showsDarkBackdrop {
                    Color.black.opacity(0.88)
                } else {
                    Color.clear
                }

                Image(uiImage: afterImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitW, height: fitH)

                Image(uiImage: beforeImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitW, height: fitH)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle().frame(width: splitX)
                            Spacer(minLength: 0)
                        }
                    )

                VStack {
                    HStack {
                        Text(beforeLabel)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.88), in: Capsule())
                            .opacity(beforeAlpha)
                        Spacer()
                        Text(afterLabel)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.68), in: Capsule())
                            .opacity(afterAlpha)
                    }
                    .padding(10)
                    Spacer()
                }
                .allowsHitTesting(false)

                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 2)
                        .shadow(color: .black.opacity(0.55), radius: 4)

                    HStack(spacing: isDragging ? 7 : 3) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: isDragging ? 48 : 36, height: isDragging ? 32 : 36)
                    .background(Color.black.opacity(0.74), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.42), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                }
                .position(x: splitX, y: fitH / 2)
                .allowsHitTesting(false)
            }
            .frame(width: fitW, height: fitH)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let raw = g.location.x / max(1, fitW)
                        let next = rubberOffset(raw: raw)
                        let clampedNext = max(0, min(1, next))
                        if !crossedHalfOnce && abs(clampedNext - 0.5) < 0.014 {
                            crossedHalfOnce = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } else if abs(clampedNext - 0.5) > 0.05 {
                            crossedHalfOnce = false
                        }
                        fraction = clampedNext
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            isDragging = false
                        }
                    }
            )
            .onTapGesture(count: 2) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    fraction = 0.5
                }
            }
            .position(x: maxW / 2, y: maxH / 2)
        }
    }
}

// MARK: - 4. 物理刻度尺微调条 (RulerSlider)
struct TactileRulerSliderView: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var majorEvery: Int = 5
    var spacing: CGFloat = 10
    var title: String = ""
    var accentColor: Color
    var formatValue: (Double) -> String = { String(format: "%.0f", $0) }

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStartValue: Double? = nil

    private func snapped(_ raw: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, raw))
        let count = ((clamped - range.lowerBound) / step).rounded()
        return min(range.upperBound, max(range.lowerBound, range.lowerBound + count * step))
    }

    var body: some View {
        let totalSteps = max(1, Int(((range.upperBound - range.lowerBound) / step).rounded()))
        let currentIndex = (value - range.lowerBound) / step

        HStack(spacing: 10) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                let midX = geo.size.width / 2
                let offset = -CGFloat(currentIndex) * spacing

                ZStack {
                    HStack(spacing: spacing - 1.5) {
                        ForEach(0...totalSteps, id: \.self) { idx in
                            let isMajor = idx % majorEvery == 0
                            RoundedRectangle(cornerRadius: 1)
                                .fill(isMajor ? Color.primary.opacity(0.62) : Color.secondary.opacity(0.32))
                                .frame(width: 1.5, height: isMajor ? 14 : 8)
                        }
                    }
                    .offset(x: midX + offset - 0.75)
                    .frame(width: geo.size.width, alignment: .leading)

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accentColor)
                        .frame(width: 2.5, height: 22)
                        .shadow(color: accentColor.opacity(0.5), radius: 4)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 0.84),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragStartValue == nil {
                                dragStartValue = value
                            }
                            guard let start = dragStartValue else { return }
                            let deltaUnits = -Double(g.translation.width / spacing) * step
                            let next = snapped(start + deltaUnits)
                            if abs(next - value) > (step * 0.25) {
                                value = next
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                        }
                )
            }
            .frame(width: 146, height: 26)

            Text(formatValue(value))
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundColor(accentColor)
                .frame(minWidth: 44, alignment: .trailing)
                .wallPullNumericContentTransition()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .wallPullFloatingSurface(in: Capsule())
    }
}

// MARK: - 5. 长按防误删确认胶囊 (HoldToConfirm)
struct HoldToConfirmCapsule: View {
    let title: String
    var icon: String = "trash.fill"
    var duration: Double = 0.85
    var tint: Color = .red
    var isDisabled: Bool = false
    let onConfirm: () -> Void

    @State private var isPressing: Bool = false
    @State private var fillProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>? = nil

    var body: some View {
        let labelView = HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)

        ZStack {
            labelView
                .foregroundColor(isDisabled ? .secondary : tint)
                .background((isDisabled ? Color.gray : tint).opacity(0.14), in: Capsule())

            labelView
                .foregroundColor(.white)
                .background(tint, in: Capsule())
                .mask(
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: geo.size.width * min(1, max(0, fillProgress)))
                            Spacer(minLength: 0)
                        }
                    }
                )
        }
        .overlay(Capsule().strokeBorder((isDisabled ? Color.gray : tint).opacity(0.45), lineWidth: 1))
        .scaleEffect(isPressing ? 0.96 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isPressing)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard !isDisabled else { return }
                    if abs(g.translation.width) > 36 || abs(g.translation.height) > 36 {
                        cancelHold()
                        return
                    }
                    if !isPressing {
                        startHold()
                    }
                }
                .onEnded { _ in
                    cancelHold()
                }
        )
        .opacity(isDisabled ? 0.5 : 1.0)
        .onDisappear {
            cancelHold()
        }
    }

    private func startHold() {
        holdTask?.cancel()
        isPressing = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let start = Date()
        holdTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                let p = CGFloat(min(1.0, elapsed / max(0.2, duration)))
                fillProgress = p
                if p >= 1.0 {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    isPressing = false
                    fillProgress = 0
                    onConfirm()
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func cancelHold() {
        guard isPressing || fillProgress > 0 else { return }
        holdTask?.cancel()
        holdTask = nil
        isPressing = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            fillProgress = 0
        }
    }
}

// MARK: - 6. 统一双任务灵动岛浮窗 (islandcn 形态原生化)
struct AnimatedLevelMeterView: View {
    let isPlaying: Bool
    let accentColor: Color
    var barCount: Int = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { idx in
                    let speed = 5.2 + Double(idx) * 1.15
                    let phase = Double(idx) * 0.9
                    let amp = isPlaying ? (0.34 + 0.64 * (0.5 + 0.5 * sin(t * speed + phase))) : 0.24
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accentColor)
                        .frame(width: 2.5, height: 14 * CGFloat(amp))
                        .frame(height: 14, alignment: .center)
                }
            }
        }
    }
}

struct UnifiedFloatingActivityCapsule: View {
    @ObservedObject var localSend: LocalSendService
    @ObservedObject var musicPlayer: MusicPlayerManager
    let accentColor: Color
    var hideMusicWhenObscured: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded: Bool = false
    @State private var preferMusicFocus: Bool = false

    init(
        localSend: LocalSendService,
        musicPlayer: MusicPlayerManager?,
        accentColor: Color,
        hideMusicWhenObscured: Bool = false
    ) {
        self.localSend = localSend
        self.musicPlayer = musicPlayer ?? MusicPlayerManager.idlePlaceholder
        self.accentColor = accentColor
        self.hideMusicWhenObscured = hideMusicWhenObscured
    }

    private var hasTransfer: Bool {
        localSend.transferProgress != nil
    }

    private var hasMusic: Bool {
        musicPlayer.activeTrack != nil && (!hideMusicWhenObscured || hasTransfer)
    }

    private var showTransferPrimary: Bool {
        if hasTransfer && hasMusic {
            return !preferMusicFocus
        }
        return hasTransfer
    }

    var body: some View {
        if hasTransfer || hasMusic {
            HStack(alignment: .bottom, spacing: 10) {
                if showTransferPrimary, let progress = localSend.transferProgress {
                    transferPill(progress: progress)
                } else if let track = musicPlayer.activeTrack {
                    musicPill(mp: musicPlayer, track: track)
                }

                if hasTransfer && hasMusic {
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            preferMusicFocus.toggle()
                            expanded = false
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        ZStack {
                            if showTransferPrimary {
                                AnimatedLevelMeterView(isPlaying: musicPlayer.isPlaying, accentColor: accentColor, barCount: 4)
                            } else if let progress = localSend.transferProgress {
                                Circle()
                                    .stroke(accentColor.opacity(0.22), lineWidth: 2.5)
                                    .frame(width: 22, height: 22)
                                Circle()
                                    .trim(from: 0, to: CGFloat(min(1, max(0.05, progress.fraction))))
                                    .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 22, height: 22)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .wallPullFloatingSurface(in: Circle())
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                    }
                    .buttonStyle(StickerPressButtonStyle())
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: showTransferPrimary)
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: expanded)
        }
    }

    @ViewBuilder
    private func transferPill(progress: TransferProgressState) -> some View {
        let subtitle: String? = {
            if let hint = progress.stageHint, !hint.isEmpty {
                return progress.totalFiles > 0 ? "\(progress.currentFileIndex)/\(progress.totalFiles) · \(hint)" : hint
            }
            guard progress.totalFiles > 0 else { return nil }
            if progress.totalBytes > 0 {
                let sent = formatFileSize(progress.bytesTransferred)
                let total = formatFileSize(progress.totalBytes)
                let speed = progress.bytesPerSecond >= 102_400
                    ? String(format: " · %.1f MB/s", progress.bytesPerSecond / 1_048_576.0)
                    : ""
                return "\(progress.currentFileIndex)/\(progress.totalFiles) · \(sent)/\(total)\(speed)"
            }
            return "\(progress.currentFileIndex)/\(progress.totalFiles) · \(Int((progress.fraction * 100).rounded()))%"
        }()

        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(accentColor.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0.04, progress.fraction))))
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(accentColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(progress.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .wallPullNumericContentTransition()
                }
            }

            if localSend.canCancelTransfer {
                Button {
                    localSend.cancelActiveTransfer()
                } label: {
                    Text("停止")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.13), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .wallPullFloatingSurface(in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    @ViewBuilder
    private func musicPill(mp: MusicPlayerManager, track: VaultAudioTrack) -> some View {
        VStack(spacing: expanded ? 10 : 0) {
            HStack(spacing: 11) {
                AnimatedLevelMeterView(isPlaying: mp.isPlaying, accentColor: .white, barCount: 4)
                    .frame(width: 32, height: 32)
                    .background(accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let itemTitle = mp.activeItem?.title {
                            Text(itemTitle)
                                .lineLimit(1)
                        }
                        Text("·")
                        MusicClockText(clock: mp.clock)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: 205, alignment: .leading)

                HStack(spacing: 4) {
                    Button { mp.toggleLoopMode() } label: {
                        Image(systemName: mp.isLoopingSingle ? "repeat.1" : "repeat")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(mp.isLoopingSingle ? accentColor : .secondary)
                            .frame(width: 28, height: 28)
                    }
                    Button { mp.prevTrack() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    Button { mp.togglePlayPause() } label: {
                        Image(systemName: mp.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(accentColor, in: Circle())
                    }
                    Button { mp.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    Button {
                        expanded = false
                        mp.stop()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 26, height: 26)
                    }
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                    expanded.toggle()
                }
            }

            if expanded {
                CapsuleMusicScrubber(clock: mp.clock, accentColor: accentColor, onSeek: { sec in
                    mp.seek(to: sec)
                })
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, expanded ? 11 : 8)
        .wallPullFloatingSurface(in: RoundedRectangle(cornerRadius: expanded ? 22 : 28, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}

private struct CapsuleMusicScrubber: View {
    @ObservedObject var clock: MusicPlaybackClock
    let accentColor: Color
    let onSeek: (Double) -> Void

    var body: some View {
        let dur = max(1, clock.duration)
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            ProgressView(value: min(1.0, max(0.0, clock.currentTime / dur)))
                .progressViewStyle(.linear)
                .tint(accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { g in
                            let frac = max(0, min(1, g.location.x / w))
                            onSeek(Double(frac) * dur)
                        }
                )
        }
        .frame(minWidth: 160, idealWidth: 280, maxWidth: 340, minHeight: 28, maxHeight: 28)
    }
}
