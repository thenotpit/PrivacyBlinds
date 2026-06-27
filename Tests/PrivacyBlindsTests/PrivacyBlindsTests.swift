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
                         screenAngle: Float = 0.1, horizontalOffset: Float = 0,
                         lux: Double = 1000) -> GazeReading {
        GazeReading(isTracked: tracked, unavailable: false, gazeDir: simd_normalize(dir),
                    roll: 0, pitch: 0, isBlinking: blinking, screenAngle: screenAngle,
                    horizontalOffset: horizontalOffset, ambientLux: lux)
    }

    @Test func lookingAtBaselineIsOpen() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))     // captures baseline, angle 0
        #expect(gate.away == 0)
    }

    @Test func lookingAwaySlamsClosed() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))                          // baseline
        gate.apply(reading(SIMD3(sin(0.5), 0, cos(0.5))))           // ~28° away → past closeAngle
        #expect(gate.away == 1)                                     // binary slam, not partial
    }

    @Test func closeIsBinaryNotAnalog() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))                          // baseline, open
        // An angle inside the hysteresis band (between open and close) holds the previous state (open),
        // never a partial value — so a slow eye-roll can't ride the cover partway.
        gate.apply(reading(SIMD3(sin(0.28), 0, cos(0.28))))        // ~16°, between 0.20 and 0.38
        #expect(gate.away == 0)
    }

    @Test func blinkHoldsState() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))
        gate.apply(reading(SIMD3(sin(0.5), 0, cos(0.5))))           // away == 1
        let before = gate.away
        gate.apply(reading(SIMD3(0, 0, 1), blinking: true))        // blink → ignored
        #expect(gate.away == before)
    }

    @Test func lowLightSuspendsGaze() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))                          // good light, baseline
        gate.apply(reading(SIMD3(sin(0.5), 0, cos(0.5)), lux: 100)) // dark + looking away
        #expect(gate.away == 0)                                     // suspended → pose-only, not closed
    }

    @Test func lostTrackingReadsAsAway() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))
        gate.apply(reading(SIMD3(0, 0, 1), tracked: false))
        #expect(gate.away == 1)
    }

    @Test func capturesBaselineOnlyWhenLookingAtScreen() {
        var gate = GazeGate()
        // Enabled while looking away: no baseline captured yet → stay OPEN through warm-up (avoids
        // both the black flash and capturing a skewed/inverted baseline).
        gate.apply(reading(SIMD3(1, 0, 0), screenAngle: 1.2))
        #expect(gate.away == 0)
        // Look at the screen → baseline captured here → open.
        gate.apply(reading(SIMD3(0, 0, 1), screenAngle: 0.1))
        #expect(gate.away == 0)
        // Now look away → closes. Correctly oriented (not inverted), proving the baseline was the
        // looking-at-screen frame, not the looking-away one.
        gate.apply(reading(SIMD3(sin(0.5), 0, cos(0.5))))
        #expect(gate.away == 1)
    }

    @Test func defersBaselineUntilHorizontallyCentered() {
        var gate = GazeGate()
        // Within the cone but horizontally turned → skewed; defer capture, stay open through warm-up.
        gate.apply(reading(SIMD3(0.3, 0, 1), screenAngle: 0.2, horizontalOffset: 0.4))
        #expect(gate.away == 0)
        // Now horizontally centered → captures an unskewed baseline → open.
        gate.apply(reading(SIMD3(0, 0, 1), screenAngle: 0.12, horizontalOffset: 0.0))
        #expect(gate.away == 0)
        // And a clear look-away from that unskewed baseline closes it.
        gate.apply(reading(SIMD3(sin(0.5), 0, cos(0.5))))
        #expect(gate.away == 1)
    }

    @Test func staysOpenWhileTrackingNotYetAcquired() {
        var gate = GazeGate()
        // Camera warm-up: not tracked yet, before any baseline → open (no flash on start/unlock).
        gate.apply(reading(SIMD3(0, 0, 1), tracked: false))
        #expect(gate.away == 0)
    }

    @Test func readyTracksWarmUp() {
        var gate = GazeGate()
        #expect(gate.ready == false)                                   // fresh → still warming up
        gate.apply(reading(SIMD3(0, 0, 1), tracked: false))            // camera not acquired yet
        #expect(gate.ready == false)                                   // still warming
        gate.apply(reading(SIMD3(0, 0, 1)))                            // baseline captured → live
        #expect(gate.ready == true)
    }

    @Test func lowLightEndsWarmUp() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1), lux: 100))                  // too dark → pose-only is live
        #expect(gate.ready == true)
    }

    @Test func recenterKeepsReadyButResetClears() {
        var gate = GazeGate()
        gate.apply(reading(SIMD3(0, 0, 1)))                            // become ready
        #expect(gate.ready == true)
        gate.recenter()                                                // mid-session re-center
        #expect(gate.ready == true)                                    // must NOT replay the warm-up
        gate.reset()                                                   // full stop
        #expect(gate.ready == false)
    }
}

/// Authenticated-gaze lock/unlock/re-lock state machine, driven with fakes.
@MainActor
@Suite struct AuthGazeTests {

