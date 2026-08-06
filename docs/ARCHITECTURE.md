# Architecture

WhisprGo separates the latency-critical capture path from work that can block, allocate, or touch the network.

```text
configured global shortcut edge
      │
      ▼
HotkeyMonitor ──► AudioCapture ──► TranscriptionRuntime ──► Pro cleanup ──► TextInjector
                       │                    │                    │
                       │                    ├─ Parakeet/Whisper  ├─ GPT-5.6 Luna
                       │                    └─ OpenAI audio      └─ Gemma 4 E2B / MLX
                       ▼
               RecordingOverlay
               (display-synced Core Animation)

After text insertion only:
captured buffer ──► HistoryPersistence actor ──► WAV + compact JSON manifest
```

## Lifecycle

1. The app starts as a menu-bar accessory and installs one narrow CGEvent tap for modifier changes and configured key edges.
2. The selected model downloads automatically if needed, then loads and prewarms. Only that local model remains resident.
3. The persisted shortcut configuration maps key or modifier-only chords to five actions. Push-to-talk starts after a 40 ms modifier-chord disambiguation window and stops on release; all other actions fire once per press or tap. Defaults remain fn hold, fn + shift toggle, right Shift mode switching, right Control + right Shift profile cycling, and Command + Option + V for paste-last.
4. The stop edge snapshots 16 kHz mono Float32 samples. Capture either stays active or releases the graph according to the explicit instant-response setting.
5. Very short or silent buffers are discarded without inference.
6. Source and resampled durations are compared; incomplete capture never reaches a speech model.
7. Local audio goes to FluidAudio/Parakeet or WhisperKit. Cloud audio is encoded as 16-bit WAV and posted to the selected API model.
8. In Pro Mode, the raw transcript and bounded Accessibility context are cleaned by GPT-5.6 Luna by default or the optional 4-bit Gemma 4 E2B MLX beta.
9. Text is inserted directly into the focused Accessibility element when supported, with Unicode CGEvents as the compatibility fallback.
10. After insertion completes, a utility-priority actor encodes the same immutable buffer to WAV and atomically updates a compact manifest. The newest 50 runs are retained.
11. In always-active mode, an atomic gate discards idle callbacks before any conversion, buffering, or history persistence.

## Memory limits

- Capture reserves about 15 seconds of Float32 audio and grows only when required.
- The resampler is preallocated for 16,384 native input frames because Core Audio tap packet sizes may exceed the requested hint; no packet is sized from a fixed 1,024-frame assumption.
- Capture transfers its array to transcription without a second full-sized copy, then reuses only buffers of 30 seconds or less so idle memory remains bounded.
- Recordings are capped at five minutes, preventing an accidental toggle from growing without bound.
- Model changes release the existing pipeline before downloading/loading a replacement, avoiding two resident model graphs.
- Parakeet uses the int8 Core ML encoder and one long-form worker to prevent multi-worker memory spikes.
- Cloud selection releases the local Core ML pipeline entirely.
- Local Pro cleanup keeps Gemma resident throughout Pro Mode, then releases its model container and clears the MLX cache after a five-minute grace period. Its download remains isolated and removable.
- Every new model download has an isolated storage root, so removal reclaims that model without touching any other cache.
- History is bounded to 50 16 kHz mono WAV files. It uses a compact JSON manifest rather than a resident database, and no audio is decoded until the user explicitly replays or re-runs it.
- There is no WebView, analytics SDK, or background sidecar.

## Latency tradeoffs

**Use the Mac microphone instead of AirPods** is on by default. WhisprGo selects the built-in input directly on its Audio Unit and does not alter the system output, so AirPods stay available for high-quality playback even while capture is active.

The default idle policy stops the audio engine, removes its input tap, and releases the converter after every dictation. The next dictation rebuilds the small input graph.

Users can explicitly enable **Keep microphone active between dictations**. In that mode the input hardware and graph remain running, removing device-start latency. The render callback first checks a C11 atomic flag and returns immediately while idle, before resampling, metering, locking, or appending samples. This mode is off by default and its privacy behavior is described next to the setting.

Parakeet v3 uses one long-form worker to cap memory. Its multilingual long-form path disables the mel-context prepend that FluidAudio identifies as a source of decoder drift, and a system-language script hint prevents noisy audio from switching into an unrelated alphabet.

Local model prewarming reduces first-dictation latency and peak Core ML specialization memory, at the cost of a longer one-time model preparation step. Cloud latency is network dependent; the client reuses a URLSession to preserve connection pooling between dictations.

The overlay does not observe an audio-level model. The real-time callback overwrites one C11 atomic Float, and a 60 fps maximum display link reads only the newest value. Prebuilt dot layers update inside disabled Core Animation transactions; no update can accumulate in a queue.

History never runs alongside transcription by design. The engine injects the result and records latency first, then hands the immutable buffer to a serial utility actor. WAV conversion, disk writes, manifest pruning, playback, and saved-audio decoding therefore add no work to model inference or text insertion.
