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
import simd
import QuartzCore

// MARK: - Lens model

/// Orchestrates the pose + gaze streams and publishes the values the overlay renders from. The actual
/// gating logic lives in the pure, unit-tested `PoseGate` / `GazeGate`; this type only wires the
/// device sources to them and mirrors their outputs into observable state. Sources are injected
/// (defaulting to the shared singletons) so the model can be driven with fakes in tests.
@MainActor
@Observable
final class PrivacyLensModel {
    /// Signed roll deviation (side-to-side) from the reading pose, in radians.
    private(set) var rollDeviation: Float = 0
    /// Signed pitch deviation (top-to-bottom) from the reading pose, in radians.
    private(set) var pitchDeviation: Float = 0
    /// 0 = looking at the screen .. 1 = looking away (only meaningful with eye tracking on).
    private(set) var gazeAway: Float = 0
    /// Signed horizontal look-away direction (drives the sweep when gaze is the closer).
    private(set) var gazeDirection: Float = 0
    /// ARKit ambient light estimate (lux, -1 when unknown). Surfaced via the modifier for the host.
    private(set) var ambientLux: Double = -1
    /// True once gaze tracking is online this session (or unavailable → pose-only). Drives the
    /// post-unlock "warming up" cover so content isn't exposed while ARKit acquires the face.
    private(set) var gazeReady = false
    /// Random offset for the perforated mask, regenerated each appearance (static while shown).
    private(set) var maskSeed = SIMD2<Float>(0, 0)

    /// Lock state for authenticated-gaze mode. In pose-only mode it stays `.unlocked` and is ignored.
    enum LockState { case locked, authenticating, unlocked }
    private(set) var lockState: LockState = .unlocked

    private let poseSource: PoseSource
    private let gazeSource: GazeSource
    private let authenticator: Authenticating
    private var poseGate = PoseGate()
    private var gazeGate = GazeGate()

    private var token: UUID?
    private var gazeToken: UUID?
    /// While the AR (eye-tracking) session runs it suspends CMMotionManager, so pose comes from ARKit.
    private var usingARPose = false
    // Gaze config carried so unlock can (re)start gaze with the right thresholds.
    private var gazeMinLux = Tuning.ambientLuxLow
    private var gazeResumeLux = Tuning.ambientLuxHigh

    init(pose: PoseSource = MotionManager.shared,
         gaze: GazeSource = EyeTracker.shared,
         authenticator: Authenticating = BiometricAuthenticator()) {
        self.poseSource = pose
        self.gazeSource = gaze
        self.authenticator = authenticator
    }

    func start() {
        poseGate.fullReset()
        publishPose()
        regenerateMaskSeed()
        guard token == nil else { return }
        token = poseSource.addListener { [weak self] reading in
            // The sources always fan out on the main thread, so assume main-actor isolation and
            // update synchronously — no async hop, no motion lag.
            MainActor.assumeIsolated {
                guard let self, !self.usingARPose else { return }   // ARKit drives pose while it runs
                self.poseGate.apply(roll: reading.roll, pitch: reading.pitch, now: CACurrentMediaTime())
                self.publishPose()
            }
        }
    }

    /// Re-anchor the reading pose (and re-baseline gaze) on the next settle. Triggered deliberately
    /// (two-finger triple-tap) — never automatically from motion, so incidental movement can't reveal.
    func recenter() {
        poseGate.reset()
        gazeGate.recenter()
    }

