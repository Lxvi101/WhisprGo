# WhisprGo — launch trailer

A 30.85-second, code-rendered launch trailer for WhisprGo, cut to "Glossy Loop". Every frame is a
deterministic function of song time, so the browser preview and the offline 1080p60 export are
identical. The approach and engine follow [mexicat/pdoom-video](https://github.com/mexicat/pdoom-video)
(MIT): the renderer core in `app/src/engine/` is forked from it (see `app/src/engine/LICENSE-pdoom-video`).

The concept, the music map and the plate-by-plate treatment are in [`docs/TREATMENT.md`](docs/TREATMENT.md).

## Layout

- `audio/glossy-loop.m4a`: the track (Suno, 140 BPM, G minor, 18 bars, instrumental).
- `analysis/`: Python (uv) tools that produced the timing data. `analyze.py` writes `data/audio.json`
  from the mix and Demucs stems; `patterns.py` prints the drum/bass/pluck pattern of every bar on a 16th
  grid; `roll.py` renders piano-roll and drum-envelope plots for checking by eye.
- `data/audio.json`: beat grid, downbeats, sections, kick/snare/hat/pluck onsets (snapped to the 16th
  grid), sub-bass notes, 100 fps envelopes and a 44-band spectrum at 60 fps.
- `app/`: the renderer (TypeScript + three.js, bun + Vite).
  - `src/engine/`: timeline playback, motion-blur sampling, post (bloom, grain, vignette), typography.
  - `src/scenes/`: one module per plate, plus `_kit.ts` (the glossy dot, text-to-dots, the logo mark,
    ports of the app's `SignalField` and recording pill) and `logo-data.ts` (the mark's 55 dots).
  - `src/timeline.ts`: the edit, every cut on a beat of the grid.
  - `scripts/render.ts`: offline renderer (headless Chromium → raw frames → ffmpeg).
  - `scripts/render-final.sh`: the final render in three resumable segments, muxed with the audio.

## Requirements

[bun](https://bun.sh), ffmpeg with libx264, and Chromium (Google Chrome if installed, else Playwright's:
`bunx playwright install chromium`). The type is Apple's SF Pro Display/Text/Rounded (from
`/Library/Fonts`, install them from developer.apple.com/fonts) and SF Mono (read from Terminal.app).
The dev server serves them from the system at run time; they are never copied into the repository.

```sh
ffmpeg -i audio/glossy-loop.m4a -ar 44100 audio/glossy-loop.wav   # decoded audio for preview/export
cd app && bun install
```

## Preview

```sh
cd app && bunx vite
```

Open http://localhost:5173 (`?t=10` starts at 10 s). Space plays, ←/→ seek, `,`/`.` step a frame,
`[`/`]` jump between plates, `l` loops the current plate, `h` hides the UI.

## Render

```sh
cd app
zsh scripts/render-final.sh                 # → out/whisprgo-trailer.mp4 (1080p60, motion blur)
bun scripts/render.ts video --samples 1 --preset veryfast --out ../out/draft.mp4   # quick draft
bun scripts/render.ts stills --t 10.5,24 --only speak,logo --out ../out/wip          # check stills
bun scripts/render.ts sheet --cuts --out ../out/cuts.png                             # every cut
```

`render-final.sh --scale 2` renders a true 3840×2160 version.

## Regenerate the timing data

```sh
cd analysis
uv run python -m demucs -n htdemucs -o stems ../audio/glossy-loop.wav
uv run python analyze.py
```
