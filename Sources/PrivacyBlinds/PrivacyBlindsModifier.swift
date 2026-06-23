//
//  PrivacyBlindsModifier.swift
//  PrivacyBlinds
//
//  The ViewModifier behind `.privacyBlinds(...)`. It owns the motion subscription + reading-pose
//  capture, maps device deviation → closeProgress (with a soft open/close band) + a signed parallax
//  viewAngle, and drives the `privacyBlinds` layerEffect on an opaque cover overlay.
//

import SwiftUI
import UIKit

// MARK: - Motion model

/// Subscribes to the shared motion stream, captures the reading pose on first reading (and on
/// `recenter()`), and publishes the signed roll deviation from that pose. Held by the modifier as
/// `@State` so its lifetime tracks the view.
@MainActor
@Observable
final class PrivacyLensModel {
    /// Signed roll deviation (side-to-side) from the reading pose, in radians.
    private(set) var rollDeviation: Float = 0
    /// Signed pitch deviation (top-to-bottom) from the reading pose, in radians.
    private(set) var pitchDeviation: Float = 0
    /// Random offset for the perforated mask, regenerated each time the view appears so the hole
    /// pattern differs every time (but stays static while shown — see the shader note on why).
    private(set) var maskSeed = SIMD2<Float>(0, 0)

    private var referenceRoll: Float?
    private var referencePitch: Float?
    private var needsCapture = true
    private var token: UUID?

    // Settle detection: when a (re)capture is pending we wait until the device is held still before
    // anchoring the reading pose — so a re-center lands on where you actually read, not mid-motion.
    private var lastRoll: Float?
    private var lastPitch: Float?
    private var stillFrames = 0
    private var pendingFrames = 0
    private let stillDeltaThreshold: Float = 0.02   // rad/frame (roll+pitch); below this ≈ "held still"
    private let settleFrames = 15                   // ~0.25s of stillness before we anchor
    private let maxPendingFrames = 150              // ~2.5s safety valve so you can't get stuck closed

    func start() {
        needsCapture = true
        pendingFrames = 0
        // Fresh mask pattern each appearance.
        maskSeed = SIMD2<Float>(.random(in: 0..<4096), .random(in: 0..<4096))
        guard token == nil else { return }
        token = MotionManager.shared.addListener { [weak self] reading in
            // MotionManager always fans out on the main thread (it dispatches to main / the
            // simulation timer fires on main), so it is safe to assume main-actor isolation here
            // and update synchronously — no async hop, no motion lag.
            MainActor.assumeIsolated {
                guard let self else { return }

                // Track how still the device is, frame to frame, across both axes.
                if let lr = self.lastRoll, let lp = self.lastPitch {
                    let moved = abs(wrapToPi(reading.roll - lr)) + abs(wrapToPi(reading.pitch - lp))
                    self.stillFrames = moved < self.stillDeltaThreshold ? self.stillFrames + 1 : 0
                }
                self.lastRoll = reading.roll
                self.lastPitch = reading.pitch

                if self.needsCapture {
                    // Anchor once the user has settled (held still) — or force it after the safety
                    // timeout so a fidgety hold can't leave the cover stuck closed. Until then we keep
                    // measuring against the previous anchor (so the cover stays closed mid-reposition).
                    self.pendingFrames += 1
                    if self.stillFrames >= self.settleFrames || self.pendingFrames >= self.maxPendingFrames {
                        self.referenceRoll = reading.roll
                        self.referencePitch = reading.pitch
                        self.needsCapture = false
                        self.pendingFrames = 0
                    }
                }

                guard let refRoll = self.referenceRoll, let refPitch = self.referencePitch else { return }
                self.rollDeviation = wrapToPi(reading.roll - refRoll)
                self.pitchDeviation = wrapToPi(reading.pitch - refPitch)
            }
        }
    }

    /// Re-capture the reading pose once the device next settles (held still). Triggered deliberately
    /// (two-finger triple-tap) — never automatically from motion, so incidental movement can't reveal
    /// the content.
    func recenter() {
        needsCapture = true
        pendingFrames = 0
    }

    func stop() {
        if let token { MotionManager.shared.removeListener(token) }
        token = nil
    }
}

// MARK: - Modifier

public struct PrivacyBlindsModifier: ViewModifier {
    let cover: PrivacyCover
    let enabled: Bool

    // Feel knobs (defaults mirror the lenticular sim's LenticularEffectConfig).
    var stripWidthPt: CGFloat = 2.0
    var lenticuleSweep: Float = 1.0
    var transition: Float = 0.75
    var directionalSweep: Float = 0.5
    // Perforated privacy mask at the reading position (0 = off).
    var maskFillRatio: Float = 0
    var maskCellSize: CGFloat = 3
    var maskRevealHeight: CGFloat = 70   // height of the touch-following cleared reading band
    var maskRevealFeather: CGFloat = 18  // soft edge of the reading band
    var maskCover: PrivacyCover = .black // mask pattern appearance, independent of the blinds cover
    // Pose gate (degrees): reading pose → 0; combined roll+pitch deviation ≥ closeThreshold → covered.
    var openThresholdDeg: Float = 8
    var closeThresholdDeg: Float = 16
    var maxViewAngleDeg: Float = 20
    var onStateChange: ((Bool) -> Void)?

