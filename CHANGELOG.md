# Changelog

All notable changes to WhisprGo are documented here.

## 1.1.0 — 2026-08-06

- Optional beta for 4-bit Gemma 4 E2B cleanup through MLX, with OpenAI kept as the default, automatic download, clear storage/RAM warnings, and delayed unloading after local Pro Mode.
- Configurable global shortcuts with press-to-record editing, duplicate protection, live updates, and restore defaults.
- Dynamic shortcut hints throughout the menu bar and Settings.
- On-device Pro cleanup and bounded nearby-text context keep screenshots out of the pipeline.

## 1.0.0 — 2026-08-04

- Native menu-bar dictation with fn push-to-talk and fn + shift toggle mode.
- NVIDIA Parakeet TDT 0.6B v3 as the fast, multilingual default.
- Automatic local-model downloads, visible storage state, and safe removal controls.
- Local Whisper and OpenAI transcription model choices.
- Mac microphone routing by default so AirPods keep high-quality playback.
- Explicit opt-in always-active microphone mode for minimum start latency.
- Display-synced, allocation-free recording overlay and bounded audio buffers.
- Original WhisprGo app icon, wordmark, and compositor-only startup animation.
- Automatic migration of early Whispr Flow settings, model downloads, and API key.
