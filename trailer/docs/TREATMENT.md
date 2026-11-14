# WhisprGo launch trailer — treatment

## The idea in one paragraph

The film argues one thing in 30 seconds: **you speak about four times faster than you type, and
WhisprGo closes that gap with a single key.** It opens on a caret typing "You type at 40." one
character per pluck of the arpeggio, then "You speak at 150." arrives all at once in dots. The build
is a macro of the `fn` key, the drop is the key going down, and from there the film follows the app's
own loop (hold, speak, let go, it's typed) before a fast run through the features, the menu bar, and
the mark. Running through everything is **the dot**, the app's only ornament: the typed speech, the
menu's SignalField, the recording pill's 11×5 meter, and the 55 dots of the logo are all the same
glossy dot. The last frame is the first frame, so the film loops.

## Style

- Monochrome, like the app: ink `#050506`, greys, bone `#F5F5F7`, and the light surface `#FAFAFA` for
  the one inverted plate. Gloss (specular highlights on dots, keycaps and spheres) is the only thing
  allowed to bloom; type stays crisp.
- Type is the system's: SF Pro Display for statements, SF Pro Text/Rounded for UI, SF Mono for the
  machine voice (readouts, footnotes, specs).
- Real UI, quoted exactly: the SignalField formula, the recording pill's meter/spinner/spring, the
  menu's layout, the segmented control's critically damped pill, the default shortcut table.
- Claims come from the README and source (25 languages via Parakeet TDT 0.6B v3, local audio never
  leaves the Mac, default shortcuts, Instruct Pro). The 40 / 150 wpm figures are commonly cited
  averages for typing and speaking.

## The music (analysis/analyze.py → data/audio.json)

140 BPM half-time trap, G minor, exactly 18 bars (30.85 s), so it loops. Clap on beat 3 of every
bar; 808 kicks in a tresillo (beats 1, 2&, 4) in the drops.

| bars | beats | section | what the music does |
|---|---|---|---|
| 0–3 | 0–16 | intro | glossy 16th-note pluck arps, pads, clap |
| 4–5 | 16–24 | build | 8th-note hats enter |
| 6–8½ | 24–34 | drop A | 808 + sub (Eb → D), one-beat stop at beat 31, kick + G at 32 |
| 8½–9¼ | 34–37 | break 1 | bass and kicks out, hats only |
| 9¼–12½ | 37–50 | drop B | kick back on beat 2; bass stop at beats 42–43.5 |
| 12½–13¼ | 50–53 | break 2 | bass out, hats only |
| 13¼–16 | 53–64 | drop C | full groove, snare roll into bar 16 |
| 16–17 | 64–72 | outro | arps and claps return, no drums; loops into bar 0 |

## Plates

| plate | beats | idea | sync |
|---|---|---|---|
| `think` | 0–16 | "You type at 40." typed; "You speak at 150." in dots | one character per pluck (15 plucks, 15 characters); "150." on the clap |
| `fn` | 16–24 | 3D macro of the keyboard corner, backlit legends | backlight breathes on each hat; "Hold fn." on the clap; cut on bar 5; key bottoms out on the drop |
| `speak` | 24–32 | the SignalField as a 3D field of glossy spheres | columns = mirrored 44-band spectrum; cuts on the tresillo kicks; collapse + transcribing sweep on the stop: "Let go." |
| `typed` | 32–34 | inverted plate: the dictation lands at the cursor at once | kick + G |
| `local` | 34–37 | the recording pill, large: meter → spinner → dismiss | meter driven by the hats; spec lines type in bursts per hat |
| `montage` | 37–50 | languages · model · hands-free · Pro · shortcuts | a greeting per 16th; the pill slides per beat; fn + ⇧ on the stop's clap; strikes on the kicks; a row per 8th |
| `menubar` | 50–53 | menu bar slides in, menu opens, dive into the field | bar on the clap, click on the next 8th, dive into the downbeat |
| `logo` | 53–64 | 55 spheres: the pill's 11×5 meter becomes the 55-dot mark | all land on the kick at 54.5; dolly-zoom settle on the Eb (56); kick rings; tagline on kicks 59 / 61 / 62.5 |
| `outro` | 64–72 | end card, release line, the mark drains into the caret | line on the clap (66); card empties from bar 17; caret in phase with frame 0 |

## Technical conventions

See `app/src/engine/` and the pdoom-video engine guide: deterministic, cuts on beats, motion blur by
adaptive sub-frame averaging (`--samples auto --shutter 0.2`). The `fn` plate's depth of field
jitters a thin-lens camera across those sub-frames (capped at 108).