    final class FakePose: PoseSource {
        var listener: ((MotionReading) -> Void)?
        func addListener(_ listener: @escaping (MotionReading) -> Void) -> UUID { self.listener = listener; return UUID() }
        func removeListener(_ id: UUID) { listener = nil }
    }
    final class FakeGaze: GazeSource {
        var listener: ((GazeReading) -> Void)?
        func addListener(_ listener: @escaping (GazeReading) -> Void) -> UUID { self.listener = listener; return UUID() }
        func removeListener(_ id: UUID) { listener = nil }
    }
    final class FakeAuth: Authenticating {
        var succeed = true
        var autoComplete = true                  // false → hold the prompt open until finish()
        private(set) var calls = 0
        private var pending: ((Bool) -> Void)?
        func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
            calls += 1
            if autoComplete { completion(succeed) } else { pending = completion }
        }
        func finish() { pending?(succeed); pending = nil }
    }

    private func makeModel(_ auth: FakeAuth = FakeAuth()) -> PrivacyLensModel {
        PrivacyLensModel(pose: FakePose(), gaze: FakeGaze(), authenticator: auth)
    }

    @Test func startsLockedInAuthenticatedMode() {
        let model = makeModel()
        model.enterAuthenticatedMode(minLux: 0, resumeLux: 0)
        #expect(model.lockState == .locked)
    }

    @Test func unlocksOnAuthSuccess() {
        let auth = FakeAuth()
        let model = makeModel(auth)
        model.enterAuthenticatedMode(minLux: 0, resumeLux: 0)
        model.beginUnlock(reason: "x")
        #expect(auth.calls == 1)
        #expect(model.lockState == .unlocked)
    }

    @Test func staysLockedOnAuthFailure() {
        let auth = FakeAuth(); auth.succeed = false
        let model = makeModel(auth)
        model.enterAuthenticatedMode(minLux: 0, resumeLux: 0)
        model.beginUnlock(reason: "x")
        #expect(model.lockState == .locked)
    }

    @Test func relockReturnsToLocked() {
        let model = makeModel()
        model.enterAuthenticatedMode(minLux: 0, resumeLux: 0)
        model.beginUnlock(reason: "x")
        #expect(model.lockState == .unlocked)
        model.relock()
        #expect(model.lockState == .locked)
    }

    @Test func unlockIgnoredWhenNotLocked() {
        let auth = FakeAuth()
        let model = makeModel(auth)
        model.enterAuthenticatedMode(minLux: 0, resumeLux: 0)
        model.beginUnlock(reason: "x")        // → unlocked
        model.beginUnlock(reason: "x")        // ignored (already unlocked)
        #expect(auth.calls == 1)
        #expect(model.lockState == .unlocked)
    }

    // MARK: Synced unlock (syncGroup)

    /// Two models sharing a coordinator + group id, each with its own fakes.
    private func makeGroup(_ coord: SyncGroupCoordinator, auth: FakeAuth = FakeAuth()) -> PrivacyLensModel {
        PrivacyLensModel(pose: FakePose(), gaze: FakeGaze(), authenticator: auth, syncCoordinator: coord)
    }

    @Test func syncedGroupUnlocksTogether() {
        let coord = SyncGroupCoordinator()
        let a = makeGroup(coord), b = makeGroup(coord)
        a.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        b.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        a.beginUnlock(reason: "x")
        #expect(a.lockState == .unlocked)
        #expect(b.lockState == .unlocked)   // unlocked via sync, never prompted itself
    }

    @Test func differentGroupsStayIsolated() {
        let coord = SyncGroupCoordinator()
        let a = makeGroup(coord), b = makeGroup(coord)
        a.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "a")
        b.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "b")
        a.beginUnlock(reason: "x")
        #expect(a.lockState == .unlocked)
        #expect(b.lockState == .locked)
    }

    @Test func nilGroupStaysIndependent() {
        let coord = SyncGroupCoordinator()
        let a = makeGroup(coord), b = makeGroup(coord)
        a.enterAuthenticatedMode(minLux: 0, resumeLux: 0)   // nil group
        b.enterAuthenticatedMode(minLux: 0, resumeLux: 0)
        a.beginUnlock(reason: "x")
        #expect(a.lockState == .unlocked)
        #expect(b.lockState == .locked)
    }

    @Test func syncedRelockLocksGroup() {
        let coord = SyncGroupCoordinator()
        let a = makeGroup(coord), b = makeGroup(coord)
        a.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        b.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        a.beginUnlock(reason: "x")
        #expect(b.lockState == .unlocked)
        a.relock()
        #expect(a.lockState == .locked)
        #expect(b.lockState == .locked)     // re-locked via sync
    }

    @Test func newcomerJoinsUnlockedGroup() {
        let coord = SyncGroupCoordinator()
        let a = makeGroup(coord)
        a.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        a.beginUnlock(reason: "x")
        #expect(a.lockState == .unlocked)
        // A second view appears while the group is already unlocked.
        let b = makeGroup(coord)
        b.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        #expect(b.lockState == .unlocked)   // joined unlocked, no prompt
    }

    @Test func secondPromptSuppressedWhileGroupAuthenticating() {
        let coord = SyncGroupCoordinator()
        let authA = FakeAuth(); authA.autoComplete = false   // hold A's sheet open
        let authB = FakeAuth()
        let a = makeGroup(coord, auth: authA), b = makeGroup(coord, auth: authB)
        a.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        b.enterAuthenticatedMode(minLux: 0, resumeLux: 0, syncGroup: "g")
        a.beginUnlock(reason: "x")          // A's prompt is up, not yet resolved
        b.beginUnlock(reason: "x")          // suppressed — the group is already authenticating
        #expect(authB.calls == 0)
        authA.finish()                      // A succeeds → unlocks the whole group
        #expect(a.lockState == .unlocked)
        #expect(b.lockState == .unlocked)
    }
}
