//
//  PrivacyBlinds.metal
//  PrivacyBlinds
//
//  Renders the privacy overlay: vertical strips that sweep closed over the cover, driven by
//  `closeProgress`. Outputs alpha 0 where a strip reveals the content beneath.
//
//  Two deliberate choices:
//    • The cover is sampled 1:1 (no per-strip slice, no translation) so an image cover stays crisp
//      AND always fully covers — translating the sample runs off the cover edge on the leading
//      side and opens a see-through privacy gap, so we don't.
//    • The closing sweep is directional: it cascades across the screen in the tilt direction (the
//      leading edge closes first). The cascade is scaled to vanish at fully-open and fully-closed,
//      so the reading pose stays crisp and full close is fully covered (no residual gap).
//
//  This is a SwiftUI `layerEffect` stitchable shader. `layerEffect` supplies the first two
//  parameters implicitly: `position` (pixel position in points) and the sampleable cover
//  `SwiftUI::Layer` (a black/color rect or the decoy image) — never the protected content.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]]
half4 privacyBlinds(
    float2 position,                // implicit: pixel position (points) in the layer
    SwiftUI::Layer cover,           // implicit: sampleable cover overlay (NOT the content beneath)
    float2 size,                    // view size in points
    float  stripWidth,              // strip width in points
    float  closeProgress,           // 0 = fully open/revealed .. 1 = fully closed/covered
    float  stripSweep,              // 0 = uniform per-strip fade .. 1 = full swipe-over fill
    float  transition,              // sweep edge softness
    float  viewAngle,               // signed radians: drives the sweep direction
    float  directionalSweep,        // 0 = strips close in lockstep .. higher = stronger directional cascade
    float  maskFillRatio,           // 0 = mask off .. 1 = solid; fraction of cells painted opaque
    float  maskCellSize,            // mask cell size in points (one blue-noise cell per this)
    float2 maskSeed,                // per-appearance tile shift so the pattern differs each time
    float  revealProgress,          // 0 = closed .. 1 = fully open (animates out from the touch point)
    float  revealY,                 // finger Y in points
    float  revealHalfHeight,        // half-height of the cleared reading band at full open, points
    float  revealFeather,           // soft edge of the band, points
    texture2d<float> blueNoise,     // 64×64 tileable blue-noise dither array (rank texture)
    float  maskUseImage,            // 0 = mask uses maskColor, 1 = samples maskImage
    half4  maskColor,               // mask pattern color (independent of the blinds cover)
    texture2d<float> maskImage      // mask pattern image (used when maskUseImage > 0.5)
) {
    // --- Strip geometry: which vertical strip we're in, and where within it -------------------
    float u   = position.x / size.x;          // 0..1 across the view width
    float lw  = stripWidth / size.x;          // normalized strip width
    float pil = fmod(u, lw) / lw;             // 0..1 within the strip
    float c   = pil - 0.5;                    // -0.5..+0.5 centered

    // Tilt direction, smoothly ramped through 0 (settles to ±1 before any coverage begins, so no
    // snap as it crosses the reading pose).
    float dirSign = clamp(viewAngle / 0.05, -1.0, 1.0);

    // --- Directional cascade (the "swipe"): leading edge closes first, sweeping across the screen.
    // `cascade` is 0 at fully open and fully closed and peaks mid-transition, so the reading pose
    // stays crisp and full close is fully covered — the cascade never leaves a gap once closed.
    float cascade    = closeProgress * (1.0 - closeProgress) * 4.0;
    float screenLead = (u - 0.5) * dirSign * directionalSweep * cascade;
    float localProgress = clamp(closeProgress + screenLead, 0.0, 1.0);

    // --- Per-strip sweep: a moving boundary wipes the cover in from one edge of the strip -------
    // The wipe fills from the side you tilt toward (cc = c * dirSign).
    float edgeSoftness = max(transition * 0.5, 0.02);
    float boundary     = (0.5 + edgeSoftness) - localProgress * (1.0 + 2.0 * edgeSoftness);
    float cc           = c * dirSign;
    float sweepBlend   = smoothstep(boundary - edgeSoftness, boundary + edgeSoftness, cc);
    float coverAmount  = mix(localProgress, sweepBlend, stripSweep); // 0 reveal .. 1 cover

    // --- Perforated privacy mask (optional) --------------------------------------------------
    // Even at the reading position, lay down opaque black with an evenly-spaced field of holes:
    // readable through the holes up close, but it integrates toward solid at a distance / to a
    // camera. Static per appearance (driven by maskSeed) — animating it would let a camera average
    // frames and recover the content. Disabled when maskFillRatio <= 0.
    //
    // Blue noise: each cell reads a rank (0..1) from a tileable blue-noise dither array and is
    // opaque when rank < maskFillRatio. Blue noise is random but spatially even, so the holes stay
    // evenly spaced at any fill ratio — no clumps, no big blocked patches (white noise's failure),
    // and no grid moiré (a regular grid's failure). maskSeed shifts the tile per appearance.
    half maskAlpha = 0.0h;
    if (maskFillRatio > 0.0) {
        constexpr sampler bnSampler(filter::nearest, address::repeat, coord::normalized);
        float cs = max(maskCellSize, 0.01);
        float2 cell = floor(position / cs) + maskSeed;      // one cell per maskCellSize points
        float bn = blueNoise.sample(bnSampler, (cell + 0.5) / 64.0).r;
        maskAlpha = bn < maskFillRatio ? 1.0h : 0.0h;       // even (blue-noise) opaque/hole choice

        // Touch-following reading band: clear the mask in a horizontal strip at the finger so the
        // user can read a line straight through the pattern. It follows the finger and only affects
        // the mask — the pose-gated cover still wins everywhere when closed (see the max() below).
        // Emanate from the touch: the band's half-height grows from 0 to full with revealProgress and
        // the clearing fades in, so it opens outward from the finger and fades back on release.
        if (revealProgress > 0.0) {
            float hh    = revealHalfHeight * revealProgress;
            float band  = smoothstep(hh - revealFeather, hh + revealFeather, abs(position.y - revealY));
            float clear = (1.0 - band) * revealProgress;    // 0..1 cleared inside the grown band
            maskAlpha *= half(1.0 - clear);
        }
    }

    // --- Composite (premultiplied alpha) -----------------------------------------------------
    // Two layers, both sampled 1:1 (no translation, so each always fully covers — no gap):
    //   • mask layer  — the perforated dither, in its OWN color/image (independent of the blinds).
    //   • cover layer — the closing blinds, in the cover's color/image, scaled by coverAmount.
    // Composite the blinds OVER the mask: at the reading position only the mask shows; as it closes
    // the blinds sweep over the mask; fully closed the blinds win entirely (privacy intact).
    half3 maskRGB;
    if (maskUseImage > 0.5) {
        constexpr sampler imgSampler(filter::linear, address::clamp_to_edge, coord::normalized);
        maskRGB = half3(maskImage.sample(imgSampler, position / size).rgb);  // stretch to fill
    } else {
        maskRGB = maskColor.rgb;
    }

    half4 coverLayer = cover.sample(position) * half(coverAmount);   // premultiplied
    half4 maskLayer  = half4(maskRGB * maskAlpha, maskAlpha);        // premultiplied
    return coverLayer + maskLayer * (1.0h - coverLayer.a);           // blinds over mask over content
}
