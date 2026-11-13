<p align="center">
  <img src="Assets/WhisprGo.svg" width="520" alt="WhisprGo">
</p>

WhisprGo is a low-latency macOS dictation engine that lives in the menu bar. By default, hold **fn** for push-to-talk, then release it to type. Press **fn + shift** once to start hands-free listening and press the chord again to stop and type. Every global shortcut is configurable in Settings.

## What is included

- A native SwiftUI menu-bar interface and Settings window.
- Configurable shortcuts for push-to-talk, hands-free dictation, mode switching (double-tap Right Shift cycles Fast → Pro → ChatGPT), Pro profiles, and pasting the last dictation.
- Automatic one-time download and warm-up for Parakeet and Whisper models.
- NVIDIA Parakeet TDT 0.6B v3 plus local Whisper Tiny, Base, Small, and Large v3 Turbo choices.
- OpenAI `gpt-transcribe`, `gpt-4o-mini-transcribe`, and `whisper-1` choices.
- A selectable Pro engine: Instruct Pro uses the chosen Fast transcription model followed by GPT-5.6 Luna cleanup with full profile and nearby-text context; Gemini 3.5 Transcribe Smart provides an optional one-pass path with vocabulary hints.
- ChatGPT Mode: transcription with your ChatGPT plan through a browser sign-in, with no API key or local model. WhisprGo keeps its own ChatGPT session in Keychain and never reads or changes a Codex CLI sign-in.
- Google and OpenAI API keys stored in macOS Keychain.
- Delivery that always says where the text went: typed into the focused field, pasted into the app you dictated into, or copied for ⌘V when that app is no longer in front. WhisprGo never brings another app forward to paste.
- Built-in microphone priority that ignores Bluetooth headset inputs while allowing explicit USB/external microphone exceptions.
- Optional always-active input for the lowest possible shortcut-to-audio latency.
- Optional launch at login.
- Signed, in-app updates that download, verify, install, and relaunch automatically.
- A local history of the latest 50 dictations with audio replay, deletion, and re-run using the current model. The menu shows the three most recent; click one to copy it.

The default is NVIDIA Parakeet TDT 0.6B v3, running locally through Core ML. It automatically detects and transcribes 25 European languages. Select Whisper Tiny for the smallest resident footprint, or an API model to avoid holding a local model in RAM.

Downloaded transcription models can be removed in **Settings → Models**. Choose the Pro engine in **Settings → General → Dictation**. Instruct Pro requires an OpenAI API key; Gemini 3.5 Transcribe requires a Google API key. Both are managed in **Settings → Accounts**, together with the ChatGPT sign-in for ChatGPT Mode. Any retired Gemma cleanup download from an older release remains user-removable from the Dictation section.

Shortcuts are managed in **Settings → General → Shortcuts**. Click any shortcut and press a new key combination; changes apply immediately. WhisprGo prevents duplicates and protects ordinary typing keys from being assigned without a modifier.

## Requirements

- macOS 14 or newer
- Apple silicon for practical local-model performance
- Xcode 26 and Swift 6.3 or newer (mlx-swift 0.32 requires Swift tools 6.3; if Xcode bundles an older Swift, install the swift.org 6.3 toolchain and build with `TOOLCHAINS` set to its identifier)

## Install