    @State private var model = PrivacyLensModel()
    @State private var touchLocation: CGPoint?
    @State private var revealProgress: CGFloat = 0

    /// The tileable blue-noise dither array shipped with the package, loaded once.
    private static let blueNoise: Image = {
        if let url = Bundle.module.url(forResource: "blueNoise", withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let ui = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "circle.fill") // fallback; should never hit
    }()

    /// 1×1 clear image passed as the mask-image slot when the mask isn't using an image (the shader
    /// argument must always be supplied, but it's never sampled in that case).
    private static let clearPixel: Image = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let ui = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Image(uiImage: ui)
    }()

    /// Total deviation from the reading pose (radians) — roll and pitch combined, so tilting in
    /// any direction (or a mix) past the threshold closes the cover.
    private var deviationMagnitude: Float {
        let r = model.rollDeviation, p = model.pitchDeviation
        return (r * r + p * p).squareRoot()
    }

    /// 0 = fully open/revealed .. 1 = fully closed/covered.
    private var closeProgress: Float {
        let open = openThresholdDeg * .pi / 180
        let close = closeThresholdDeg * .pi / 180
        return smoothstep(open, close, deviationMagnitude)
    }

    /// Signed view angle (radians) driving the closing-sweep direction. Both axes contribute so the
    /// blinds come in from the side you tilt toward: roll does left/right, pitch maps forward → left
    /// and back → right. Summing the signed deviations means a real pitch angle dominates the small
    /// incidental roll you pick up when tipping forward/back, so the direction is reliable.
    private var viewAngle: Float {
        let maxV = maxViewAngleDeg * .pi / 180
        let dir = model.rollDeviation + model.pitchDeviation
        return max(-maxV, min(maxV, dir))
    }

    public func body(content: Content) -> some View {
        // Reading closeProgress here establishes the state/observation dependencies for re-render.
        let progress = closeProgress
        let angle = viewAngle
        let closed = enabled && progress > 0.5
        let maskActive = enabled && maskFillRatio > 0
        let touch = touchLocation

        return content
            .overlay {
                if enabled {
                    GeometryReader { geo in
                        coverLayer(size: geo.size, closeProgress: progress, viewAngle: angle,
                                   revealY: Float(touch?.y ?? 0))
                            .overlay {
                                // Observe touches to drive the reading band WITHOUT consuming them, so
                                // the content underneath still scrolls. A window-level recognizer also
                                // dodges the ScrollView's ~150ms delaysContentTouches latency, so the
                                // band starts instantly. Only present while the mask is on.
                                if maskActive {
                                    TouchObserver { location in
                                        if let location {
                                            touchLocation = location
                                            if revealProgress != 1 {
                                                withAnimation(.easeOut(duration: 0.10)) { revealProgress = 1 }
                                            }
                                        } else if revealProgress != 0 {
                                            withAnimation(.easeIn(duration: 0.10)) { revealProgress = 0 }
                                        }
                                    }
                                }
                            }
                            // Deliberate re-center: two-finger triple-tap re-anchors the reading pose
                            // to the current pose (for recovering a lost view angle). Never automatic.
                            .overlay { RecenterGesture { model.recenter() } }
                    }
                    .ignoresSafeArea()
                    // Open ⇒ touches pass through to content (scroll/tap); closed ⇒ cover locks interaction.
                    .allowsHitTesting(closed)
                }
            }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: closed) { _, newValue in onStateChange?(newValue) }
    }

    private func coverLayer(size: CGSize, closeProgress: Float, viewAngle: Float,
                            revealY: Float) -> some View {
        // Resolve the mask's own appearance (independent of the blinds cover).
        let maskUseImage: Float
        let maskColorValue: Color
        let maskImageValue: Image
        switch maskCover {
        case .black:
            maskUseImage = 0; maskColorValue = .black; maskImageValue = Self.clearPixel
        case .color(let color):
            maskUseImage = 0; maskColorValue = color; maskImageValue = Self.clearPixel
        case .image(let image):
            maskUseImage = 1; maskColorValue = .black; maskImageValue = image
        }

        return coverBase
            .modifier(PrivacyBlindsShaderModifier(
                size: size,
                stripWidthPt: stripWidthPt,
                closeProgress: closeProgress,
                lenticuleSweep: lenticuleSweep,
                transition: transition,
                viewAngle: viewAngle,
                directionalSweep: directionalSweep,
                maskFillRatio: maskFillRatio,
                maskCellSize: maskCellSize,
                maskSeed: model.maskSeed,
                revealY: revealY,
                revealHalfHeight: Float(maskRevealHeight / 2),
                revealFeather: Float(maskRevealFeather),
                revealProgress: Double(revealProgress),
                blueNoise: Self.blueNoise,
                maskUseImage: maskUseImage,
                maskColor: maskColorValue,
                maskImage: maskImageValue
            ))
    }

    @ViewBuilder
    private var coverBase: some View {
        switch cover {
        case .black:
            Rectangle().fill(.black)
        case .color(let color):
            Rectangle().fill(color)
        case .image(let image):
            image.resizable().scaledToFill()
        }
    }
}

