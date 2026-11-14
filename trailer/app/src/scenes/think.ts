// Plate 1 — "40 / 150" (intro, bars 0–3). A caret on black. "You type at 40." is typed one
// character per pluck of the arpeggio (the 15 plucks of bars 0–1, hesitation before "at" and
// the quick 16ths of "40." included); "You speak at 150." arrives as the voice would: in dots,
// one breath, landing "150." on the clap. The first frame is the outro's last frame (the loop).
import type * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font, glyphX } from '../engine/type';
import { clamp, ease, prog, smoothstep, springStep, hash } from '../engine/util';
import { DotBatch, textDots, beatT, type TextDot } from './_kit';

export const CARET = { x: 200, y: 470, h: 104, w: 6 };
/** Caret blink: on for the first half of every beat (shared with the outro so the loop matches). */
export const caretOn = (beatPhase: number) => (beatPhase < 0.5 ? 1 : 0);

const TYPED = 'You type at 40.';
const SPOKEN = 'You speak at 150.';
const MONO = 96;

export default class Think extends Scene {
  text = new Layer2D();
  dots = new DotBatch(20000);
  keyT: number[] = [];
  spoken!: { dots: TextDot[]; width: number };
  wordStart: number[] = [];
  wordAt: number[] = [];

  override init() {
    const au = this.ctx.audio;
    // one keystroke per pluck from beat 0.5 on (fall back to the 8th grid if analysis changes)
    const plucks = au.events('pluck', beatT(au, 0.4), beatT(au, 7.9)).map((e) => e[0]!);
    this.keyT = plucks.length >= TYPED.length ? plucks.slice(0, TYPED.length) : [...TYPED].map((_, i) => beatT(au, 0.5 + i * 0.5));
    this.spoken = textDots(SPOKEN, 'display', 800, 176, 9, { min: 0.18 });
    // word boundaries in the dot grid (by x) and when each word is spoken (beats)
    const gx = glyphX(SPOKEN, 'display', 800, 176);
    const starts = [0, 4, 10, 13]; // char index of You / speak / at / 150.
    this.wordStart = starts.map((i) => gx.xs[i]!);
    this.wordAt = [8.5, 9.0, 9.75, 10.0].map((x) => beatT(au, x));
  }

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    clearRT(renderer, out, LIN.ink);
    const c = this.text.ctx;
    this.text.clear();

    // ---- line 1: typed
    c.font = font('mono', 500, MONO);
    c.letterSpacing = '-2px';
    const typedN = this.keyT.filter((k) => t >= k).length;
    const shown = TYPED.slice(0, typedN);
    const gx = glyphX(TYPED, 'mono', 500, MONO, -2);
    const exitK = prog(t, beatT(au, 14), beatT(au, 15.6), ease.inOutCubic); // the typed line dims: slow
    for (let i = 0; i < typedN; i++) {
      const age = t - this.keyT[i]!;
      const pop = 1 + 0.08 * Math.exp(-age / 0.05);
      const flash = Math.exp(-age / 0.09);
      c.save();
      c.translate(CARET.x + gx.xs[i]!, CARET.y);
      c.scale(pop, pop);
      c.fillStyle = rgba('bone', (0.92 + 0.08 * flash) * (1 - 0.72 * exitK));
      c.fillText(TYPED[i]!, 0, 0);
      c.restore();
    }
    // caret: solid while typing, blinking on the beat otherwise; it hands over to line 2 at beat 8
    const lastKey = typedN ? this.keyT[typedN - 1]! : -1;
    const typing = typedN > 0 && typedN < TYPED.length ? 1 : t - lastKey < 0.25 ? 1 : 0;
    const blink = typing || caretOn(f.beatPhase);
    const caretX = CARET.x + (typedN ? (typedN < TYPED.length ? gx.xs[typedN]! : gx.width) : 0) + 6;
    const caretGone = t >= beatT(au, 8);
    if (!caretGone && blink) {
      c.fillStyle = rgba('bone', 1);
      c.beginPath();
      c.roundRect(caretX, CARET.y - CARET.h * 0.8, CARET.w, CARET.h, 3);
      c.fill();
    }
    // footnotes (mono, ash): what the numbers are
    const note = (s: string, x: number, y: number, at: number, a = 1) => {
      const k = prog(t, at, at + 0.25, ease.outCubic);
      if (k <= 0) return;
      c.font = font('mono', 400, 26);
      c.letterSpacing = '0.5px';
      c.fillStyle = rgba('ash', k * a);
      c.fillText(s, x, y + (1 - k) * 8);
    };
    note('words per minute, typing', CARET.x + 4, CARET.y + 64, beatT(au, 8), 1 - 0.6 * exitK);

    // ---- line 2: spoken, in dots
    const y2 = 760;
    const d = this.dots;
    d.clear();
    const voice = au.env('other', t);
    const out2 = prog(t, beatT(au, 15.5), beatT(au, 16), ease.inQuad); // scatter out before the cut
    for (const p of this.spoken.dots) {
      let w = 0;
      for (let k = 0; k < this.wordStart.length; k++) if (p.x + 4 >= this.wordStart[k]!) w = k;
      // each word is voiced left to right across ~120 ms, like a waveform passing
      const local = (p.x - this.wordStart[w]!) / 900;
      const t0 = this.wordAt[w]! + local * 0.5;
      const a = t - t0;
      if (a <= 0) continue;
      const s = Math.max(0, springStep(a * 1.4, 3.2, 0.42));
      const wob = 1 + 0.18 * voice * Math.sin(p.col * 0.9 - t * 11 + p.row * 0.4) * Math.exp(-a * 0.6);
      const h1 = hash(p.col, p.row, 7);
      const dx = out2 * (h1 - 0.5) * 240, dy = -out2 * (40 + 260 * hash(p.col, p.row, 9));
      const r = 3.9 * Math.sqrt(p.cov) * s * wob * (1 - out2 * 0.7);
      d.add(CARET.x + p.x + dx, y2 + p.y + dy, r, 1.0, 1 - out2, 0.9);
    }
    note('words per minute, speaking', CARET.x + 4, y2 + 64, beatT(au, 12), 1 - out2);
    // the comparison, on the last clap of the intro
    const cmp = prog(t, beatT(au, 14), beatT(au, 14.4), ease.outExpo);
    if (cmp > 0) {
      c.font = font('mono', 500, 30);
      c.letterSpacing = '0px';
      c.fillStyle = rgba('bone', cmp * (1 - out2));
      c.textAlign = 'right';
      c.fillText('3.75× faster', CARET.x + this.spoken.width - 12, y2 + 64 + (1 - cmp) * 10);
      c.textAlign = 'left';
    }

    d.render(renderer, out);
    comp.draw(renderer, this.text.upload(), out);
    // a small lift on the claps (beat 3 of each bar)
    const clap = au.hit('snare', t, 0.12);
    return { exposure: 1 + 0.06 * clap * smoothstep(0, 1, 1), vignette: 0.32 };
  }
}