    /// Begin gaze tracking (opt-in). Starts the front-camera session (prompts for camera permission
    /// the first time); while it runs, ARKit also supplies the device pose. `minLux`/`resumeLux`
    /// configure the low-light suspension band.
    func startGaze(minLux: Double, resumeLux: Double) {
        gazeGate.minLux = minLux
        gazeGate.resumeLux = resumeLux
        // Open the moment we unlock: zero pose + re-baseline gaze and publish now, so the view shows
        // through the camera warm-up instead of flashing the cover until the first AR frame lands.
        gazeGate.recenter()
        poseGate.fullReset()
        gazeReady = false   // begin warm-up: hold the processing cover until tracking is online
        publishPose()
        publishGaze()
        guard gazeToken == nil else { return }
        gazeToken = gazeSource.addListener { [weak self] reading in
            MainActor.assumeIsolated {
                guard let self else { return }
                if reading.unavailable {
                    // No TrueDepth / permission denied → AR drives nothing; stay on CoreMotion pose.
                    if self.usingARPose { self.usingARPose = false; self.poseGate.fullReset() }
                    self.gazeGate.reset()
                    self.gazeReady = true   // no gaze → pose-only protection is live; end warm-up
                    self.publishPose()
                    self.publishGaze()
                    return
                }
                // AR session is delivering frames → it drives pose (CMMotionManager is suspended).
                if !self.usingARPose { self.usingARPose = true; self.poseGate.fullReset() }
                self.poseGate.apply(roll: reading.roll, pitch: reading.pitch, now: CACurrentMediaTime())
                self.publishPose()
                // The gate handles look-away (binary slam) and low-light suspension internally.
                self.gazeGate.apply(reading)
                self.ambientLux = reading.ambientLux
                self.gazeReady = self.gazeGate.ready
                self.publishGaze()
            }
        }
    }

    func stopGaze() {
        if let gazeToken { gazeSource.removeListener(gazeToken) }
        gazeToken = nil
        gazeGate.reset()
        gazeReady = false
        if usingARPose { usingARPose = false; poseGate.fullReset() }
        publishGaze()
        publishPose()   // zero deviations so the next start/unlock reads as open (no stale flash)
    }

    func stop() {
        if let token { poseSource.removeListener(token) }
        token = nil
        stopGaze()
    }

    // MARK: Authenticated-gaze lock state

    /// Enter authenticated-gaze mode: start LOCKED (camera off) and wait for a tap to authenticate.
    func enterAuthenticatedMode(minLux: Double, resumeLux: Double) {
        gazeMinLux = minLux
        gazeResumeLux = resumeLux
        regenerateMaskSeed()   // fresh perforation pattern for the locked screen
        lockState = .locked
    }

    /// Tap on the locked cover → authenticate; on success unlock + start gaze, else stay locked.
    func beginUnlock(reason: String) {
        guard lockState == .locked else { return }
        lockState = .authenticating
        authenticator.authenticate(reason: reason) { [weak self] success in
            guard let self else { return }
            if success {
                self.lockState = .unlocked
                self.regenerateMaskSeed()
                self.startGaze(minLux: self.gazeMinLux, resumeLux: self.gazeResumeLux)
            } else {
                self.lockState = .locked
            }
        }
    }

    /// Return to the locked state (re-lock): stop gaze/camera and require auth again.
    func relock() {
        guard lockState != .locked else { return }
        regenerateMaskSeed()   // fresh perforation pattern each lock
        lockState = .locked
        stopGaze()
    }

    private func regenerateMaskSeed() {
        maskSeed = SIMD2<Float>(.random(in: 0..<Tuning.maskSeedRange),
                                .random(in: 0..<Tuning.maskSeedRange))
    }

    private func publishPose() {
        rollDeviation = poseGate.rollDeviation
        pitchDeviation = poseGate.pitchDeviation
    }

    private func publishGaze() {
        gazeAway = gazeGate.away
        gazeDirection = gazeGate.direction
    }
}

// MARK: - Modifier

public struct PrivacyBlindsModifier: ViewModifier {
    let cover: PrivacyCover
    let enabled: Bool

    // Feel knobs.
    var stripWidthPt: CGFloat = 2.0
    var stripSweep: Float = 1.0
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
    // Authenticated-gaze mode: Face ID lock/unlock + eye tracking (bundled). Off = pose-only.
    var authenticatedGaze: Bool = false
    var gazeMinLux: Double = Tuning.ambientLuxLow      // suspend gaze below this ambient light
    var gazeResumeLux: Double = Tuning.ambientLuxHigh  // resume gaze above this ambient light
    var relockSeconds: Double = 10                     // re-lock after this long continuously covered
    var lockMaskFillRatio: Float = 0.4                 // perforation density on the locked screen
    var unlockReason: String = "Unlock to reveal"
    // Locked-screen appearance (all default to the stock white / black look).
    var lockBackgroundColor: Color = .white
    var lockPatternColor: Color = .black
    var lockIconBackgroundColor: Color = .white
    var lockIconColor: Color = .black
    var onStateChange: ((Bool) -> Void)?
    var onAmbientLux: ((Double) -> Void)?   // reports the ARKit ambient light estimate (lux)

