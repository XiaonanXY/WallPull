import SwiftUI
import UIKit

// MARK: - 1. BorderGlow 多选默认环境流光边框 (CoreAnimation Render-Server Layer — 0% main-thread overhead)
final class HardwareGlowBorderView: UIView {
    private let baseRingLayer = CAShapeLayer()
    private let ringContainerLayer = CALayer()
    private let snakeGradientLayer = CAGradientLayer()
    private let snakeMaskLayer = CAShapeLayer()
    private var cornerRadius: CGFloat = 16
    private var borderLineWidth: CGFloat = 3.2
    private var currentAccentColor: UIColor = .systemPurple
    private var lastBoundsSize: CGSize = .zero

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true

        baseRingLayer.fillColor = nil
        layer.addSublayer(baseRingLayer)

        ringContainerLayer.masksToBounds = false
        layer.addSublayer(ringContainerLayer)

        snakeGradientLayer.type = .conic
        snakeGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        snakeGradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        snakeGradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 0.95).cgColor,
            UIColor(red: 0.0, green: 0.749, blue: 0.910, alpha: 0.98).cgColor,
            UIColor(red: 0.0, green: 0.851, blue: 0.494, alpha: 0.98).cgColor,
            UIColor(red: 1.0, green: 0.835, blue: 0.0, alpha: 0.98).cgColor,
            UIColor(red: 1.0, green: 0.090, blue: 0.267, alpha: 0.95).cgColor,
            UIColor.clear.cgColor,
        ]
        snakeGradientLayer.locations = [0.0, 0.62, 0.70, 0.77, 0.84, 0.90, 0.96, 1.0]
        ringContainerLayer.addSublayer(snakeGradientLayer)

        snakeMaskLayer.fillColor = nil
        snakeMaskLayer.strokeColor = UIColor.white.cgColor
        ringContainerLayer.mask = snakeMaskLayer

        startSpinIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(accentColor: UIColor, cornerRadius: CGFloat, lineWidth: CGFloat) {
        let changedGeom = abs(self.cornerRadius - cornerRadius) > 0.01 || abs(self.borderLineWidth - lineWidth) > 0.01
        self.cornerRadius = cornerRadius
        self.borderLineWidth = lineWidth
        self.currentAccentColor = accentColor
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        baseRingLayer.strokeColor = accentColor.withAlphaComponent(reduceMotion ? 1.0 : 0.42).cgColor
        baseRingLayer.lineWidth = reduceMotion ? lineWidth : max(1.6, lineWidth * 0.6)
        snakeMaskLayer.lineWidth = lineWidth
        if changedGeom {
            lastBoundsSize = .zero
            setNeedsLayout()
        }
        startSpinIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startSpinIfNeeded()
        }
    }

    private func startSpinIfNeeded() {
        if UIAccessibility.isReduceMotionEnabled {
            ringContainerLayer.isHidden = true
            snakeGradientLayer.removeAnimation(forKey: "wp_glow_spin")
            baseRingLayer.strokeColor = currentAccentColor.cgColor
            baseRingLayer.lineWidth = borderLineWidth
            return
        }
        ringContainerLayer.isHidden = false
        baseRingLayer.strokeColor = currentAccentColor.withAlphaComponent(0.42).cgColor
        baseRingLayer.lineWidth = max(1.6, borderLineWidth * 0.6)
        if snakeGradientLayer.animation(forKey: "wp_glow_spin") == nil {
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = 0.0
            anim.toValue = Double.pi * 2.0
            anim.duration = 2.8
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            snakeGradientLayer.add(anim, forKey: "wp_glow_spin")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        if bounds.size == lastBoundsSize { return }
        lastBoundsSize = bounds.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = borderLineWidth * 0.5
        let path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, cornerRadius - inset)
        ).cgPath
        baseRingLayer.frame = bounds
        baseRingLayer.path = path

        ringContainerLayer.frame = bounds
        snakeMaskLayer.frame = bounds
        snakeMaskLayer.path = path

        let diag = ceil(hypot(bounds.width, bounds.height)) + 16
        snakeGradientLayer.bounds = CGRect(x: 0, y: 0, width: diag, height: diag)
        snakeGradientLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

struct BorderGlowOverlay: UIViewRepresentable {
    let accentColor: Color
    var cornerRadius: CGFloat = 16
    var lineWidth: CGFloat = 3.2

    func makeUIView(context: Context) -> HardwareGlowBorderView {
        let v = HardwareGlowBorderView()
        v.update(accentColor: UIColor(accentColor), cornerRadius: cornerRadius, lineWidth: lineWidth)
        return v
    }

