# WhisprGo 1.1.0

WhisprGo 1.1 adds configurable global shortcuts and an optional on-device Pro cleanup beta.

## What’s new

- Record custom shortcuts for push-to-talk, hands-free dictation, Fast/Pro switching, Pro profile cycling, and paste-last.
- Shortcut changes apply immediately, persist across launches, reject conflicts, and can be restored to the familiar defaults.
- Pro cleanup continues to use GPT-5.6 Luna by default.
- The optional **On Device (Beta)** provider downloads a 4-bit Gemma 4 E2B MLX model and keeps cleanup text and nearby context on the Mac.
- Clear confirmation warns that the beta needs about 4.6 GB of storage and roughly 5–7 GB of unified memory while loaded.
- Gemma stays resident throughout local Pro Mode and unloads after five minutes away from it.

## Install

1. Download `WhisprGo-1.1.0.dmg`.
2. Open the disk image and drag **WhisprGo** to **Applications**.
3. Control-click the app, choose **Open**, and confirm.
4. Allow Microphone and Accessibility access when prompted.

This build is ad-hoc signed, not notarized with an Apple Developer ID. All source code and build steps are available in this repository.
