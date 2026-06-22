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
complementary filter for drift-free roll). When the modifier appears it captures the current pose
as the reading pose; deviation from it drives how closed the lens is.

## ⚠️ Pose-gated, not anti-shoulder-surfer privacy

It reacts to **how the device is held**, which software knows perfectly. It does **not** stop
someone beside you from seeing your screen at your own viewing moment — every OLED pixel emits in
all directions, so true per-observer angular privacy needs a physical louver/lens film. Treat this
as a "reveal only when held just-so" gate / glance-deterrent, not a guarantee against snooping.

## Requirements

- iOS 17.0+ (uses SwiftUI `layerEffect` + stitchable Metal shaders)
- Xcode 26+ / Swift 6 toolchain
- A real device for the motion gating (the Simulator has no device motion)

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/<your-account>/PrivacyBlinds.git", from: "0.1.0")
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

### Tuning

| Parameter | Default | What it does |
|---|---|---|
| `cover` | `.black` | Strip fill: `.black`, `.color(Color)`, or `.image(Image)` |
| `enabled` | `true` | Master on/off |
| `stripWidth` | `2.0` | Lens-strip width in points; widen for chunkier venetian slats |
| `sweep` | `1.0` | 0 = uniform per-strip fade, 1 = full swipe-over fill |
| `transition` | `0.75` | Sweep edge softness |
| `directionalSweep` | `0.5` | How strongly the close cascades in the tilt direction (0 = lockstep) |
| `openThresholdDegrees` | `8` | At/below this much deviation the lens is fully open |
| `closeThresholdDegrees` | `16` | At/above this much deviation the lens is fully closed |
| `maxViewAngleDegrees` | `20` | Clamp for the sweep-direction angle |

## Status

v0: reveal/cover sweep, roll-based pose gating, and black / color / image covers. Not yet:
custom-cover persistence, multi-axis (pitch / face-down) deviation, app-switcher snapshot cover,
Reduce Motion / always-reveal accessibility override, and a live-tuning sheet.

## License

MIT — see [LICENSE](LICENSE).