// MARK: - Animatable shader wrapper

/// Applies the `privacyBlinds` layerEffect. `Animatable` on `revealProgress` lets SwiftUI
/// interpolate it frame-by-frame under `withAnimation` — shader uniforms don't animate on their
/// own — so the touch reading band can emanate/fade smoothly. The other uniforms just take their
/// latest value on each render (motion already drives those at ~60 Hz).
private struct PrivacyBlindsShaderModifier: ViewModifier, Animatable {
    var size: CGSize
    var stripWidthPt: CGFloat
    var closeProgress: Float
    var lenticuleSweep: Float
    var transition: Float
    var viewAngle: Float
    var directionalSweep: Float
    var maskFillRatio: Float
    var maskCellSize: CGFloat
    var maskSeed: SIMD2<Float>
    var revealY: Float
    var revealHalfHeight: Float
    var revealFeather: Float
    var revealProgress: Double
    var blueNoise: Image
    var maskUseImage: Float
    var maskColor: Color
    var maskImage: Image

    nonisolated var animatableData: Double {
        get { revealProgress }
        set { revealProgress = newValue }
    }

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.bundle(.module).privacyBlinds(
                .float2(size),
                .float(Float(stripWidthPt)),
                .float(closeProgress),
                .float(lenticuleSweep),
                .float(transition),
                .float(viewAngle),
                .float(directionalSweep),
                .float(maskFillRatio),
                .float(Float(maskCellSize)),
                .float2(maskSeed.x, maskSeed.y),
                .float(Float(revealProgress)),
                .float(revealY),
                .float(revealHalfHeight),
                .float(revealFeather),
                .image(blueNoise),
                .float(maskUseImage),
                .color(maskColor),
                .image(maskImage)
            ),
            // The shader samples each pixel 1:1 (no translation), so it never reaches outside
            // the cover — zero sample offset.
            maxSampleOffset: .zero
        )
    }
}

// MARK: - Passthrough touch observer

/// Reports the touch location (or nil on lift) without consuming touches — the content underneath
/// keeps scrolling/tapping. The recognizer is attached at the window so it fires on touch-down
/// immediately, sidestepping a ScrollView's `delaysContentTouches` latency. Coordinates are in the
/// observing view's space, which the GeometryReader aligns with the shader's `position`.
private struct TouchObserver: UIViewRepresentable {
    var onChange: (CGPoint?) -> Void

    func makeUIView(context: Context) -> TouchObservingView {
        let view = TouchObservingView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: TouchObservingView, context: Context) {
        uiView.onChange = onChange
    }
}

private final class TouchObservingView: UIView, UIGestureRecognizerDelegate {
    var onChange: ((CGPoint?) -> Void)?
    private weak var attachedTo: UIView?

    private lazy var press: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        g.minimumPressDuration = 0          // fire on touch-down, no delay
        g.cancelsTouchesInView = false      // don't steal touches from the scroll view
        g.delaysTouchesBegan = false
        g.delegate = self
        return g
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachedTo?.removeGestureRecognizer(press)
        attachedTo = nil
        if let window {
            window.addGestureRecognizer(press)
            attachedTo = window
        }
    }

    @objc private func handle(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            onChange?(bounds.contains(p) ? p : nil)   // ignore touches outside the protected view
        default:
            onChange?(nil)
        }
    }

    // Never the hit-test target → touches always pass through to the content below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - Re-center gesture (two-finger triple-tap)

/// Fires `onRecenter` on a two-finger triple-tap — a deliberate, uncommon gesture that won't collide
/// with normal taps/scrolls. Attached at the window and non-consuming, so it works anywhere over the
/// protected view without interfering with the content.
private struct RecenterGesture: UIViewRepresentable {
    var onRecenter: () -> Void

    func makeUIView(context: Context) -> RecenterView {
        let view = RecenterView()
        view.onRecenter = onRecenter
        return view
    }

    func updateUIView(_ uiView: RecenterView, context: Context) {
        uiView.onRecenter = onRecenter
    }
}

private final class RecenterView: UIView, UIGestureRecognizerDelegate {
    var onRecenter: (() -> Void)?
    private weak var attachedTo: UIView?

    private lazy var tap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(fire))
        g.numberOfTouchesRequired = 2
        g.numberOfTapsRequired = 3
        g.cancelsTouchesInView = false
        g.delegate = self
        return g
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachedTo?.removeGestureRecognizer(tap)
        attachedTo = nil
        if let window {
            window.addGestureRecognizer(tap)
            attachedTo = window
        }
    }

    @objc private func fire() { onRecenter?() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - Math helpers

@inline(__always)
func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let denom = max(edge1 - edge0, .leastNonzeroMagnitude)
    let t = max(0, min(1, (x - edge0) / denom))
    return t * t * (3 - 2 * t)
}

@inline(__always)
func wrapToPi(_ angle: Float) -> Float {
    var x = angle
    while x > .pi { x -= 2 * .pi }
    while x < -.pi { x += 2 * .pi }
    return x
}
