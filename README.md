# PrivacyBlinds

A SwiftUI view modifier that overlays a **pose-gated privacy lens** on any view. The protected
content is revealed only while the device is held in a calibrated "reading position"; rotate it
away and lens-shaped strips sweep closed with a black, color, or custom-image cover.

```swift
SecretView().privacyBlinds(cover: .black)
```

Forked from a lenticular-print simulation — it reuses the lens-strip geometry and the per-lenticule
sweep, driven by the same drift-free roll detection.

## How it works

The cover is a separate **opaque overlay** composited on top of your view. The Metal shader only
ever samples the cover — never the protected content — and outputs alpha 0 where a strip reveals
what's beneath. So it works over *any* view (a `ScrollView`, an image, a whole screen) with zero
content capture, and the protected pixels are never handed to the shader.

Device pose comes from a single shared `CoreMotion` stream (gyro integration + a gravity
complementary filter for drift-free roll, plus a gravity-derived pitch). When the modifier appears
it captures the current pose as the reading pose; deviation from it drives how closed the lens is.

**Multi-axis:** both side-to-side roll and top-to-bottom pitch are combined into one deviation
magnitude, so tilting the device *any* direction (or a mix) past the threshold closes the cover. The
closing sweep also follows the tilt direction it came from.

**Re-centering:** the reading pose is captured on appear, once the device settles (held still), so
the "open" pose lands where you actually read rather than mid-motion. To reset it deliberately — say
you shift to a new reading position — **two-finger triple-tap** the protected view to re-anchor. The
pose is *never* re-anchored automatically from motion, so incidental movement (dropping your hand,
setting the phone down) can't reveal the content.

## ⚠️ Pose-gated, not anti-shoulder-surfer privacy

It reacts to **how the device is held**, which software knows perfectly. It does **not** stop
someone beside you from seeing your screen at your own viewing moment — every OLED pixel emits in
all directions, so true per-observer angular privacy needs a physical louver/lens film. Treat this
as a "reveal only when held just-so" gate / glance-deterrent, not a guarantee against snooping.

## Requirements

- iOS 17.0+ (uses SwiftUI `layerEffect` + stitchable Metal shaders)
- Xcode 26+ / Swift 6 toolchain
- A real device for the motion gating (the Simulator has no device motion)
- Eye tracking (optional) needs a TrueDepth front camera (iPhone X+) and an `NSCameraUsageDescription`
  in the host app's Info.plist; it degrades gracefully to pose-only where unavailable

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/thenotpit/PrivacyBlinds.git", from: "0.3.0")
```

…then add `"PrivacyBlinds"` to your target's dependencies. Or in Xcode: **File ▸ Add Package
Dependencies…** and paste the URL.

## Usage

```swift
import PrivacyBlinds