    func updateUIView(_ uiView: HardwareGlowBorderView, context: Context) {
        uiView.update(accentColor: UIColor(accentColor), cornerRadius: cornerRadius, lineWidth: lineWidth)
    }
}

// MARK: - 3. SpringCheck 弹簧复选徽章 (1:1 port of SpringCheck.jsx)
private struct SpringCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.25, y: h * 0.52))
        p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.71))
        p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.31))
        return p
    }
}

struct SpringCheckBadge: View {
    let checked: Bool
    let accentColor: Color
    var size: CGFloat = 25

    var body: some View {
        ZStack {
            Circle()
                .fill(checked ? accentColor : Color.black.opacity(0.42))
                .frame(width: size, height: size)
                .scaleEffect(checked ? 1.06 : 0.94)
            Circle()
                .strokeBorder(checked ? Color.white : Color.white.opacity(0.88), lineWidth: 1.6)
                .frame(width: size, height: size)
            SpringCheckmarkShape()
                .trim(from: 0, to: checked ? 1.0 : 0.0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.55), value: checked)
    }
}

// MARK: - 4. PulseHeart 脉冲收藏桃心 (1:1 port of PulseHeart.jsx)
struct PulseHeartButton: View {
    let isFavorite: Bool
    let onToggle: () -> Void

    @State private var heartScale: CGFloat = 1.0
    @State private var burstProgress: CGFloat = 0.0
    @State private var showBurst: Bool = false

    private let heartPink = Color(hex: "#FF4D6D")

    var body: some View {
        Button {
            let willFavorite = !isFavorite
            onToggle()
            if willFavorite {
                showBurst = true
                burstProgress = 0
                heartScale = 1.48
                withAnimation(.spring(response: 0.34, dampingFraction: 0.44)) {
                    heartScale = 1.0
                }
                withAnimation(.easeOut(duration: 0.54)) {
                    burstProgress = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) {
                    showBurst = false
                    burstProgress = 0
                }
            } else {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                    heartScale = 0.85
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) {
                        heartScale = 1.0
                    }
                }
            }
        } label: {
            ZStack {
                if showBurst {
                    Circle()
                        .stroke(heartPink.opacity(max(0, 1.0 - burstProgress)), lineWidth: 2.2)
                        .frame(width: 28, height: 28)
                        .scaleEffect(1.0 + burstProgress * 0.95)
                        .allowsHitTesting(false)

                    ForEach(0..<6, id: \.self) { idx in
                        let rad = Double(idx) * .pi / 3.0
                        let dist = 14.0 + Double(burstProgress) * 12.0
                        Circle()
                            .fill(heartPink.opacity(max(0, 1.0 - burstProgress)))
                            .frame(width: 3.5, height: 3.5)
                            .offset(
                                x: cos(rad) * dist,
                                y: sin(rad) * dist
                            )
                            .allowsHitTesting(false)
                    }
                }

                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(isFavorite ? heartPink : .white.opacity(0.92))
                    .scaleEffect(heartScale)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.42), in: Circle())
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 5. ShinyText 品牌光泽文字 (1:1 port of ShinyText.jsx)
struct ShinyTextTitle: View {
    let text: String
    var font: Font = .system(size: 23, weight: .bold, design: .rounded)
    @Environment(\.colorScheme) private var colorScheme
    @State private var sweepProgress: CGFloat = -0.5

    @State private var didSweep: Bool = false

    var body: some View {
        let baseColor = colorScheme == .dark ? Color.white : Color(hex: "#18181B")
        let shineColor = colorScheme == .dark ? Color(hex: "#E0E7FF") : Color(hex: "#7C3AED")

        Text(text)
            .font(font)
            .foregroundColor(baseColor)
            .overlay(
                Group {
                    if !didSweep {
                        GeometryReader { geo in
                            let w = max(1, geo.size.width)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: shineColor.opacity(0.75), location: 0.5),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(width: w * 0.55)
                            .offset(x: sweepProgress * w * 1.6)
                        }
                        .mask(Text(text).font(font))
                        .allowsHitTesting(false)
                    }
                }
            )
            .onAppear {
                guard !didSweep else { return }
                sweepProgress = -0.6
                withAnimation(.easeInOut(duration: 2.0).delay(0.4)) {
                    sweepProgress = 1.2
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    didSweep = true
                }
            }
    }
}

