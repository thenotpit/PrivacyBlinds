# PrivacyBlinds — Example app

A small SwiftUI app that exercises every feature of the package on a real device.

## Run it

1. Open **`Privacy Blinds/Privacy Blinds.xcodeproj`**.
2. The package is referenced locally at `../..` (this repo), so there's nothing to fetch.
3. Select your iPhone, set your own **Signing Team** (Target ▸ Signing & Capabilities — the
   bundled team/bundle id are placeholders), and Run.

Use a **real device** — the motion gating needs device sensors, and eye tracking needs the
TrueDepth front camera; neither works in the Simulator.

## What it shows

Two independent overlays: a one-line **Account** number (always Face ID, screenshot-protected) above
the scrolling **notes**. A clean control panel on top (never covered) drives the notes:

- **Cover** (Black / Color / Image) — the blinds' fill; *Image* uses a photo you pick.
- **Choose Image** — pick a photo for the image cover.
- **Privacy mask** — overlay the perforated blue-noise mask at the reading position. With it on,
  press-and-drag to clear a reading band at your finger.
- **Authenticated gaze (Face ID)** — lock the notes behind Face ID + on-device eye tracking (prompts
  for camera permission on first enable). The account field and notes share `syncGroup: "account"`, so
  with this on, **one Face ID unlocks both**.

Hold the phone in a comfortable reading pose to reveal the content; tilt it away (or, with gaze on,
look away) to close it. **Two-finger triple-tap** re-centers the reading pose for every overlay.
