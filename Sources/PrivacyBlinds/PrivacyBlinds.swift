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
    ///   - screenshotProtected: Exclude the protected content from screenshots / screen recordings /
    ///     mirroring via a secure layer — it reads blank in any capture while staying visible live
    ///     (default `true`). Routes content through a UIKit secure container; see the docs for caveats
    ///     (severs SwiftUI environment inheritance into the content; best for fill-sized content).
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
    ///   - authenticatedGaze: Opt-in. When `true`, the view starts in a **locked** state (a blue-noise
    ///     cover over solid white); tapping it prompts Face ID / passcode to unlock. While unlocked,
    ///     pose + on-device eye tracking gate as normal, and the gaze close is instant (binary). It
    ///     re-locks after `relockSeconds` continuously covered, or when the app is backgrounded.
    ///     Requires an `NSCameraUsageDescription` in the host app. Default `false` (pose-only).
    ///   - gazeMinLux: Ambient light (lux) below which gaze is suspended (pose-only). Default `450`.
    ///   - gazeResumeLux: Ambient light (lux) above which gaze resumes (hysteresis). Default `600`.
    ///   - relockSeconds: Re-lock after the view is continuously covered this long (default `10`).
    ///   - syncGroup: Opt-in id for authenticated-gaze views. Views on screen sharing a non-nil id unlock
    ///     and re-lock together — one Face ID clears the whole group. `nil` (default) keeps each view
    ///     independent. Ignored when `authenticatedGaze` is `false`.
    ///   - unlockReason: Prompt text shown by Face ID / passcode (default `"Unlock to reveal"`).
    ///   - lockBackgroundColor: Locked-screen background, behind the perforation (default `.white`).
    ///   - lockPatternColor: Locked-screen blue-noise perforation color (default `.black`).
    ///   - lockIconBackgroundColor: Fill of the small square behind the lock icon (default `.white`).
    ///   - lockIconColor: Lock icon color (default `.black`).
    ///   - showsLockIcon: Whether the lock glyph is drawn on the locked screen. Set `false` for a clean
    ///     cover with no icon (default `true`).
    ///   - onStateChange: Called with `true` when the overlay becomes (mostly) closed, `false` when it reopens.
    ///   - onAmbientLux: Reports the ARKit ambient light estimate (lux) while gaze is active.
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
        screenshotProtected: Bool = true,
        maskFillRatio: Float = 0,
        maskCellSize: CGFloat = 3,
        maskRevealHeight: CGFloat = 70,
        maskRevealFeather: CGFloat = 18,
        maskCover: PrivacyCover = .black,
        authenticatedGaze: Bool = false,
        gazeMinLux: Double = 450,
        gazeResumeLux: Double = 600,
        relockSeconds: Double = 10,
        syncGroup: String? = nil,
        unlockReason: String = "Unlock to reveal",
        lockBackgroundColor: Color = .white,
        lockPatternColor: Color = .black,
        lockIconBackgroundColor: Color = .white,
        lockIconColor: Color = .black,
        showsLockIcon: Bool = true,
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
            screenshotProtected: screenshotProtected,
            authenticatedGaze: authenticatedGaze,
            gazeMinLux: gazeMinLux,
            gazeResumeLux: gazeResumeLux,
            relockSeconds: relockSeconds,
            syncGroup: syncGroup,
            unlockReason: unlockReason,
            lockBackgroundColor: lockBackgroundColor,
            lockPatternColor: lockPatternColor,
            lockIconBackgroundColor: lockIconBackgroundColor,
            lockIconColor: lockIconColor,
            showsLockIcon: showsLockIcon,
            onStateChange: onStateChange,
            onAmbientLux: onAmbientLux
        ))
    }
}
