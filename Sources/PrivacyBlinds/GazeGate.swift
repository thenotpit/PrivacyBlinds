//
//  GazeGate.swift
//  PrivacyBlinds
//
//  Pure gaze-gating logic. Unit-testable with synthetic `GazeReading`s. The caller handles the
//  `unavailable` case (it affects pose-source switching), so `apply` is only given readings while
//  the AR session is delivering frames.
//
//  Two deliberate behaviours:
//    • The close is BINARY ("slam"), with the open/close angles forming a hysteresis band — not an
//      analog ramp. So a slow eye-roll can't ride the cover partway, and a noisy low-light estimate
//      that jitters near the boundary can't half-close it. (Pose keeps the analog swipe.)
//    • Low light suspends gaze entirely (pose-only), with its own lux hysteresis, since ARKit gaze
//      is unreliable in the dark.
//

import simd

struct GazeGate {
    var openAngle: Float = Tuning.gazeOpenAngle
    var closeAngle: Float = Tuning.gazeCloseAngle
    var screenCone: Float = Tuning.gazeScreenCone
    var captureHorizontalTol: Float = Tuning.gazeCaptureHorizontalTol
    var minLux: Double = Tuning.ambientLuxLow      // suspend gaze below this
    var resumeLux: Double = Tuning.ambientLuxHigh  // resume above this

    /// 0 = open (look at screen / suspended) .. 1 = closed (looking away). Binary, not analog.
    private(set) var away: Float = 0
    /// Signed horizontal look-away direction (drives the sweep when gaze is the dominant closer).
    private(set) var direction: Float = 0
    /// True once gaze protection is live this session: a baseline has been captured, OR low light has
    /// pushed us to pose-only. Used to hold a "warming up" cover until tracking is actually online
    /// (so a post-unlock look-away can't expose content during the ~0.5–1s ARKit warm-up).
    private(set) var ready = false

    private var referenceGaze: SIMD3<Float>?
    private var needsCapture = true
    private var closedState = false   // binary close state (hysteresis)
    private var luxReliable = true    // low-light state (hysteresis)

    /// Re-baseline on the next tracked frame; stay open until then (no flash mid-reading). Does NOT
    /// clear `ready` — a deliberate mid-session re-center shouldn't replay the warm-up graphic.
    mutating func recenter() {
        needsCapture = true
        away = 0
        closedState = false
    }

    /// Full clear (on stop / when gaze becomes unavailable).
    mutating func reset() {
        needsCapture = true
        referenceGaze = nil
        away = 0
        direction = 0
        closedState = false
        luxReliable = true
        ready = false
    }

    mutating func apply(_ reading: GazeReading) {
        // Low-light hysteresis: too dark → suspend gaze (pose-only), re-baseline when light returns.
        if reading.ambientLux >= 0 {
            if reading.ambientLux < minLux { luxReliable = false }
            else if reading.ambientLux > resumeLux { luxReliable = true }
        }
        if !luxReliable {
            away = 0
            closedState = false
            needsCapture = true
            ready = true        // low light → pose-only is the live protection; don't keep warming
            return
        }

        // Until a baseline is captured we're "warming up" (the camera takes ~0.5–1s to acquire the
        // face). Stay OPEN through warm-up — biasing closed here is what caused the black flash on
        // start/unlock. Capture the baseline only when looking squarely at the device (within the
        // screen cone AND horizontally centered); a not-yet-centered / not-yet-tracked frame just
        // keeps us open until a good one arrives.
        if needsCapture {
            if reading.isTracked, !reading.isBlinking,
               reading.screenAngle < screenCone, abs(reading.horizontalOffset) < captureHorizontalTol {
                referenceGaze = reading.gazeDir
                needsCapture = false
                closedState = false
                ready = true        // tracking is live → end warm-up
                away = 0
                direction = reading.horizontalOffset
            } else {
                away = 0
                closedState = false
            }
            return
        }

        // Baseline established → gate for real.
        if !reading.isTracked {
            away = 1; closedState = true   // face left view after acquiring → looking away
            return
        }
        if reading.isBlinking { return }   // gaze spikes mid-blink — hold the last state
        guard let ref = referenceGaze else { return }

        // Binary slam with angle hysteresis: cross closeAngle → closed; drop under openAngle → open.
        let angle = acos(max(-1, min(1, simd_dot(reading.gazeDir, ref))))
        if angle > closeAngle { closedState = true }
        else if angle < openAngle { closedState = false }
        away = closedState ? 1 : 0
        direction = reading.horizontalOffset   // absolute (unskewed) horizontal hint for the sweep
    }
}
