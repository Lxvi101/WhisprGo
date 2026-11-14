// The edit: which plate plays when. Every boundary is a beat of the analysed grid
// (data/audio.json: 140 BPM, 4 beats a bar, beat 0 = the first downbeat), chosen from the
// arrangement described in docs/TREATMENT.md.
import type { TimelineEntry } from './engine/engine';
import type { SceneClass } from './engine/scene';
import type { AudioData } from './engine/audio';

// Scene modules are discovered lazily so a missing/broken scene never breaks the build.
const modules = import.meta.glob<{ default: SceneClass }>('./scenes/*.ts');
const scene = (name: string) => () => {
  const m = modules[`./scenes/${name}.ts`];
  return m ? m() : Promise.reject(new Error(`scene module not found: scenes/${name}.ts`));
};

/** Beat anchors of the arrangement (see the section map in analysis/analyze.py). */
export const BEAT = {
  build: 16, // bar 4: 8th-note hats enter
  dropA: 24, // bar 6: 808 + sub (Eb)
  stop: 31, // the bass and hats stop for one beat
  land: 32, // bar 8: kick + G
  break1: 34, // bass out, hats only
  dropB: 37, // kick returns on beat 2 of bar 9
  models: 40, // bar 10
  handsfree: 42, // one-and-a-half-beat bass stop
  pro: 44.5,
  break2: 50, // bass out, hats only
  dropC: 53, // kick returns on beat 2 of bar 13
  outro: 64, // bar 16: the arps return, no drums but the clap
  loop: 72, // bar 18 = bar 0
} as const;

export function makeTimeline(au: AudioData): TimelineEntry[] {
  const b = (x: number) => au.timeOfBeat(x);
  const E = (id: string, file: string, start: number, end: number, extra: Partial<TimelineEntry> = {}): TimelineEntry =>
    ({ id, load: scene(file), start, end, ...extra });

  return [
    E('think', 'think', 0, b(BEAT.build)),
    // (the thin-lens jitter is noise the adaptive sampler would chase to 324 sub-frames)
    E('fn', 'fn', b(BEAT.build), b(BEAT.dropA), { maxSamples: 108 }),
    E('speak', 'speak', b(BEAT.dropA), b(BEAT.land)),
    E('typed', 'typed', b(BEAT.land), b(BEAT.break1)),
    E('local', 'local', b(BEAT.break1), b(BEAT.dropB)),
    E('montage', 'montage', b(BEAT.dropB), b(BEAT.break2)),
    E('menubar', 'menubar', b(BEAT.break2), b(BEAT.dropC)),
    E('logo', 'logo', b(BEAT.dropC), b(BEAT.outro)),
    E('outro', 'outro', b(BEAT.outro), au.duration),
  ];
}