// MARK: - 6. NewlyLanded 逐张入库 3D 翻转 + Q 弹落地动画 (B7 拓展)
struct NewlyLandedFlipBounceModifier: ViewModifier {
    let isNewlyLanded: Bool
    let accentColor: Color
    let onSettled: () -> Void

    @State private var flipDegrees: Double = 0
    @State private var bounceScale: CGFloat = 1.0
    @State private var bounceY: CGFloat = 0
    @State private var fadeOpacity: Double = 1.0
    @State private var didAnimate: Bool = false

    func body(content: Content) -> some View {
        let showBackFace = abs(flipDegrees) > 90
        content
            .opacity(showBackFace ? 0 : fadeOpacity)
            .overlay(
                Group {
                    if showBackFace {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accentColor.opacity(0.9), accentColor.opacity(0.55)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                Image(systemName: "sparkles")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(.white.opacity(0.92))
                            )
                    }
                }
            )
            .scaleEffect(bounceScale)
            .offset(y: bounceY)
            .rotation3DEffect(
                .degrees(flipDegrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.55
            )
            .onAppear {
                guard isNewlyLanded && !didAnimate else { return }
                didAnimate = true
                flipDegrees = -180
                bounceScale = 0.52
                bounceY = 18
                fadeOpacity = 0.25

                // Phase 1: 3D flip + Q-elastic overshoot
                withAnimation(.spring(response: 0.48, dampingFraction: 0.62, blendDuration: 0.1)) {
                    flipDegrees = 0
                    bounceScale = 1.07
                    bounceY = -5
                    fadeOpacity = 1.0
                }
                // Phase 2: soft Q-bounce settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.58)) {
                        bounceScale = 1.0
                        bounceY = 0
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                    onSettled()
                }
            }
    }
}

// MARK: - 7. RollingCounterText (ReactBits CountUp 触屏数值平滑滚动)
struct RollingCounterText: View {
    let value: Int
    var prefix: String = ""
    var suffix: String = ""

    var body: some View {
        let label = Text("\(prefix)\(value)\(suffix)")
            .monospacedDigit()
        if #available(iOS 16.0, *) {
            label
                .contentTransition(.numericText())
                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: value)
        } else {
            label
        }
    }
}

// MARK: - 8. ElasticVideoSlider (ReactBits ElasticSlider / WakeSlider 触屏弹性拖拽进度条)
struct ElasticVideoSlider: View {
    @Binding var value: Double
    let total: Double
    let accentColor: Color
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging: Bool = false
    @State private var edgeStretch: CGFloat = 0

    private var safeTotal: Double {
        max(0.5, total)
    }

    private var progress: Double {
        min(1.0, max(0.0, value / safeTotal))
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let stretchX = edgeStretch * 0.45
            let stretchScaleX = 1.0 + abs(edgeStretch) / max(120, width) * 0.45

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(isDragging ? 0.28 : 0.20))
                    .frame(height: isDragging ? 9 : 5)

                Capsule()
                    .fill(accentColor)
                    .frame(width: max(isDragging ? 10 : 6, width * progress), height: isDragging ? 9 : 5)

                if isDragging {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: accentColor.opacity(0.65), radius: 5)
                        .offset(x: min(max(0, width * progress - 7.5), width - 15))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(x: stretchScaleX, y: isDragging ? 1.06 : 1.0, anchor: edgeStretch >= 0 ? .leading : .trailing)
            .offset(x: stretchX)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let rawX = gesture.location.x
                        if rawX < 0 {
                            edgeStretch = max(-14, (rawX / width) * 32)
                        } else if rawX > width {
                            edgeStretch = min(14, ((rawX - width) / width) * 32)
                        } else {
                            edgeStretch = 0
                        }
                        let ratio = min(1.0, max(0.0, Double(rawX / width)))
                        value = ratio * safeTotal
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.58)) {
                            edgeStretch = 0
                            isDragging = false
                        }
                        onEditingChanged(false)
                    }
            )
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.78), value: isDragging)
        }
        .frame(height: 28)
    }
}

// MARK: - 9. 零开销卡片坐标追踪器 + 3D 翻转放大飞入/飞回容器 (B7 原版: WallpaperDetailDialog.jsx)
@MainActor
final class CardFrameTracker {
    private final class WeakBox {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var boxes: [String: WeakBox] = [:]

    func register(id: String, view: UIView) {
        boxes[id] = WeakBox(view)
    }