    @State private var model = PrivacyLensModel()
    @State private var touchLocation: CGPoint?
    @State private var revealProgress: CGFloat = 0
    @State private var relockTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The tileable blue-noise dither array shipped with the package, loaded once.
    private static let blueNoise: Image = {
        guard let url = Bundle.module.url(forResource: "blueNoise", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let ui = UIImage(data: data) else {
            assertionFailure("PrivacyBlinds: blueNoise.png is missing from the package resource bundle")
            return Image(systemName: "circle.fill")
        }
        return Image(uiImage: ui)
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

    /// Pose-only close amount from the combined roll+pitch deviation.
    private var poseCloseProgress: Float {
        let open = openThresholdDeg * .pi / 180
        let close = closeThresholdDeg * .pi / 180
        return smoothstep(open, close, deviationMagnitude)
    }

    /// 0 = fully open/revealed .. 1 = fully closed/covered. Closes on pose deviation OR (in
    /// authenticated-gaze mode, while unlocked) looking away — whichever is greater.
    private var closeProgress: Float {
        let pose = poseCloseProgress
        guard authenticatedGaze else { return pose }
        return max(pose, model.gazeAway)
    }

    /// Signed view angle (radians) driving the closing-sweep direction. Pose: roll does left/right,
    /// pitch maps forward → left and back → right (summed). When gaze is the dominant closer, the
    /// look-away direction drives the sweep instead.
    private var viewAngle: Float {
        let maxV = maxViewAngleDeg * .pi / 180
        if authenticatedGaze && model.gazeAway > poseCloseProgress {
            return max(-maxV, min(maxV, model.gazeDirection * maxV))
        }
        let dir = model.rollDeviation + model.pitchDeviation
        return max(-maxV, min(maxV, dir))
    }

    public func body(content: Content) -> some View {
        // Reading closeProgress here establishes the state/observation dependencies for re-render.
        let progress = closeProgress
        let angle = viewAngle
        let locked = authenticatedGaze && model.lockState != .unlocked
        // Unlocked but tracking not yet online → hold a covering "warming up" scan over the content.
        let warming = authenticatedGaze && model.lockState == .unlocked && !model.gazeReady
        let closed = enabled && (locked || warming || progress > Tuning.closedThreshold)
        let maskActive = enabled && maskFillRatio > 0
        let touch = touchLocation

        return content
            .overlay {
                if enabled {
                    GeometryReader { geo in
                        if locked {
                            lockedCover(size: geo.size)
                        } else if warming {
                            warmingCover(size: geo.size)
                        } else {
                            coverLayer(size: geo.size, closeProgress: progress, viewAngle: angle,
                                       revealY: Float(touch?.y ?? 0), revealProgress: Double(revealProgress))
                                .overlay {
                                    // Observe touches to drive the reading band WITHOUT consuming them,
                                    // so the content underneath still scrolls. A window-level recognizer
                                    // also dodges the ScrollView's ~150ms delaysContentTouches latency,
                                    // so the band starts instantly. Only present while the mask is on.
                                    if maskActive {
                                        TouchObserver { location in
                                            if let location {
                                                touchLocation = location
                                                if revealProgress != 1 {
                                                    setRevealProgress(1, .easeOut(duration: Tuning.revealOpenDuration))
                                                }
                                            } else if revealProgress != 0 {
                                                setRevealProgress(0, .easeIn(duration: Tuning.revealCloseDuration))
                                            }
                                        }
                                    }
                                }
                                // Deliberate re-center: two-finger triple-tap re-anchors the reading
                                // pose to the current pose (recovering a lost view angle). Never automatic.
                                .overlay { RecenterGesture { model.recenter() } }
                        }
                    }
                    .ignoresSafeArea()
                    // Locked ⇒ cover is a tap target; open ⇒ touches pass through; closed ⇒ locks interaction.
                    .allowsHitTesting(closed)
                }
            }
            .onAppear { startMode() }
            .onDisappear { model.stop() }
            .onChange(of: authenticatedGaze) { _, _ in model.stop(); startMode() }
            .onChange(of: closed) { _, newValue in
                onStateChange?(newValue)
                scheduleRelockIfNeeded(covered: newValue)
            }
            .onChange(of: scenePhase) { _, phase in
                // Re-lock on background (also covers the app-switcher snapshot). Not on `.inactive`,
                // which the Face ID prompt itself triggers.
                if phase == .background, model.lockState == .unlocked { model.relock() }
            }
            .onChange(of: model.ambientLux) { _, lux in onAmbientLux?(lux) }
    }

    /// Start the right mode for the current `authenticatedGaze` setting.
    private func startMode() {
        if authenticatedGaze {
            model.enterAuthenticatedMode(minLux: gazeMinLux, resumeLux: gazeResumeLux)
        } else {
            model.start()
        }
    }

    /// Re-lock after the view has been continuously covered for `relockSeconds` (authenticated-gaze
    /// only, while unlocked). Revealing cancels the pending re-lock.
    private func scheduleRelockIfNeeded(covered: Bool) {
        relockTask?.cancel()
        relockTask = nil
        guard authenticatedGaze, covered, model.lockState == .unlocked else { return }
        relockTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(relockSeconds))
            if !Task.isCancelled, model.lockState == .unlocked { model.relock() }
        }
    }

