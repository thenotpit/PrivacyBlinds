//
//  PrivacyBlindsModifier.swift
//  PrivacyBlinds
//
//  The ViewModifier behind `.privacyBlinds(...)`. It owns the motion subscription + reading-pose
//  capture, maps device deviation → closeProgress (with a soft open/close band) + a signed parallax
//  viewAngle, and drives the `privacyBlinds` layerEffect on an opaque cover overlay.
//

import SwiftUI

// MARK: - Motion model

/// Subscribes to the shared motion stream, captures the reading pose on first reading (and on
/// `recenter()`), and publishes the signed roll deviation from that pose. Held by the modifier as
/// `@State` so its lifetime tracks the view.
@MainActor
@Observable
final class PrivacyLensModel {
    /// Signed roll deviation from the reading pose, in radians.
    private(set) var deviation: Float = 0

    private var referenceAngle: Float?
    private var needsCapture = true
    private var token: UUID?

    func start() {
        needsCapture = true
        guard token == nil else { return }
        token = MotionManager.shared.addListener { [weak self] angle, _ in
            // MotionManager always fans out on the main thread (it dispatches to main / the
            // simulation timer fires on main), so it is safe to assume main-actor isolation here
            // and update synchronously — no async hop, no motion lag.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.needsCapture {
                    self.referenceAngle = angle
                    self.needsCapture = false
                }
                guard let ref = self.referenceAngle else { return }
                self.deviation = wrapToPi(angle - ref)
            }
        }
    }

    /// Re-capture the current pose as the reading pose on the next motion reading.
    func recenter() { needsCapture = true }

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
    // Pose gate (degrees): reading pose → 0; |deviation| ≥ closeThreshold → fully covered.
    var openThresholdDeg: Float = 8
    var closeThresholdDeg: Float = 16
    var maxViewAngleDeg: Float = 20
    var onStateChange: ((Bool) -> Void)?

    @State private var model = PrivacyLensModel()

    /// 0 = fully open/revealed .. 1 = fully closed/covered.
    private var closeProgress: Float {
        let open = openThresholdDeg * .pi / 180
        let close = closeThresholdDeg * .pi / 180
        return smoothstep(open, close, abs(model.deviation))
    }

    /// Signed view angle (radians) that drives the closing-sweep direction.
    private var viewAngle: Float {
        let maxV = maxViewAngleDeg * .pi / 180
        return max(-maxV, min(maxV, model.deviation))
    }

    public func body(content: Content) -> some View {
        // Reading closeProgress here establishes the state/observation dependencies for re-render.
        let progress = closeProgress
        let angle = viewAngle
        let closed = enabled && progress > 0.5

        return content
            .overlay {
                if enabled {
                    GeometryReader { geo in
                        coverLayer(size: geo.size, closeProgress: progress, viewAngle: angle)
                    }
                    .ignoresSafeArea()
                    // Open ⇒ touches pass through to content; closed ⇒ cover also locks interaction.
                    .allowsHitTesting(closed)
                }
            }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: closed) { _, newValue in onStateChange?(newValue) }
    }

    @ViewBuilder
    private func coverLayer(size: CGSize, closeProgress: Float, viewAngle: Float) -> some View {
        coverBase
            .layerEffect(
                ShaderLibrary.bundle(.module).privacyBlinds(
                    .float2(size),
                    .float(Float(stripWidthPt)),
                    .float(closeProgress),
                    .float(lenticuleSweep),
                    .float(transition),
                    .float(viewAngle),
                    .float(directionalSweep)
                ),
                // The shader samples each pixel 1:1 (no translation), so it never reaches outside
                // the cover — zero sample offset.
                maxSampleOffset: .zero
            )
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
