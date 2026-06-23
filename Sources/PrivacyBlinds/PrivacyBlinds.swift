//
//  PrivacyBlinds.swift
//  PrivacyBlinds
//
//  Public surface for the privacy overlay: vertical strips that sweep closed over a black, color, or
//  image cover, driven by device pose (and optionally gaze). The cover is composited on top of the
//  protected view and never samples the content itself.
//
//  Apply it to any view as a one-liner:
//
//      ChatListView().privacyBlinds(cover: .black)
//      SecretView().privacyBlinds(cover: .image(decoyImage))
//
//  The cover is a separate opaque z-layer composited on TOP of the protected view; the shader
//  only ever samples the cover (never the protected content), and outputs alpha 0 where a strip
//  reveals the content beneath. So it works over ANY view with zero content capture.
//
//  NOTE: This is POSE-gated privacy — it reacts to how the device is held, not to a bystander's
//  viewing angle. It is a "reveal only when held just-so" gate, not anti-shoulder-surfer privacy.
//

import SwiftUI

/// What fills the strips as they close.
public enum PrivacyCover: Sendable {
    /// Solid black — only the sweeping close/open boundary is visible ("blinds closing").
    case black
    /// A solid color cover.
    case color(Color)
    /// A decoy image (screenshot / brand splash / "nothing here").
    case image(Image)
}

public extension View {
    /// Apply a pose-gated privacy overlay. The protected content is revealed only while the device
    /// is held within `openThresholdDegrees` of the reading pose captured when the overlay appears,
    /// and the cover sweeps in as the device rotates toward `closeThresholdDegrees`.
    ///
    /// - Parameters:
    ///   - cover: What fills the strips (default `.black`).
    ///   - enabled: Master on/off (default `true`).
    ///   - stripWidth: Strip width in points (default `2.0`).
    ///   - sweep: 0 = uniform per-strip fade, 1 = full swipe-over fill (default `1.0`).
    ///   - transition: Sweep edge softness (default `0.75`).
    ///   - directionalSweep: How strongly the closing sweep cascades across the screen in the tilt
    ///     direction; `0` = all strips close in lockstep (default `0.5`). Vanishes at full close, so
    ///     a fully-closed cover never has a see-through gap.
    ///   - openThresholdDegrees: total pose deviation (roll + pitch combined) at/below which the
    ///     overlay is fully open (default `8`).
    ///   - closeThresholdDegrees: total pose deviation (roll + pitch combined) at/above which the
    ///     overlay is fully closed (default `16`). Tilting side-to-side, top-to-bottom, or any mix counts.
    ///   - maxViewAngleDegrees: Clamp for the sweep-direction angle (default `20`).
    ///   - maskFillRatio: Perforated "privacy mask" density at the reading position — the fraction of
    ///     cells painted opaque (0 = off/clear, ~0.5 = half). Readable through the holes up close,
    ///     denser to a distant camera. A fresh random pattern is generated each time the view appears.
    ///   - maskCellSize: Mask cell size in points (default `3`).
    ///   - maskRevealHeight: Height in points of the touch-following band that clears the mask at the
    ///     finger so a line can be read straight through the pattern (default `70`). Only active while
    ///     the mask is on and a finger is down.
    ///   - maskRevealFeather: Soft edge of the reading band in points (default `18`).
    ///   - maskCover: The mask pattern's appearance — `.black`, `.color`, or `.image` — independent of
    ///     the blinds `cover` (default `.black`).
    ///   - eyeTracking: Opt-in. When `true`, also close the overlay when the user looks away (TrueDepth
    ///     front camera, on-device). The gaze close is instant (binary), independent of the tilt sweep.
    ///     Starting it prompts for camera permission — the host app must include an
    ///     `NSCameraUsageDescription`. Falls back to pose-only if unsupported, denied, or too dark.
    ///     Default `false`.
    ///   - eyeTrackingMinLux: Ambient light (lux) below which gaze is suspended (pose-only). Default `450`.
    ///   - eyeTrackingResumeLux: Ambient light (lux) above which gaze resumes (hysteresis). Default `600`.
    ///   - onStateChange: Called with `true` when the overlay becomes (mostly) closed, `false` when it reopens.
    ///   - onAmbientLux: Reports the ARKit ambient light estimate (lux) while eye tracking is on.
    func privacyBlinds(
        cover: PrivacyCover = .black,
        enabled: Bool = true,
        stripWidth: CGFloat = 2.0,
        sweep: Float = 1.0,
        transition: Float = 0.75,
        directionalSweep: Float = 0.5,
        openThresholdDegrees: Float = 8,
        closeThresholdDegrees: Float = 16,
        maxViewAngleDegrees: Float = 20,
        maskFillRatio: Float = 0,
        maskCellSize: CGFloat = 3,
        maskRevealHeight: CGFloat = 70,
        maskRevealFeather: CGFloat = 18,
        maskCover: PrivacyCover = .black,
        eyeTracking: Bool = false,
        eyeTrackingMinLux: Double = 450,
        eyeTrackingResumeLux: Double = 600,
        onStateChange: ((Bool) -> Void)? = nil,
        onAmbientLux: ((Double) -> Void)? = nil
    ) -> some View {
        modifier(PrivacyBlindsModifier(
            cover: cover,
            enabled: enabled,
            stripWidthPt: stripWidth,
            stripSweep: sweep,
            transition: transition,
            directionalSweep: directionalSweep,
            maskFillRatio: maskFillRatio,
            maskCellSize: maskCellSize,
            maskRevealHeight: maskRevealHeight,
            maskRevealFeather: maskRevealFeather,
            maskCover: maskCover,
            openThresholdDeg: openThresholdDegrees,
            closeThresholdDeg: closeThresholdDegrees,
            maxViewAngleDeg: maxViewAngleDegrees,
            eyeTracking: eyeTracking,
            eyeTrackingMinLux: eyeTrackingMinLux,
            eyeTrackingResumeLux: eyeTrackingResumeLux,
            onStateChange: onStateChange,
            onAmbientLux: onAmbientLux
        ))
    }
}