    /// The SAME perforated blue-noise pattern the shader paints over the protected view, here in
    /// `lockPatternColor` over an opaque `lockBackgroundColor` base — the exact mask texture, made
    /// fully opaque. Rendered with the real shader at `closeProgress 0` (blinds cover invisible, only
    /// the mask perforation shows: pattern where `bn < fill`, transparent in the holes). Shared by the
    /// locked screen and the warm-up scan.
    private func perforatedField(size: CGSize, fill: Float) -> some View {
        ZStack {
            lockBackgroundColor
            Rectangle().fill(.black)
                .modifier(PrivacyBlindsShaderModifier(
                    size: size,
                    stripWidthPt: stripWidthPt,
                    closeProgress: 0,                 // blinds cover invisible — only the mask shows
                    stripSweep: stripSweep,
                    transition: transition,
                    viewAngle: 0,
                    directionalSweep: directionalSweep,
                    maskFillRatio: fill,
                    maskCellSize: maskCellSize,
                    maskSeed: model.maskSeed,
                    revealY: 0,
                    revealHalfHeight: 0,
                    revealFeather: 0,
                    revealProgress: 0,                // no touch reading band here
                    blueNoise: Self.blueNoise,
                    maskUseImage: 0,
                    maskColor: lockPatternColor,
                    maskImage: Self.clearPixel
                ))
        }
    }

    /// The locked state: the perforated field with the lock glyph. Tapping it prompts Face ID.
    private func lockedCover(size: CGSize) -> some View {
        perforatedField(size: size, fill: lockMaskFillRatio)
            .overlay { lockGlyph }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { model.beginUnlock(reason: unlockReason) }
    }

