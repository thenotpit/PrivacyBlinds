import Testing
@testable import PrivacyBlinds

/// The pose math that drives the lens. Runs on an iOS destination (the module is iOS-only).
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
