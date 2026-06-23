//
//  EyeTracker.swift
//  PrivacyBlinds
//
//  Optional gaze input for the privacy lens. Runs an ARKit face-tracking session (TrueDepth front
//  camera) and publishes a coarse gaze estimate — roughly where the user is looking relative to the
//  device — so the lens can close when they look away. Everything stays on-device; no frames are
//  stored or transmitted. Opt-in: only started when a `privacyBlinds(..., eyeTracking: true)` view
//  is on screen.
//

import ARKit
import simd
import Foundation

/// One frame of gaze state.
struct GazeReading: Sendable {
    /// Whether a face is currently tracked. When false, the session is running but no usable face is
    /// in view (treat as "looking away").
    var isTracked: Bool
    /// Whether gaze input is unavailable at all (no TrueDepth camera, or camera permission denied) —
    /// the lens should fall back to pose-only gating, NOT force itself closed.
    var unavailable: Bool
    /// Unit gaze direction in camera/world space — head orientation AND eye direction combined, so a
    /// head turn moves it just as an eye movement does. The lens measures its angle against a captured
    /// "looking at the screen" baseline.
    var gazeDir: SIMD3<Float>
    /// Device pose derived from ARKit (gravity-aligned), used while the AR session is running because
    /// it suspends a separate CMMotionManager. Same conventions as `MotionManager` (radians).
    var roll: Float
    var pitch: Float
    /// Both eyes closed — gaze estimate is unreliable mid-blink, so consumers hold their last state.
    var isBlinking: Bool
    /// Angle (radians) between the gaze and the direction from the face to the device — ~0 when
    /// looking straight at the device, growing as the gaze leaves the screen. Used to validate that a
    /// "looking at screen" baseline is captured only when the user really is looking at the screen.
    var screenAngle: Float
    /// Signed horizontal gaze offset (radians) from the direction-to-device (left/right). Used to
    /// reject a skewed baseline (a slight turn at enable time) and to drive the closing sweep side.
    var horizontalOffset: Float
    /// ARKit's ambient light estimate (lux), or -1 when unknown. The gaze gate decides reliability
    /// from this against its (configurable) low-light thresholds, and the host can surface it.
    var ambientLux: Double

    static let unsupported = GazeReading(isTracked: false, unavailable: true, gazeDir: .zero,
                                         roll: 0, pitch: 0, isBlinking: false, screenAngle: 0,
                                         horizontalOffset: 0, ambientLux: -1)
}

/// Abstraction over the gaze stream so the lens model can be driven (and tested) without ARKit.
/// `EyeTracker` is the production implementation.
protocol GazeSource: AnyObject {
    @discardableResult func addListener(_ listener: @escaping (GazeReading) -> Void) -> UUID
    func removeListener(_ id: UUID)
}

/// Shared front-camera gaze stream. `@unchecked Sendable`: `listeners` and the session are only
/// touched on the main thread (the ARSession delegate queue is set to `.main`), and subscribe/
/// unsubscribe happen from the main actor.
final class EyeTracker: NSObject, ARSessionDelegate, GazeSource, @unchecked Sendable {

    static let shared = EyeTracker()

    /// True only on devices with a TrueDepth front camera (iPhone X and later).
    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    private let session = ARSession()
    private var listeners: [UUID: (GazeReading) -> Void] = [:]
    private var running = false

    private override init() { super.init() }

    @discardableResult
    func addListener(_ listener: @escaping (GazeReading) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        if !running { start() }
        return id
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
        if listeners.isEmpty { stop() }
    }

    private func start() {
        guard EyeTracker.isSupported else {
            // No TrueDepth camera — report unavailable so the lens falls back to pose-only gating.
            notify(.unsupported)
            return
        }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.worldAlignment = .gravity   // so the camera transform is gravity-referenced for pose
        session.delegate = self
        session.delegateQueue = .main
        // Running the session prompts for camera permission the first time (NSCameraUsageDescription).
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        running = true
    }

    private func stop() {
        session.pause()
        running = false
    }

    private func notify(_ reading: GazeReading) {
        for listener in listeners.values { listener(reading) }
    }

    // MARK: ARSessionDelegate (called on .main)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // --- Device pose from ARKit (gravity-aligned) ---
        // Gravity in the device frame = Rᵀ · worldDown, with worldDown = (0,-1,0). For the camera
        // transform R (device→world), that's the negated Y-row, i.e. the .y of each rotation column.
        // Then the same roll/pitch formulas MotionManager uses, so values are interchangeable.
        let m = frame.camera.transform
        let gx = -m.columns.0.y
        let gy = -m.columns.1.y
        let gz = -m.columns.2.y
        let roll = asin(max(-1, min(1, gx)))
        let pitch = atan2(-gz, -gy)

        // Ambient light (lux); the gaze gate decides reliability against its configurable thresholds.
        let ambientLux = frame.lightEstimate?.ambientIntensity ?? -1

        // --- Gaze (when a face is present), expressed in the DEVICE frame ---
        // Combine head orientation + eye direction into a world-space gaze ray, then rotate it into
        // the device frame (worldToDevice = camRotᵀ). Device-relative is the key: rotating your whole
        // body turns the camera and face together, leaving this unchanged (you're still looking at the
        // screen), while turning your head relative to the device still moves it.
        if let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked {
            let t = face.transform
            let facePos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let look4 = t * simd_float4(face.lookAtPoint, 1)
            let lookWorld = simd_float3(look4.x, look4.y, look4.z)
            let gazeWorld = simd_normalize(lookWorld - facePos)
            let camRot = simd_float3x3(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                       SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                       SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            let gazeDir = simd_normalize(camRot.transpose * gazeWorld)

            // World angle between the gaze and the direction from the face to the device (camera).
            // ~0 when looking at the device; large when looking away. Rotation-invariant (both rays
            // rotate together with the body), so it's a reliable "is the user looking at the screen?".
            let cameraPos = simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let toDevice = simd_normalize(cameraPos - facePos)
            let screenAngle = acos(max(-1, min(1, simd_dot(gazeWorld, toDevice))))

            // Signed horizontal (azimuth) difference between gaze and the device direction, in the
            // device frame. The shared atan2 formula cancels axis-sign conventions in the difference.
            let toDeviceDir = simd_normalize(camRot.transpose * toDevice)
            let horizontalOffset = wrapToPi(atan2(gazeDir.x, gazeDir.z) - atan2(toDeviceDir.x, toDeviceDir.z))

            let bs: (ARFaceAnchor.BlendShapeLocation) -> Float = { face.blendShapes[$0]?.floatValue ?? 0 }
            let isBlinking = (bs(.eyeBlinkLeft) + bs(.eyeBlinkRight)) * 0.5 > Tuning.blinkThreshold

            notify(GazeReading(isTracked: true, unavailable: false, gazeDir: gazeDir, roll: roll, pitch: pitch,
                               isBlinking: isBlinking, screenAngle: screenAngle, horizontalOffset: horizontalOffset,
                               ambientLux: ambientLux))
        } else {
            notify(GazeReading(isTracked: false, unavailable: false, gazeDir: .zero, roll: roll, pitch: pitch,
                               isBlinking: false, screenAngle: 0, horizontalOffset: 0, ambientLux: ambientLux))
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Most commonly camera permission denied — fall back to pose-only, don't force closed.
        notify(.unsupported)
    }
}
