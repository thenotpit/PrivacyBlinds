//
//  MotionManager.swift
//  PrivacyBlinds
//
//  Ported from Lenticular Panel as-is. Produces a drift-free roll about the device long axis (Y):
//  gyro quaternion integration (unbounded `accumulatedAngle`) corrected in real time by a
//  gravity complementary filter, so body turns and gyro drift don't shift the zero. The privacy
//  lens reads this stream and computes deviation from a captured reading pose (see PrivacyBlindsModifier).
//
//  Only change from the parent: `LenticularSettings.shared.gravityCorrectionGain` is replaced by
//  the package-local `gravityCorrectionGain` property (tunable from the main actor).
//

import Foundation
import CoreMotion
import simd
import QuartzCore

/// One shared CoreMotion stream that every `privacyBlinds` overlay reads from.
///
/// `@unchecked Sendable`: the gyro/gravity integration state is only ever touched on the internal
/// motion queue; the `listeners` map is only touched on the main actor (subscribe/unsubscribe and
/// the main-thread fan-out). `gravityCorrectionGain` is a single `Float` tuning knob written from
/// main and read on the motion queue — a benign data race for a smoothing coefficient.
final class MotionManager: @unchecked Sendable {

    static let shared = MotionManager()

    private let motionManager = CMMotionManager()

    // Cards/overlays register here to receive (angle, velocity) updates; one stream feeds them all.
    private var listeners: [UUID: (Float, Float) -> Void] = [:]

    // Gravity complementary-filter correction strength per update (was LenticularSettings-driven).
    var gravityCorrectionGain: Float = 0.04

    private var lastAngle: Float = 0.0

    // Continuous unbounded roll from quaternion integration.
    private var accumulatedAngle: Float = 0.0
    private var previousQuaternion: simd_quatf? = nil

    // Complementary filter: gyro drives responsiveness; gravity gently corrects drift and body-turn
    // shifts, weighted by how well gravity can observe the tilt in the current pose. referenceGravityTilt
    // anchors the gravity reading to the gyro's center, captured lazily the first time gravity is clearly
    // observable so launching while upright doesn't bake in a bad zero.
    private var referenceGravityTilt: Float? = nil

    private var rollVelocity: Float = 0.0
    private var smoothedVelocity: Float = 0.0

    // Test mode - use simulated oscillating motion instead of real device motion.
    var useSimulatedMotion: Bool = false
    private var simulationStartTime: CFTimeInterval = 0
    private var simulationTimer: Timer?

    private init() {
        setupMotionUpdates()
    }