struct ChatView: View {
    var body: some View {
        MessageList()
            .privacyBlinds(cover: .black)        // or .color(.indigo), .image(decoyImage)
    }
}
```

React to open/close:

```swift
.privacyBlinds(cover: .image(decoy)) { closed in
    // closed == true once the lens is (mostly) shut
}
```

### Privacy mask (perforated overlay)

Optionally, while the lens is open at the reading position, lay down a **perforated blue-noise
mask** over the content — an evenly-distributed field of opaque cells with transparent holes:

```swift
SecretView().privacyBlinds(
    cover: .black,
    maskFillRatio: 0.4,            // 0 = off; fraction of cells opaque (more = denser)
    maskCellSize: 3,              // hole spacing in points (smaller = finer grain)
    maskCover: .color(.white)     // the mask's own color/image, independent of the blinds cover
)
```

You can read through the holes up close, but the cells integrate toward solid at a distance / to a
camera, so it raises the bar on casual off-angle photos. The pattern is **blue noise** (even, no
clumps, no moiré) and is regenerated **per appearance** but held **static while shown** — animating
it would let a camera average frames and recover the content.

**Touch reading band:** while the mask is on, press the view and a horizontal band clears the mask
at your finger so you can read a line straight through it; it emanates from the touch point and
follows your finger, and doesn't block scrolling. Size it with `maskRevealHeight` / `maskRevealFeather`.

> Honest caveat: the "dense at a distance" effect is optical and depends on pixel density, hole
> size, viewing distance, and the camera — validate it with a real camera before relying on it. It
> reduces capture fidelity; it is not a guarantee.

### Eye tracking (look-away gate)

Opt in and the lens *also* closes when you look away from the screen — combined with the pose gate,
so it closes on **tilt past the threshold OR looking away**, whichever comes first:

```swift
SecretView().privacyBlinds(cover: .black, eyeTracking: true)
```

- Uses the **TrueDepth front camera** via ARKit face tracking, entirely **on-device** — no frames are
  stored or transmitted. The session starts only when `eyeTracking` is `true`, and starting it
  prompts for camera permission, so **the host app must declare an `NSCameraUsageDescription`**.
- Detects both **eye movement and head turns** (gaze is measured relative to the device, so rotating
  your whole body while still facing the screen does *not* close it). Blinks are ignored.
- The gaze close is **instant (binary)**, independent of the tilt sweep — so a slow eye-roll can't
  ride the cover partway and a noisy estimate can't leave it half-closed. (Tilt keeps the smooth sweep.)
- **Fails safe:** no TrueDepth camera or permission denied → it silently falls back to pose-only
  gating (never forces itself shut or locks you out). In **low light** gaze is suspended the same way
  (configurable via `eyeTrackingMinLux` / `eyeTrackingResumeLux`), with pose gating carrying on. Read
  the live value through `onAmbientLux` if you want to tune it.
- While the session runs, ARKit also supplies the device pose (it suspends a separate `CMMotionManager`),
  so tilt gating and drift correction keep working with eye tracking on.

> Scope note: ARKit gaze is good for **coarse "looking at the screen vs. away."** It is *not* precise
> enough to track exactly where on the screen you're looking (that needs dedicated eye-tracking
> hardware), so the lens uses it only as a gate, not to position anything.

### Tuning

| Parameter | Default | What it does |
|---|---|---|
| `cover` | `.black` | Strip fill: `.black`, `.color(Color)`, or `.image(Image)` |
| `enabled` | `true` | Master on/off |
| `stripWidth` | `2.0` | Lens-strip width in points; widen for chunkier venetian slats |
| `sweep` | `1.0` | 0 = uniform per-strip fade, 1 = full swipe-over fill |
| `transition` | `0.75` | Sweep edge softness |
| `directionalSweep` | `0.5` | How strongly the close cascades in the tilt direction (0 = lockstep) |
| `openThresholdDegrees` | `8` | At/below this much combined (roll+pitch) deviation the lens is fully open |
| `closeThresholdDegrees` | `16` | At/above this much combined (roll+pitch) deviation the lens is fully closed |
| `maxViewAngleDegrees` | `20` | Clamp for the sweep-direction angle |
| `maskFillRatio` | `0` | Privacy-mask density (0 = off; fraction of cells opaque) |
| `maskCellSize` | `3` | Mask hole spacing in points (smaller = finer grain) |
| `maskRevealHeight` | `70` | Height of the touch-following reading band, points |
| `maskRevealFeather` | `18` | Soft edge of the reading band, points |
| `maskCover` | `.black` | Mask pattern appearance, independent of the blinds `cover` |
| `eyeTracking` | `false` | Also close when the user looks away (TrueDepth, on-device, opt-in) |
| `eyeTrackingMinLux` | `450` | Suspend gaze below this ambient light (lux); falls back to pose-only |
| `eyeTrackingResumeLux` | `600` | Resume gaze above this ambient light (lux); hysteresis band |

Re-center the reading pose with a **two-finger triple-tap** on the protected view.

## Status

Reveal/cover sweep with black / color / image covers; multi-axis (roll + pitch) pose gating with
settle-on-stillness anchoring and a two-finger triple-tap re-center; an optional perforated
blue-noise privacy mask with a touch-following reading band; and optional eye-tracking look-away
gating (on-device, opt-in). Not yet: custom-cover persistence, face-down deviation term, app-switcher
snapshot cover, Reduce Motion / always-reveal accessibility override, and a live-tuning sheet.

## License

MIT — see [LICENSE](LICENSE).