    func rect(for id: String) -> CGRect? {
        guard let v = boxes[id]?.view, v.window != nil else { return nil }
        return v.convert(v.bounds, to: nil)
    }
}

struct CardAnchorView: UIViewRepresentable {
    let id: String
    let tracker: CardFrameTracker

    final class Coordinator {
        var lastID: String = ""
        weak var lastView: UIView?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        context.coordinator.lastID = id
        context.coordinator.lastView = v
        tracker.register(id: id, view: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.lastID != id || context.coordinator.lastView !== uiView {
            context.coordinator.lastID = id
            context.coordinator.lastView = uiView
            tracker.register(id: id, view: uiView)
        }
    }
}

private struct FlipModalStage<DetailContent: View>: View, Animatable {
    var phase: CGFloat
    let originRect: CGRect?
    let coverImage: UIImage?
    let showFullUI: Bool
    let detailContent: () -> DetailContent

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        let p = max(0.0, min(1.0, phase))
        GeometryReader { geo in
            let targetRect = CGRect(origin: .zero, size: geo.size)
            let startRect = (originRect != nil && originRect!.width > 10 && originRect!.height > 10)
                ? originRect!
                : CGRect(x: geo.size.width / 2 - 140, y: geo.size.height / 2 - 90, width: 280, height: 180)

            let curW = startRect.width + (targetRect.width - startRect.width) * p
            let curH = startRect.height + (targetRect.height - startRect.height) * p
            let curMidX = startRect.midX + (targetRect.midX - startRect.midX) * p
            let curMidY = startRect.midY + (targetRect.midY - startRect.midY) * p
            let curRadius = 16.0 * (1.0 - p)
            let isFrontHalf = p >= 0.5
            let angleDeg = isFrontHalf ? Double(p - 1.0) * 180.0 : Double(p) * 180.0

            ZStack {
                if !isFrontHalf {
                    Group {
                        if let coverImage {
                            Image(uiImage: coverImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color(hex: "#14141B")
                        }
                    }
                    .frame(width: curW, height: curH)
                    .clipShape(RoundedRectangle(cornerRadius: curRadius, style: .continuous))
                } else {
                    detailContent()
                        .frame(width: targetRect.width, height: targetRect.height)
                        .opacity(showFullUI ? 1.0 : Double((p - 0.5) / 0.5))
                        .allowsHitTesting(showFullUI)
                }
            }
            .frame(
                width: isFrontHalf && showFullUI ? targetRect.width : curW,
                height: isFrontHalf && showFullUI ? targetRect.height : curH
            )
            .clipShape(RoundedRectangle(cornerRadius: showFullUI ? 0 : curRadius, style: .continuous))
            .rotation3DEffect(
                .degrees(angleDeg),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.42
            )
            .position(
                x: showFullUI ? targetRect.midX : curMidX,
                y: showFullUI ? targetRect.midY : curMidY
            )
        }
        .ignoresSafeArea(.all)
    }
}

struct DetailFlipModalContainer<DetailContent: View>: View {
    let originRect: CGRect?
    let coverImage: UIImage?
    let isClosing: Bool
    let onDismissAnimationComplete: () -> Void
    @ViewBuilder let detailContent: () -> DetailContent

    @State private var phase: CGFloat = 0.0 // 0 = at card origin, 1 = expanded full screen
    @State private var showFullUI: Bool = false
    @State private var animTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.96 * phase)
                .ignoresSafeArea(.all)

            FlipModalStage(
                phase: phase,
                originRect: originRect,
                coverImage: coverImage,
                showFullUI: showFullUI,
                detailContent: detailContent
            )
        }
        .ignoresSafeArea(.all)
        .statusBar(hidden: phase > 0.45)
        .onAppear {
            animTask?.cancel()
            phase = 0
            showFullUI = false
            withAnimation(.timingCurve(0.32, 0.08, 0.24, 1.0, duration: 0.56)) {
                phase = 1.0
            }
            animTask = Task {
                try? await Task.sleep(nanoseconds: 520_000_000)
                guard !Task.isCancelled, !isClosing else { return }
                showFullUI = true
            }
        }
        .onChange(of: isClosing) { closing in
            guard closing else { return }
            animTask?.cancel()
            showFullUI = false
            withAnimation(.timingCurve(0.28, 0.0, 0.2, 1.0, duration: 0.40)) {
                phase = 0.0
            }
            animTask = Task {
                try? await Task.sleep(nanoseconds: 410_000_000)
                guard !Task.isCancelled else { return }
                onDismissAnimationComplete()
            }
        }
        .onDisappear {
            animTask?.cancel()
            animTask = nil
        }
    }
}
