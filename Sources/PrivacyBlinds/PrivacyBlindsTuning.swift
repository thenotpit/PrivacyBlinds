//
//  PrivacyBlindsTuning.swift
//  PrivacyBlinds
//
//  Central home for the internal feel/behaviour constants that were previously inline magic numbers.
//  Public-facing knobs (thresholds, mask, etc.) stay on the `privacyBlinds(...)` modifier; these are
//  the internal tuning values dialed in on-device.
//

import Foundation

enum Tuning {
    // MARK: Pose settle-on-stillness anchoring
    /// Per-frame roll+pitch change (radians) under which the device counts as "held still".
    static let stillDelta: Float = 0.02
    /// How long the device must be held still before the reading pose is anchored.
    static let settleDuration: TimeInterval = 0.25
    /// Safety valve: anchor anyway after this long, so a fidgety hold can't leave the cover stuck closed.
    static let maxPendingDuration: TimeInterval = 2.5

    // MARK: Gaze gate (eye tracking)
    /// Gaze-from-baseline angle (radians) within which the user still counts as looking at the screen.
    static let gazeOpenAngle: Float = 0.20    // ~11°
    /// Gaze-from-baseline angle (radians) past which the user counts as looking away (fully closed).
    static let gazeCloseAngle: Float = 0.38   // ~22°
    /// Average of both eye-blink blendshapes above which we treat the frame as a blink and hold state.
    static let blinkThreshold: Float = 0.5

    // MARK: Close-state reporting
    /// `closeProgress` past this is reported as "closed" (drives `onStateChange` + interaction lock).
    static let closedThreshold: Float = 0.5

    // MARK: Reading-band reveal animation
    static let revealOpenDuration: Double = 0.10
    static let revealCloseDuration: Double = 0.10

    // MARK: Mask
    /// Range for the per-appearance random blue-noise tile offset.
    static let maskSeedRange: Float = 4096
}
