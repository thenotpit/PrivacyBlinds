//
//  GazeGate.swift
//  PrivacyBlinds
//
//  Pure gaze-gating logic: angle of the combined head+eye gaze from a captured "looking at the
//  screen" baseline → a 0..1 close amount, plus a signed horizontal direction hint. Unit-testable
//  with synthetic `GazeReading`s. The caller handles the `unavailable` case (it affects pose-source
//  switching), so `apply` is only given readings while the AR session is delivering frames.
//

import simd

struct GazeGate {
    var openAngle: Float = Tuning.gazeOpenAngle
    var closeAngle: Float = Tuning.gazeCloseAngle
    var screenCone: Float = Tuning.gazeScreenCone
    var captureHorizontalTol: Float = Tuning.gazeCaptureHorizontalTol

    /// 0 = looking at the screen .. 1 = looking away.
    private(set) var away: Float = 0
    /// Signed horizontal look-away direction (drives the sweep when gaze is the dominant closer).
    private(set) var direction: Float = 0

    private var referenceGaze: SIMD3<Float>?
    private var needsCapture = true

    /// Re-baseline the "looking at the screen" gaze on the next tracked frame (keeps current output).
    mutating func recenter() { needsCapture = true }

    /// Full clear (on stop / when gaze becomes unavailable).
    mutating func reset() {
        needsCapture = true
        referenceGaze = nil
        away = 0
        direction = 0
    }

    mutating func apply(_ reading: GazeReading) {
        if !reading.isTracked {
            away = 1   // face not in view (e.g. turned fully away) → looking away
            return
        }
        if reading.isBlinking { return }   // gaze spikes mid-blink — hold the last state
        if needsCapture {
            // Only anchor the "looking at the screen" baseline when the user really is looking
            // squarely at the device: within the screen cone (rejects enabling while looking away)
            // AND horizontally centered (rejects a slight turn that would bias the neutral pose).
            // Until then, report away (closed) — privacy-first.
            guard reading.screenAngle < screenCone,
                  abs(reading.horizontalOffset) < captureHorizontalTol else { away = 1; return }
            referenceGaze = reading.gazeDir
            needsCapture = false
        }
        guard let ref = referenceGaze else { return }
        let cosA = max(-1, min(1, simd_dot(reading.gazeDir, ref)))
        away = smoothstep(openAngle, closeAngle, acos(cosA))
        direction = reading.horizontalOffset   // absolute (unskewed) horizontal hint for the sweep
    }
}
