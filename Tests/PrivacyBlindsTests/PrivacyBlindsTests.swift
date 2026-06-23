import Testing
import Foundation
import simd
@testable import PrivacyBlinds

/// The numeric helpers. Runs on an iOS destination (the module is iOS-only).
@Suite struct PrivacyBlindsMathTests {

    @Test func wrapToPiFoldsIntoRange() {
        #expect(abs(wrapToPi(0)) < 1e-6)
        #expect(abs(wrapToPi(2 * .pi)) < 1e-5)              // a full turn folds back to ~0
        #expect(wrapToPi(1.5 * .pi) < 0)                    // 270° reads as a negative roll
        #expect(abs(wrapToPi(1.5 * .pi) - (-.pi / 2)) < 1e-5)
    }

    @Test func smoothstepClampsAtTheEdges() {
        #expect(smoothstep(8, 16, 4) == 0)                  // below the open threshold → fully open
        #expect(smoothstep(8, 16, 20) == 1)                 // past the close threshold → fully closed
    }

    @Test func smoothstepRampsMonotonically() {
        #expect(abs(smoothstep(8, 16, 12) - 0.5) < 1e-5)    // midpoint → halfway closed
        #expect(smoothstep(8, 16, 10) < smoothstep(8, 16, 14))
    }
}

/// Settle-on-stillness anchoring + deviation.
@Suite struct PoseGateTests {

    /// Feed a sample, advancing time by `dt` each call.
    private func feed(_ gate: inout PoseGate, roll: Float, pitch: Float, from t: TimeInterval,
                      count: Int, dt: TimeInterval) -> TimeInterval {
        var now = t
        for _ in 0..<count { gate.apply(roll: roll, pitch: pitch, now: now); now += dt }
        return now
    }

    @Test func noDeviationBeforeAnchor() {
        var gate = PoseGate()
        gate.apply(roll: 0.5, pitch: 0.1, now: 0)            // first sample, not yet settled
        #expect(gate.hasAnchor == false)
        #expect(gate.rollDeviation == 0)
        #expect(gate.pitchDeviation == 0)
    }

    @Test func anchorsAfterHoldingStill() {
        var gate = PoseGate()
        // Hold still well past the settle duration.
        _ = feed(&gate, roll: 0.5, pitch: 0.1, from: 0, count: 30, dt: 1.0 / 60.0)
        #expect(gate.hasAnchor)
        #expect(abs(gate.rollDeviation) < 1e-6)              // at the anchor → ~0
        // Now tilt away from the anchor.
        gate.apply(roll: 0.7, pitch: 0.1, now: 1.0)
        #expect(abs(gate.rollDeviation - 0.2) < 1e-5)
    }

    @Test func anchorsViaTimeoutEvenIfNeverStill() {
        var gate = PoseGate()
        var now: TimeInterval = 0
        var roll: Float = 0
        // Keep moving (never still) for longer than the safety timeout.
        while now < gate.maxPendingDuration + 0.1 {
            roll += 0.1
            gate.apply(roll: roll, pitch: 0, now: now)
            now += 1.0 / 60.0
        }
        #expect(gate.hasAnchor)   // forced by the timeout
    }

    @Test func resetReanchorsToNewPose() {
        var gate = PoseGate()
        _ = feed(&gate, roll: 0.0, pitch: 0.0, from: 0, count: 30, dt: 1.0 / 60.0)
        #expect(gate.hasAnchor)
        gate.reset()
        // Settle at a new pose; deviation should re-zero there.
        _ = feed(&gate, roll: 1.0, pitch: 0.0, from: 1.0, count: 30, dt: 1.0 / 60.0)
        #expect(abs(gate.rollDeviation) < 1e-6)
    }
}

/// Gaze close amount from the baseline, blink hold, and tracking loss.
@Suite struct GazeGateTests {

    private func reading(_ dir: SIMD3<Float>, tracked: Bool = true, blinking: Bool = false,
                         screenAngle: Float = 0.1) -> GazeReading {
        GazeReading(isTracked: tracked, unavailable: false, gazeDir: simd_normalize(dir),
                    roll: 0, pitch: 0, isBlinking: blinking, screenAngle: screenAngle)
    }

    @Test func lookingAtBaselineIsOpen() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))     // captures baseline, angle 0
        #expect(gate.away == 0)
    }

    @Test func lookingAwayCloses() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))                          // baseline
        gate.apply(reading(SIMD3(sin(0.5), 0, cos(0.5))))           // ~28° away → past closeAngle
        #expect(gate.away > 0.9)
    }

    @Test func blinkHoldsState() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))
        gate.apply(reading(SIMD3(sin(0.5), 0, cos(0.5))))           // away ~1
        let before = gate.away
        gate.apply(reading(SIMD3(0, 0, 1), blinking: true))        // blink → ignored
        #expect(gate.away == before)
    }

    @Test func lostTrackingReadsAsAway() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))
        gate.apply(reading(SIMD3(0, 0, 1), tracked: false))
        #expect(gate.away == 1)
    }

    @Test func enablingWhileLookingAwayStaysClosedThenAnchorsOnScreen() {
        var gate = GazeGate()
        // Enabled while looking away: large screenAngle → no baseline captured, stays closed.
        gate.apply(reading(SIMD3(1, 0, 0), screenAngle: 1.2))
        #expect(gate.away == 1)
        // Look back at the screen: small screenAngle → baseline captured here → open.
        gate.apply(reading(SIMD3(0, 0, 1), screenAngle: 0.1))
        #expect(gate.away == 0)
    }
}
