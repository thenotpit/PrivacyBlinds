//
//  PrivacyBlinds.metal
//  PrivacyBlinds
//
//  A fork of Lenticular Panel's `fragment_lenticular`. We keep the lens-strip geometry and the
//  per-lenticule "sweep" reveal, but drop the interlaced-slice sampling, refraction, chromatic
//  aberration and lighting — and swap the sim's "image A vs image B" blend for a "reveal vs
//  cover" blend driven by `closeProgress`.
//
//  Two deliberate choices vs. the sim:
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
    float2 position,            // implicit: pixel position (points) in the layer
    SwiftUI::Layer cover,       // implicit: sampleable cover overlay (NOT the content beneath)
    float2 size,                // view size in points
    float  lenticuleWidth,      // strip width in points
    float  closeProgress,       // 0 = fully open/revealed .. 1 = fully closed/covered
    float  lenticuleSweep,      // 0 = uniform per-strip fade .. 1 = full swipe-over fill
    float  transition,          // sweep edge softness
    float  viewAngle,           // signed radians: drives the sweep direction
    float  directionalSweep     // 0 = strips close in lockstep .. higher = stronger directional cascade
) {
    // --- Lenticule geometry: which vertical strip we're in, and where within it --------------
    float u   = position.x / size.x;          // 0..1 across the view width
    float lw  = lenticuleWidth / size.x;      // normalized strip width
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

    // --- Per-lenticule sweep: a moving boundary wipes the cover in from one edge of the strip --
    // The wipe fills from the side you tilt toward (cc = c * dirSign).
    float edgeSoftness = max(transition * 0.5, 0.02);
    float boundary     = (0.5 + edgeSoftness) - localProgress * (1.0 + 2.0 * edgeSoftness);
    float cc           = c * dirSign;
    float sweepBlend   = smoothstep(boundary - edgeSoftness, boundary + edgeSoftness, cc);
    float coverAmount  = mix(localProgress, sweepBlend, lenticuleSweep); // 0 reveal .. 1 cover

    // --- Composite (premultiplied alpha). Sample the cover 1:1 at this pixel — no translation, so
    // the cover always fully covers (no see-through gap). coverAmount→0 reveals the content beneath.
    half4 coverPixel = cover.sample(position); // black => (0,0,0,1); image => decoy pixel
    return coverPixel * half(coverAmount);
}
