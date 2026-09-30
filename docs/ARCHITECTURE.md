# Architecture

WhisprGo separates the latency-critical capture path from work that can block, allocate, or touch the network.

```text
configured global shortcut edge
      │
      ▼
                              ┌─ Fast ─► TranscriptionRuntime ─► Parakeet/Whisper/OpenAI ─────────────┐
HotkeyMonitor ─► AudioCapture ┼─ Instruct Pro ─► TranscriptionRuntime ─► GPT-5.6 Luna cleanup ───────┼─► TextInjector
                              └─ Gemini Pro ─► Gemini 3.5 Transcribe Smart (one pass) ───────────────┘
                       ▼
               RecordingOverlay
               (display-synced Core Animation)

After text insertion only:
captured buffer ──► HistoryPersistence actor ──► WAV + compact JSON manifest
```

## Lifecycle

1. The app starts as a menu-bar accessory and installs one narrow CGEvent tap for modifier changes and configured key edges.
2. In Fast Mode and Instruct Pro, the selected transcription model downloads automatically if needed, then loads and prewarms. Gemini Pro instead releases that runtime and waits for audio without preloading a model. The Pro engine choice is persisted and defaults to Instruct Pro.
3. The persisted shortcut configuration maps key or modifier-only chords to five actions. Push-to-talk starts after a 40 ms modifier-chord disambiguation window and stops on release; all other actions fire once per press or tap. Defaults remain fn hold, fn + shift toggle, right Shift mode switching, right Control + right Shift profile cycling, and Command + Option + V for paste-last.
4. The stop edge snapshots 16 kHz mono Float32 samples. Capture either stays active or releases the graph according to the explicit instant-response setting.
5. Very short or silent buffers are discarded without inference.
6. Delivered and retained durations are compared; incomplete capture never reaches a speech model.
7. In Fast Mode, local audio goes to FluidAudio/Parakeet or WhisperKit; a selected OpenAI model receives a 16-bit WAV instead.
8. In Instruct Pro, the selected Fast model produces a raw transcript and GPT-5.6 Luna cleans it using the selected profile plus bounded nearby text. If cleanup fails, WhisprGo inserts the raw transcript with a warning. In Gemini Pro, the 16-bit WAV goes directly to Gemini 3.5 Transcribe in Smart mode, while bounded nearby text and the selected profile are reduced to at most 100 custom-vocabulary hints.
9. Text is inserted directly into the focused Accessibility element when supported, with Unicode CGEvents as the compatibility fallback.
10. After insertion completes, a utility-priority actor encodes the same immutable buffer to WAV and atomically updates a compact manifest. The newest 50 runs are retained.
11. In always-active mode, an atomic gate discards idle callbacks before any conversion, buffering, or history persistence.

## Memory limits

- Capture reserves about 15 seconds of Float32 audio and grows only when required.
- Capture uses three reusable 4,096-frame Audio Queue buffers. Core Audio performs hardware-format conversion into the app's 16 kHz mono Float32 stream.
- Capture transfers its array to transcription without a second full-sized copy, then reuses only buffers of 30 seconds or less so idle memory remains bounded.
- Recordings are capped at five minutes, preventing an accidental toggle from growing without bound.
- Model changes release the existing pipeline before downloading/loading a replacement, avoiding two resident model graphs.
- Parakeet uses the int8 Core ML encoder and one long-form worker to prevent multi-worker memory spikes.
- Cloud selection releases the local Core ML pipeline entirely.
- Gemini Pro releases the selected transcription runtime, while Instruct Pro keeps it resident for its required first pass.
- Every new model download has an isolated storage root, so removal reclaims that model without touching any other cache.
- History is bounded to 50 16 kHz mono WAV files. It uses a compact JSON manifest rather than a resident database, and no audio is decoded until the user explicitly replays or re-runs it.
- There is no WebView, analytics SDK, or background sidecar.

## Latency tradeoffs

WhisprGo binds an input-only Core Audio Audio Queue directly to the selected microphone's stable device UID and does not alter the system output. This avoids AVAudioEngine's private aggregate device and its asynchronous default-device resets. Bluetooth headset microphones are excluded by Core Audio transport type. Users can explicitly allow trusted non-Bluetooth inputs, such as a RØDE USB microphone, by stable device UID; an allowed connected microphone takes priority over the built-in input.

The default idle policy stops and disposes the input queue after every dictation. The next dictation creates a new queue and binds it to the current preferred route.

Users can explicitly enable **Keep microphone active between dictations**. In that mode the input queue and hardware remain running, removing device-start latency. The queue callback first checks a C11 atomic flag and returns immediately while idle, before metering, locking, or appending samples. This mode is off by default and its privacy behavior is described next to the setting.

Parakeet v3 uses one long-form worker to cap memory. Its multilingual long-form path disables the mel-context prepend that FluidAudio identifies as a source of decoder drift, and a system-language script hint prevents noisy audio from switching into an unrelated alphabet.

Local model prewarming reduces first-dictation latency and peak Core ML specialization memory, at the cost of a longer one-time model preparation step. Cloud latency is network dependent; the client reuses a URLSession to preserve connection pooling between dictations.

The overlay does not observe an audio-level model. The real-time callback overwrites one C11 atomic Float, and a 60 fps maximum display link reads only the newest value. Prebuilt dot layers update inside disabled Core Animation transactions; no update can accumulate in a queue.

History never runs alongside transcription by design. The engine injects the result and records latency first, then hands the immutable buffer to a serial utility actor. WAV conversion, disk writes, manifest pruning, playback, and saved-audio decoding therefore add no work to model inference or text insertion.
