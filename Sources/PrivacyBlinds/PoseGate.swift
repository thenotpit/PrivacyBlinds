//
//  PoseGate.swift
//  PrivacyBlinds
//
//  Pure pose-gating logic: settle-on-stillness anchoring of the reading pose, then deviation from it.
//  No device or framework dependencies — feed it `(roll, pitch, now)` samples and read the deviations,
//  which makes the whole state machine unit-testable without CoreMotion or ARKit.
//

import Foundation

struct PoseGate {
    var stillDelta: Float = Tuning.stillDelta
    var settleDuration: TimeInterval = Tuning.settleDuration
    var maxPendingDuration: TimeInterval = Tuning.maxPendingDuration

    /// Signed deviations from the anchored reading pose, in radians (0 until an anchor is captured).
    private(set) var rollDeviation: Float = 0
    private(set) var pitchDeviation: Float = 0
    private(set) var hasAnchor = false

    private var referenceRoll: Float = 0
    private var referencePitch: Float = 0
    private var needsCapture = true
    private var lastRoll: Float?
    private var lastPitch: Float?
    private var stillSince: TimeInterval?
    private var pendingSince: TimeInterval?

    /// Re-anchor on the next settle (or after the safety timeout). Keeps measuring against the previous
    /// anchor until then, so the cover stays closed mid-reposition.
    mutating func reset() {
        needsCapture = true
        stillSince = nil
        pendingSince = nil
        lastRoll = nil
        lastPitch = nil
    }

    mutating func apply(roll: Float, pitch: Float, now: TimeInterval) {
        // Stillness: how long roll+pitch have stayed under the threshold.
        if let lr = lastRoll, let lp = lastPitch {
            let moved = abs(wrapToPi(roll - lr)) + abs(wrapToPi(pitch - lp))
            if moved < stillDelta {
                if stillSince == nil { stillSince = now }
            } else {
                stillSince = nil
            }
        }
        lastRoll = roll
        lastPitch = pitch

        if needsCapture {
            if pendingSince == nil { pendingSince = now }
            let settled = stillSince.map { now - $0 >= settleDuration } ?? false
            let timedOut = now - (pendingSince ?? now) >= maxPendingDuration
            if settled || timedOut {
                referenceRoll = roll
                referencePitch = pitch
                needsCapture = false
                hasAnchor = true
            }
        }

        guard hasAnchor else { return }
        rollDeviation = wrapToPi(roll - referenceRoll)
        pitchDeviation = wrapToPi(pitch - referencePitch)
    }
}
