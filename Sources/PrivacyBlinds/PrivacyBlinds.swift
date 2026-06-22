//
//  PrivacyBlinds.swift
//  PrivacyBlinds
//
//  Public surface for the privacy-lens overlay. A fork of the Lenticular Panel simulation:
//  reuses the lens-strip geometry, the per-lenticule sweep reveal, and the parallax fill — but
//  drops refraction/aberration/lighting and is driven by device pose instead of an image blend.
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

/// What fills the lens strips as they close.
public enum PrivacyCover: Sendable {
    /// Solid black — only the sweeping close/open boundary is visible ("blinds closing").
    case black
    /// A solid color cover.
    case color(Color)
    /// A decoy image (screenshot / brand splash / "nothing here"); it also parallaxes within each strip.
    case image(Image)
}

public extension View {
    /// Overlay a pose-gated privacy lens. The protected content is revealed only while the device
    /// is held within `openThresholdDegrees` of the reading pose captured when the overlay appears,
    /// and the cover sweeps in as the device rotates toward `closeThresholdDegrees`.
    ///
    /// - Parameters:
    ///   - cover: What fills the strips (default `.black`).
    ///   - enabled: Master on/off (default `true`).
    ///   - stripWidth: Lens-strip width in points (default `2.0`, from the sim's `stripWidth`).
    ///   - sweep: 0 = uniform per-strip fade, 1 = full swipe-over fill (default `1.0`).
    ///   - transition: Sweep edge softness (default `0.75`).
    ///   - directionalSweep: How strongly the closing sweep cascades across the screen in the tilt
    ///     direction; `0` = all strips close in lockstep (default `0.5`). Vanishes at full close, so
    ///     a fully-closed cover never has a see-through gap.
    ///   - openThresholdDegrees: |deviation| at/below which the lens is fully open (default `8`).
    ///   - closeThresholdDegrees: |deviation| at/above which the lens is fully closed (default `16`).
    ///   - maxViewAngleDegrees: Clamp for the parallax view angle (default `20`).
    ///   - onStateChange: Called with `true` when the lens becomes (mostly) closed, `false` when it reopens.
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
        onStateChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(PrivacyBlindsModifier(
            cover: cover,
            enabled: enabled,
            stripWidthPt: stripWidth,
            lenticuleSweep: sweep,
            transition: transition,
            directionalSweep: directionalSweep,
            openThresholdDeg: openThresholdDegrees,
            closeThresholdDeg: closeThresholdDegrees,
            maxViewAngleDeg: maxViewAngleDegrees,
            onStateChange: onStateChange
        ))
    }
}
