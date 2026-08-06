<p align="center">
  <img src="Assets/WhisprGo.svg" width="520" alt="WhisprGo">
</p>

WhisprGo is a low-latency macOS dictation engine that lives in the menu bar. By default, hold **fn** for push-to-talk, then release it to type. Press **fn + shift** once to start hands-free listening and press the chord again to stop and type. Every global shortcut is configurable in Settings.

## What is included

- A native SwiftUI menu-bar interface and Settings window.
- Configurable shortcuts for push-to-talk, hands-free dictation, Fast/Pro switching, Pro profiles, and pasting the last dictation.
- Automatic one-time download and warm-up for Parakeet and Whisper models.
- NVIDIA Parakeet TDT 0.6B v3 plus local Whisper Tiny, Base, Small, and Large v3 Turbo choices.
- OpenAI `gpt-transcribe`, `gpt-4o-mini-transcribe`, and `whisper-1` choices.
- Pro cleanup through GPT-5.6 Luna by default, or an optional beta for on-device, 4-bit Gemma 4 E2B accelerated by MLX.
- API keys stored in macOS Keychain.
- AirPods mode uses the built-in Mac microphone while leaving headphones in high-quality playback mode.
- Optional always-active input for the lowest possible shortcut-to-audio latency.
- Optional launch at login.
- A local history of the latest 50 dictations with audio replay, deletion, and re-run using the current model.

The default is NVIDIA Parakeet TDT 0.6B v3, running locally through Core ML. It automatically detects and transcribes 25 European languages. Select Whisper Tiny for the smallest resident footprint, or an API model to avoid holding a local model in RAM.

Downloaded transcription models can be removed in **Settings → Models**. The optional On Device (Beta) Gemma cleanup model is managed in **Settings → General → Pro Cleanup**; OpenAI remains the default. Choosing the beta confirms its roughly 4.6 GB download and 5–7 GB loaded unified-memory footprint before downloading automatically. It stays loaded throughout local Pro Mode and unloads five minutes after leaving it.

Shortcuts are managed in **Settings → General → Shortcuts**. Click any shortcut and press a new key combination; changes apply immediately. WhisprGo prevents duplicates and protects ordinary typing keys from being assigned without a modifier.

## Requirements

- macOS 14 or newer
- Apple silicon for practical local-model performance
- Xcode 26 / Swift 6.2 or newer

## Install

Download the latest `WhisprGo-macOS.zip` from [Releases](https://github.com/Lxvi101/WhisprGo/releases/latest), unzip it, and move **WhisprGo.app** to Applications.

Version 1.0 is ad-hoc signed while Developer ID distribution is being set up. On first launch, Control-click the app, choose **Open**, then confirm. macOS will ask for Microphone and Accessibility access.

## Build

From the project folder:

```sh
zsh Scripts/build-app.sh
```

The packaged app is created at:

```text
.build/WhisprGo.app
```

Open it from Finder or run:

```sh
open '.build/WhisprGo.app'
```

On first launch, allow Microphone and Accessibility access. Accessibility is required for the global shortcut and for inserting text at the active cursor.

## Performance shape

WhisprGo removes avoidable wake-up latency rather than promising impossible zero-time inference:

- The global event tap watches only modifier changes and configured shortcut key edges.
- The AVAudioEngine graph, converter, and output buffer are reused between dictations.
- Microphone packets are resampled from their actual delivered frame count; a preallocated worst-case buffer avoids both truncation and render-thread allocation.
- AirPods mode is on by default and pins this app's input to the built-in Mac microphone without changing the output device.
- By default, the microphone graph and input tap are fully released while idle.
- An explicit “Keep microphone active” setting leaves the hardware stream running for instant response. A lock-free gate exits the callback before conversion, metering, locks, or buffer writes while idle.
- The audio render callback writes its latest level to one relaxed atomic value; it never queues UI work.
- The recording indicator is a layer-backed AppKit pill synchronized to the display, with no SwiftUI invalidation, Combine publishing, implicit layer animation, or text layout in its recording path.
- Audio buffers are handed to inference without a full-array copy and modest buffers are reused between dictations.
- Download progress is coalesced before it reaches the settings UI.
- Silence is rejected before model inference.
- Incomplete or failed microphone conversion is rejected before inference instead of producing a plausible but unrelated transcript.
- Only the selected transcription model is resident continuously. The optional local Pro cleanup model is additionally resident only while local Pro Mode is in use and for a five-minute grace period afterward.
- Local transcription uses Core ML and Apple Neural Engine defaults; local Pro cleanup uses MLX on Apple silicon.
- Cloud dictation reuses a single ephemeral URLSession connection pool.
- Text insertion tries the focused Accessibility element before falling back to Unicode key events.
- History persistence starts only after transcription and text insertion finish; WAV encoding and atomic metadata writes run on a utility-priority actor.

See [Architecture](docs/ARCHITECTURE.md) for the full lifecycle and tradeoffs.

## Privacy

Local model audio never leaves the Mac. OpenAI model audio is uploaded only after a dictation ends—when the push-to-talk shortcut is released or the toggle is stopped. With the On Device Pro cleanup beta, the raw transcript and nearby Accessibility context stay on the Mac and are processed by Gemma through MLX. With the default OpenAI Pro cleanup, that bounded text is sent to GPT-5.6 Luna with API storage disabled. API keys are stored in Keychain. WhisprGo keeps the latest 50 completed dictations as local WAV files and metadata under its Application Support folder; each item or the entire history can be deleted from Settings. If always-active input is enabled, idle samples are discarded immediately and never enter a recording buffer or history.

## Acknowledgements

The interaction and lean native architecture were inspired by [digimata/parrot](https://github.com/digimata/parrot). Parakeet inference is provided by [FluidAudio](https://github.com/FluidInference/FluidAudio), Whisper inference by [Argmax's open-source WhisperKit SDK](https://github.com/argmaxinc/argmax-oss-swift), and local cleanup by [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) with the [Unsloth Gemma 4 E2B MLX conversion](https://huggingface.co/unsloth/gemma-4-E2B-it-UD-MLX-4bit).
