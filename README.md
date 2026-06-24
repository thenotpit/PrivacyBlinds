# PrivacyBlinds

A SwiftUI view modifier that puts a **pose-gated privacy overlay** on any view. The protected
content is revealed only while the device is held in a calibrated "reading position"; rotate it
away and strips sweep closed with a black, color, or custom-image cover.

```swift
SecretView().privacyBlinds(cover: .black)
```

## How it works

The cover is a separate **opaque overlay** composited on top of your view. The Metal shader only
ever samples the cover — never the protected content — and outputs alpha 0 where a strip reveals
what's beneath. So it works over *any* view (a `ScrollView`, an image, a whole screen) with zero
content capture, and the protected pixels are never handed to the shader.

Device pose comes from a single shared `CoreMotion` stream (gyro integration + a gravity
complementary filter for drift-free roll, plus a gravity-derived pitch). When the modifier appears
it captures the current pose as the reading pose; deviation from it drives how closed the overlay is.

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
all directions, so true per-observer angular privacy needs a physical louver/privacy film. Treat this
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
    // closed == true once the overlay is (mostly) shut
}
```

### Privacy mask (perforated overlay)

Optionally, while the overlay is open at the reading position, lay down a **perforated blue-noise
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

### Authenticated gaze (Face ID + eye tracking)

Opt in to a **lock/unlock** layer with on-device eye tracking. The view starts **locked** — a
perforated blue-noise cover with a lock glyph; tapping it prompts Face ID (→ passcode). Once
unlocked, pose + gaze gate as normal, and it **re-locks** when left covered or backgrounded.

```swift
SecretView().privacyBlinds(cover: .black, authenticatedGaze: true)
```

The states:

1. **Locked** (resting): opaque perforated cover + lock icon, camera off. Tap → authenticate.
2. **Authenticating:** `LocalAuthentication` `.deviceOwnerAuthentication` — **Face ID / Touch ID,
   falling back to the device passcode**. Requires an `NSFaceIDUsageDescription` in the host app.
3. **Warming up:** after auth, the privacy texture "calibrates" (its perforation breathes in place)
   while ARKit acquires your face — the content stays covered, so a quick look-away can't expose it.
4. **Unlocked:** content reveals only while held in the reading pose **and** looked at. Tilts / quick
   look-aways do a transient cover (look back → revealed, no re-auth). The gaze close is **instant
   (binary)** — a slow eye-roll can't ride it partway.

**Re-lock** (back to Face ID) happens after the view has been **continuously covered for
`relockSeconds`** (default 10) — driven by gaze in good light, or by pose in the dark — and on **app
backgrounding** (which also covers the app-switcher snapshot).

- Everything is **on-device**; no frames are stored or transmitted. Needs an `NSCameraUsageDescription`
  (camera) and `NSFaceIDUsageDescription` (Face ID) in the host app.
- Gaze is measured **relative to the device**, so turning your whole body while still facing the
  screen does *not* close it; blinks are ignored.
- **Fails safe:** no TrueDepth camera → degrades to Face-ID lock + pose-only. In **low light** gaze
  suspends (configurable via `gazeMinLux` / `gazeResumeLux`) and pose carries the gate; Face ID itself
  works in the dark. Read the live lux via `onAmbientLux`.
- The locked-screen colors are configurable (`lockBackgroundColor`, `lockPatternColor`,
  `lockIconBackgroundColor`, `lockIconColor`).

> Scope note: ARKit gaze is good for **coarse "looking at the screen vs. away,"** not precise
> on-screen gaze, and it is **not** identity-aware — it gates on "a face is looking," not "the owner
> is looking." Face ID is the identity check; gaze is the attention check.

### Tuning

| Parameter | Default | What it does |
|---|---|---|
| `cover` | `.black` | Strip fill: `.black`, `.color(Color)`, or `.image(Image)` |
| `enabled` | `true` | Master on/off |
| `stripWidth` | `2.0` | Strip width in points; widen for chunkier venetian slats |
| `sweep` | `1.0` | 0 = uniform per-strip fade, 1 = full swipe-over fill |
| `transition` | `0.75` | Sweep edge softness |
| `directionalSweep` | `0.5` | How strongly the close cascades in the tilt direction (0 = lockstep) |
| `openThresholdDegrees` | `8` | At/below this much combined (roll+pitch) deviation the overlay is fully open |
| `closeThresholdDegrees` | `16` | At/above this much combined (roll+pitch) deviation the overlay is fully closed |
| `maxViewAngleDegrees` | `20` | Clamp for the sweep-direction angle |
| `screenshotProtected` | `true` | Exclude protected content from screenshots / recordings / mirroring (secure layer) |
| `maskFillRatio` | `0` | Privacy-mask density (0 = off; fraction of cells opaque) |
| `maskCellSize` | `3` | Mask hole spacing in points (smaller = finer grain) |
| `maskRevealHeight` | `70` | Height of the touch-following reading band, points |
| `maskRevealFeather` | `18` | Soft edge of the reading band, points |
| `maskCover` | `.black` | Mask pattern appearance, independent of the blinds `cover` |
| `authenticatedGaze` | `false` | Face ID lock/unlock + on-device eye tracking (opt-in) |
| `gazeMinLux` | `450` | Suspend gaze below this ambient light (lux); falls back to pose-only |
| `gazeResumeLux` | `600` | Resume gaze above this ambient light (lux); hysteresis band |
| `relockSeconds` | `10` | Re-lock after the view is continuously covered this long |
| `unlockReason` | `"Unlock to reveal"` | Prompt text shown by Face ID / passcode |
| `lockBackgroundColor` | `.white` | Locked-screen background behind the perforation |
| `lockPatternColor` | `.black` | Locked-screen blue-noise perforation color |
| `lockIconBackgroundColor` | `.white` | Fill of the square behind the lock icon |
| `lockIconColor` | `.black` | Lock icon color |

Re-center the reading pose with a **two-finger triple-tap** on the protected view.

### Capture & background protection

- **Screenshots / recordings / mirroring** — with `screenshotProtected` (default `true`), the protected
  content is hosted in a secure layer iOS excludes from capture, so it reads **blank** in any
  screenshot, screen recording, or AirPlay mirror while staying visible live. *Caveats:* it relies on
  UIKit's secure-field rendering (an undocumented behavior), severs SwiftUI environment inheritance into
  the content, and is best for content that fills its frame.
- **App switcher** — whenever the app leaves the foreground the cover is forced closed (all modes), so
  the OS multitasking snapshot never shows content.

### Accessibility

- Honors **Reduce Motion** (the touch reading band snaps instead of animating).
- `enabled: false` is the **always-reveal escape hatch** — fully disables gating *and* screenshot
  hosting (clean passthrough) for users for whom pose/gaze gating is a barrier. Wire it to your app's
  own accessibility preference.

## Status

Shipping: reveal/cover sweep (black / color / image covers); multi-axis (roll + pitch) pose gating with
settle-on-stillness anchoring and two-finger triple-tap re-center; an optional perforated blue-noise
privacy mask with a touch-following reading band; **authenticated-gaze mode** (Face ID lock/unlock +
on-device eye tracking, with a "warming up" calibration and re-lock); **screenshot/recording protection**;
**app-switcher snapshot cover** (all modes); and Reduce-Motion support. All on-device.

## License

MIT — see [LICENSE](LICENSE).
