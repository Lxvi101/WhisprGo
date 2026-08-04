# Architecture

WhisprGo separates the latency-critical capture path from work that can block, allocate, or touch the network.

```text
fn hold / fn + shift edge
      │
      ▼
HotkeyMonitor ──► AudioCapture ──► TranscriptionRuntime ──► TextInjector
                       │                    │
                       │                    ├─ one Parakeet or Whisper pipeline
                       │                    └─ one reusable OpenAI client
                       ▼
               RecordingOverlay
               (display-synced Core Animation)
```

## Lifecycle

1. The app starts as a menu-bar accessory and installs one modifier-only CGEvent tap.
2. The selected model downloads automatically if needed, then loads and prewarms. Only that local model remains resident.
3. Holding fn starts push-to-talk after a 40 ms chord-disambiguation window; releasing fn stops. fn + shift is an independent start/stop toggle.
4. The stop edge snapshots 16 kHz mono Float32 samples. Capture either stays active or releases the graph according to the explicit instant-response setting.
5. Very short or silent buffers are discarded without inference.
6. Source and resampled durations are compared; incomplete capture never reaches a speech model.
7. Local audio goes to FluidAudio/Parakeet or WhisperKit. Cloud audio is encoded as 16-bit WAV and posted to the selected API model.
8. Text is inserted directly into the focused Accessibility element when supported, with Unicode CGEvents as the compatibility fallback.
9. No audio or transcript is persisted. In always-active mode, an atomic gate discards idle callbacks before any conversion or buffering.

## Memory limits

- Capture reserves about 15 seconds of Float32 audio and grows only when required.
- The resampler is preallocated for 16,384 native input frames because Core Audio tap packet sizes may exceed the requested hint; no packet is sized from a fixed 1,024-frame assumption.
- Capture transfers its array to transcription without a second full-sized copy, then reuses only buffers of 30 seconds or less so idle memory remains bounded.
- Recordings are capped at five minutes, preventing an accidental toggle from growing without bound.
- Model changes release the existing pipeline before downloading/loading a replacement, avoiding two resident model graphs.
- Parakeet uses the int8 Core ML encoder and one long-form worker to prevent multi-worker memory spikes.
- Cloud selection releases the local Core ML pipeline entirely.
- Every new model download has an isolated storage root, so removal reclaims that model without touching any other cache.
- There is no transcript history, database, WebView, analytics SDK, or background sidecar.

## Latency tradeoffs

**Use the Mac microphone instead of AirPods** is on by default. WhisprGo selects the built-in input directly on its Audio Unit and does not alter the system output, so AirPods stay available for high-quality playback even while capture is active.

The default idle policy stops the audio engine, removes its input tap, and releases the converter after every dictation. The next dictation rebuilds the small input graph.

Users can explicitly enable **Keep microphone active between dictations**. In that mode the input hardware and graph remain running, removing device-start latency. The render callback first checks a C11 atomic flag and returns immediately while idle, before resampling, metering, locking, or appending samples. This mode is off by default and its privacy behavior is described next to the setting.

Parakeet v3 uses one long-form worker to cap memory. Its multilingual long-form path disables the mel-context prepend that FluidAudio identifies as a source of decoder drift, and a system-language script hint prevents noisy audio from switching into an unrelated alphabet.

Local model prewarming reduces first-dictation latency and peak Core ML specialization memory, at the cost of a longer one-time model preparation step. Cloud latency is network dependent; the client reuses a URLSession to preserve connection pooling between dictations.

The overlay does not observe an audio-level model. The real-time callback overwrites one C11 atomic Float, and a 60 fps maximum display link reads only the newest value. Eleven prebuilt layers are transformed inside disabled Core Animation transactions; no update can accumulate in a queue.