    /// Post-unlock "warming up": the privacy texture "calibrates" — its perforation density breathes
    /// in place while ARKit acquires the face, then it gives way to the content the moment gaze is
    /// live. Animated in place (no dimension dependence), so it works at any view size.
    private func warmingCover(size: CGSize) -> some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            let fill = Float(0.40 + 0.22 * sin(phase * 3.0))   // breathe density ~0.18 .. 0.62
            perforatedField(size: size, fill: fill)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
    }

    /// Lock icon on a tight square (8pt padding all around). Uses the bundled vector icon, template-
    /// rendered so `lockIconColor` tints it.
    private var lockGlyph: some View {
        Image("lock-icon", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 36, height: 36)
            .foregroundStyle(lockIconColor)
            .padding(8)
            .background(lockIconBackgroundColor)
    }

    private func coverLayer(size: CGSize, closeProgress: Float, viewAngle: Float,
                            revealY: Float, revealProgress: Double) -> some View {
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
                stripSweep: stripSweep,
                transition: transition,
                viewAngle: viewAngle,
                directionalSweep: directionalSweep,
                maskFillRatio: maskFillRatio,
                maskCellSize: maskCellSize,
                maskSeed: model.maskSeed,
                revealY: revealY,
                revealHalfHeight: Float(maskRevealHeight / 2),
                revealFeather: Float(maskRevealFeather),
                revealProgress: revealProgress,
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

    /// Animate the reading band open/closed — unless Reduce Motion is on, in which case snap instantly.
    /// (The pose/gaze gating itself isn't decorative motion, so it's unaffected; only this flourish is.)
    private func setRevealProgress(_ value: CGFloat, _ animation: Animation) {
        if reduceMotion {
            revealProgress = value
        } else {
            withAnimation(animation) { revealProgress = value }
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
    var stripSweep: Float
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
                .float(stripSweep),
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

// MARK: - Window gesture bridges

/// Base for a transparent view that observes touches via a recognizer attached to the *window* — so
/// it fires on touch-down without a ScrollView's `delaysContentTouches` latency and never consumes
/// touches (the content keeps scrolling/tapping). Subclasses supply the recognizer in `makeRecognizer`.
private class WindowGestureView: UIView, UIGestureRecognizerDelegate {
    private weak var attachedTo: UIView?
    private var recognizer: UIGestureRecognizer?

    /// Subclasses build their recognizer here (target/action and any config).
    func makeRecognizer() -> UIGestureRecognizer { UIGestureRecognizer() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if recognizer == nil {
            let g = makeRecognizer()
            g.cancelsTouchesInView = false   // don't steal touches from the content
            g.delegate = self
            recognizer = g
        }
        detach()
        if let window, let recognizer {
            window.addGestureRecognizer(recognizer)
            attachedTo = window
        }
    }

    /// Remove our recognizer from the window (called on teardown so they don't accumulate).
    func detach() {
        if let recognizer { attachedTo?.removeGestureRecognizer(recognizer) }
        attachedTo = nil
    }

    // Never the hit-test target → touches always pass through to the content below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Reports the touch location (or nil on lift) for the mask reading band, in the view's own space
/// (which the GeometryReader aligns with the shader's `position`).
private struct TouchObserver: UIViewRepresentable {
    var onChange: (CGPoint?) -> Void

    func makeUIView(context: Context) -> TouchObservingView {
        let view = TouchObservingView()
        view.onChange = onChange
        return view
    }
    func updateUIView(_ uiView: TouchObservingView, context: Context) { uiView.onChange = onChange }
    static func dismantleUIView(_ uiView: TouchObservingView, coordinator: ()) { uiView.detach() }
}

private final class TouchObservingView: WindowGestureView {
    var onChange: ((CGPoint?) -> Void)?

    override func makeRecognizer() -> UIGestureRecognizer {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        g.minimumPressDuration = 0       // fire on touch-down, no delay
        g.delaysTouchesBegan = false
        return g
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
}

/// Fires `onRecenter` on a two-finger triple-tap — a deliberate, uncommon gesture that won't collide
/// with normal taps/scrolls.
private struct RecenterGesture: UIViewRepresentable {
    var onRecenter: () -> Void

    func makeUIView(context: Context) -> RecenterView {
        let view = RecenterView()
        view.onRecenter = onRecenter
        return view
    }
    func updateUIView(_ uiView: RecenterView, context: Context) { uiView.onRecenter = onRecenter }
    static func dismantleUIView(_ uiView: RecenterView, coordinator: ()) { uiView.detach() }
}

private final class RecenterView: WindowGestureView {
    var onRecenter: (() -> Void)?

    override func makeRecognizer() -> UIGestureRecognizer {
        let g = UITapGestureRecognizer(target: self, action: #selector(fire))
        g.numberOfTouchesRequired = 2
        g.numberOfTapsRequired = 3
        return g
    }

    @objc private func fire() { onRecenter?() }
}