    /// Register for motion updates. Keep the returned token and pass it to `removeListener` later.
    @discardableResult
    func addListener(_ listener: @escaping (Float, Float) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func notifyListeners(angle: Float, velocity: Float) {
        for listener in listeners.values { listener(angle, velocity) }
    }

    private func setupMotionUpdates() {
        if useSimulatedMotion {
            setupSimulatedMotion()
            return
        }

        guard motionManager.isDeviceMotionAvailable else {
            print("Device motion not available")
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz for smooth motion
        motionManager.showsDeviceMovementDisplay = false

        let motionQueue = OperationQueue()
        motionQueue.name = "PrivacyBlinds.MotionQueue"
        motionQueue.maxConcurrentOperationCount = 1

        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self,
                  let motion = motion,
                  error == nil else {
                return
            }

            // Quaternion from CoreMotion (using -q.x for consistency with ScreenNormal2Metal).
            let q = motion.attitude.quaternion
            let currentQuat = simd_quatf(ix: Float(-q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))

            // Gravity-referenced roll about the device long axis (Y), drift-free. gx = sin(roll):
            // gravity's lateral component depends ONLY on left/right roll — pitch and yaw leave gx
            // untouched. observability = how far gravity is off the Y axis (0 when the long axis points
            // straight up/down, where roll about Y is unobservable).
            let g = motion.gravity
            let gx = Float(max(-1.0, min(1.0, g.x)))
            let gravityTilt = asin(gx)
            let observability = Float(sqrt(g.x * g.x + g.z * g.z))

            // First reading - just store the quaternion.
            guard let previousQuat = self.previousQuaternion else {
                self.previousQuaternion = currentQuat
                self.accumulatedAngle = 0.0
                return
            }

            // --- Gyro accumulation: integrate the roll component about device Y ---------
            let deltaQuat = currentQuat * previousQuat.inverse
            let w = simd_clamp(deltaQuat.real, -1.0, 1.0)
            let rotationAngle = 2.0 * acos(w)

            // Dead zone + roll-axis gating: only accumulate clear roll motion (skip noise/pitch/spin).
            let rotationThreshold: Float = 0.001 // ~0.057 degrees
            if rotationAngle > rotationThreshold {
                let axis = deltaQuat.imag
                let axisLength = simd_length(axis)
                if axisLength > 0.0001 {
                    let normalizedAxis = axis / axisLength
                    let rollComponent = normalizedAxis.y // Y-axis = top/bottom; isolates left/right roll
                    let rollThreshold: Float = 0.1
                    if abs(rollComponent) > rollThreshold {
                        let rollAngle = rotationAngle * rollComponent

                        let updateInterval: Float = 1.0 / 60.0
                        self.rollVelocity = abs(rollAngle) / updateInterval
                        let velocitySmoothingFactor: Float = 0.3
                        self.smoothedVelocity = velocitySmoothingFactor * self.rollVelocity + (1.0 - velocitySmoothingFactor) * self.smoothedVelocity

                        self.accumulatedAngle += rollAngle
                        self.previousQuaternion = currentQuat
                    }
                }
            }

            // --- Gravity correction (complementary filter): pull the gyro angle toward the gravity
            // reading, scaled by observability. Turns are rotation about vertical, which leaves gravity
            // unchanged, so this cancels drift + turn-shift in real time, and fades to pure gyro upright.
            // Fade the correction out once the screen faces down (phone overhead), where the roll-about-Y
            // model no longer matches the viewing gesture. g.z > 0 means gravity points into the screen.
            let gz = Float(g.z)
            let zt = max(0.0, min(1.0, (gz - 0.4) / (0.0 - 0.4))) // 1 when screen up (gz≤0), 0 when gz≥0.4
            let screenWeight = zt * zt * (3.0 - 2.0 * zt)

            if self.referenceGravityTilt == nil && observability > 0.5 && gz < 0.2 {
                // Anchor lazily once gravity is clearly trustworthy AND the screen faces up.
                self.referenceGravityTilt = gravityTilt - self.accumulatedAngle
            }
            if let reference = self.referenceGravityTilt {
                var diff = (gravityTilt - reference) - self.accumulatedAngle
                if diff > .pi { diff -= 2 * .pi }          // shortest-path wrap
                if diff < -.pi { diff += 2 * .pi }
                // Trust gravity only when it clearly sees the tilt. Ramp in with a smoothstep on
                // observability, gate by screen-facing, and hard-clamp so nothing can flip rapidly.
                let t = max(0.0, min(1.0, (observability - 0.4) / 0.3))
                let obsWeight = t * t * (3.0 - 2.0 * t)
                let maxStep: Float = 0.015 // rad per update (~0.85°)
                let gain = self.gravityCorrectionGain
                let correction = max(-maxStep, min(maxStep, diff * gain * obsWeight * screenWeight))
                self.accumulatedAngle += correction
            }

            // Broadcast every frame so the gravity correction is reflected continuously.
            let outputAngle = self.accumulatedAngle
            let outputVelocity = self.smoothedVelocity
            DispatchQueue.main.async { [weak self] in
                self?.notifyListeners(angle: outputAngle, velocity: outputVelocity)
            }
        }
    }

    private func setupSimulatedMotion() {
        simulationStartTime = CACurrentMediaTime()

        // 60 Hz update rate. Oscillates the roll so the lens can be exercised in the simulator.
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let currentTime = CACurrentMediaTime()
            let elapsed = Float(currentTime - self.simulationStartTime)

            let cycleDuration: Float = 3.0
            let oscillationPeriod: Float = 10.0

            let periodIndex = Int(elapsed / oscillationPeriod)
            let timeInPeriod = elapsed.truncatingRemainder(dividingBy: oscillationPeriod)
            let isReversing = periodIndex % 2 == 1

            let peakAngle = oscillationPeriod / cycleDuration
            let simulatedAngle: Float
            if isReversing {
                simulatedAngle = peakAngle - timeInPeriod / cycleDuration
            } else {
                simulatedAngle = timeInPeriod / cycleDuration
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let angleChange = abs(simulatedAngle - self.lastAngle)
                if angleChange > 0.001 {
                    self.lastAngle = simulatedAngle
                    self.notifyListeners(angle: simulatedAngle, velocity: 0.0)
                }
            }
        }
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
        simulationTimer?.invalidate()
        simulationTimer = nil
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}