Download the latest DMG from [Releases](https://github.com/Lxvi101/WhisprGo/releases/latest), open it, and drag **WhisprGo** to Applications. This one bridge installation enables signed automatic updates for future releases. WhisprGo then checks in the background, verifies both the signed feed and update archive, and can install and relaunch without sending users back to GitHub.

The Developer ID signature keeps WhisprGo's identity stable across releases, so macOS does not treat every update as a different app. macOS will ask for Microphone and Accessibility access on the first signed installation.

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
- A Core Audio input queue is bound directly to the selected microphone by stable device UID, avoiding AVAudioEngine's private aggregate-device resets.
- Core Audio converts the microphone's hardware format directly to 16 kHz mono Float32 in reusable queue buffers.
- The app pins capture to the built-in Mac microphone without changing the output device. Bluetooth inputs are ignored; trusted non-Bluetooth microphones can be explicitly allowed by stable device UID in Settings.
- By default, the input queue and microphone device are fully released while idle.
- An explicit “Keep microphone active” setting leaves the hardware stream running for instant response. A lock-free gate exits the callback before conversion, metering, locks, or buffer writes while idle.
- The audio queue callback writes its latest level to one relaxed atomic value; it never queues UI work.
- The recording indicator is a layer-backed AppKit pill synchronized to the display, with no SwiftUI invalidation, Combine publishing, implicit layer animation, or text layout in its recording path.
- Audio buffers are handed to inference without a full-array copy and modest buffers are reused between dictations.
- Download progress is coalesced before it reaches the settings UI.
- Silence is rejected before model inference.
- Incomplete or failed microphone conversion is rejected before inference instead of producing a plausible but unrelated transcript.
- Only the selected transcription model is resident. Instruct Pro keeps it ready for the first pass; Gemini Pro releases it because Gemini receives the audio directly.
- Local transcription uses Core ML and Apple Neural Engine defaults.
- Cloud dictation reuses a single ephemeral URLSession connection pool.
- ChatGPT Mode opens its HTTPS connection and renews a nearly expired token when recording starts, trims silence around speech, and uploads 32 kbps AAC instead of WAV (roughly 4–7× less data). The account token stays in memory, so release waits only on the upload and ChatGPT's response.
- Instruct Pro can prepare cleanup during pauses with Phonon or Parakeet. It makes at most three draft attempts in the first 30 seconds and reuses cleanup only when it matches the complete final transcript, profile, and context. Turn off **Prepare Pro during pauses** in General settings to avoid extra API requests.
- Pro Mode gets the same cloud speed work. Gemini Pro trims silence and sends 32 kbps AAC inline with the transcription request: one round trip instead of an upload followed by a request, and no temporary file at Google. If Google refuses inline audio, WhisprGo falls back to the Files API upload for that session and returns text without waiting for the file's deletion. Instruct Pro opens its OpenAI cleanup connection when recording starts, and cloud Fast models (alone or under Instruct Pro) also trim silence, upload AAC instead of WAV, and connect while you speak. General settings show the latest dictation's total delay; hover over the time for capture, draft wait, transcription, cleanup, and insertion timings.
- Text insertion tries the focused Accessibility element before falling back to ⌘V into the same app, and copies instead of pasting when you have switched apps.
- History persistence starts only after transcription and text insertion finish; WAV encoding and atomic metadata writes run on a utility-priority actor.

See [Architecture](docs/ARCHITECTURE.md) for the full lifecycle and tradeoffs.

## Privacy

Local transcription audio never leaves the Mac. OpenAI Fast model audio and Gemini Pro audio are uploaded only after a dictation ends—when the push-to-talk shortcut is released or the toggle is stopped. Instruct Pro first transcribes with the selected Fast model, then sends the transcript, profile instructions, and enabled bounded Accessibility context to OpenAI for cleanup. Gemini Pro sends the audio to Gemini Smart transcription in one pass and reduces enabled context to bounded custom-vocabulary hints. ChatGPT Mode uploads the recording to ChatGPT under your signed-in account after the dictation ends; ChatGPT reports keeping uploaded dictation audio for up to 30 days. It uses the private endpoint the ChatGPT apps use, so OpenAI may change or limit it. Gemini Pro normally sends the audio inline, so Google stores no file. Only when Google refuses inline audio does WhisprGo upload a temporary file, request its deletion after the response, and rely on Google's automatic expiry as a backstop. API keys are stored in Keychain. WhisprGo keeps the latest 50 completed dictations as local WAV files and metadata under its Application Support folder; each item or the entire history can be deleted from Settings. If always-active input is enabled, idle samples are discarded immediately and never enter a recording buffer or history.

**Prepare Pro during pauses** is enabled by default for Instruct Pro with Phonon or Parakeet. Draft transcripts, the profile, and enabled context can reach OpenAI while recording, including a recording you later cancel. Audio remains local for those models. Disable this setting to send only the final transcript after recording stops. Drafts remain in memory for one recording and are never added to history. Latency logs contain timings and a cleanup-reuse flag, not dictation content.

## Acknowledgements

The interaction and lean native architecture were inspired by [digimata/parrot](https://github.com/digimata/parrot). Parakeet inference is provided by [FluidAudio](https://github.com/FluidInference/FluidAudio), and Whisper inference by [Argmax's open-source WhisperKit SDK](https://github.com/argmaxinc/argmax-oss-swift).
