// Plate 9 — the end card and the loop (outro, beats 64–72: arps and claps, no drums). The logo
// plate's settled frame continues flat: glossy dots, wordmark, tagline. The release line lands on
// the clap (beat 66). From bar 17 the card empties: the wordmark wipes out, and the mark's dots
// drain one after another into a single caret at plate 1's position, blinking on the beat in the
// same phase as the film's first frame, so the end runs seamlessly back into the start.
import type * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font } from '../engine/type';
import { clamp, ease, lerp, prog, hash } from '../engine/util';
import { DotBatch, beatT, CARD, loadWordmark, caretBlink } from './_kit';
import { CARET } from './think';
import { drawCard, logoWorld, TAGLINE } from './logo';

export default class Outro extends Scene {
  dots = new DotBatch(200);
  text = new Layer2D();
  img!: HTMLImageElement;
  logo = logoWorld();

  override async init() { this.img = await loadWordmark(); }

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.ink);

    // the caret the dots drain into (plate 1's caret: its centre)
    const cx = CARET.x + 6 + CARET.w / 2, cy = CARET.y - CARET.h * 0.8 + CARET.h / 2;
    this.dots.clear();
    const n = this.logo.length;
    // drain order: farthest from the caret first, staggered over beats 68–70.5, each flight 0.6 beat
    const order = this.logo.map((p, i) => ({ i, d: Math.hypot(CARD.cx + p.x * CARD.k - cx, CARD.markCy - p.y * CARD.k - cy) }))
      .sort((a, b) => b.d - a.d).map((o, rank) => ({ ...o, rank }));
    const pl = au.env('other', t);
    for (const o of order) {
      const p = this.logo[o.i]!;
      const x0 = CARD.cx + p.x * CARD.k, y0 = CARD.markCy - p.y * CARD.k, r0 = p.r * CARD.k;
      const t0 = B(68 + (o.rank / (n - 1)) * 2.5);
      const u = prog(t, t0, t0 + B(0.6) - B(0), ease.inOutCubic);
      if (u >= 1) continue;
      // a gentle curve into the caret; the dot shrinks to the caret's width
      const bend = Math.sin(Math.PI * u) * 60 * (hash(o.i, 11) - 0.5);
      const x = lerp(x0, cx, u) + bend, y = lerp(y0, cy, u) - bend * 0.4;
      const r = lerp(r0 * (1 + 0.04 * pl), CARET.w / 2, u);
      this.dots.add(x, y, r, 1, 1 - 0.3 * u, 0.9 * (1 - u));
    }
    this.dots.render(renderer, out);

    const c = this.text.ctx;
    this.text.clear();
    const gone = prog(t, B(68), B(68.6), ease.inCubic);
    drawCard(c, this.img, t, B, {
      wipe: 1,
      wipeOut: gone,
      tagline: (i) => 1 - prog(t, B(68.5 + i * 0.25), B(68.9 + i * 0.25), ease.inQuad),
    });
    // release line on the clap
    const kR = prog(t, B(66), B(66) + 0.25, ease.outExpo) * (1 - prog(t, B(68.2), B(68.8), ease.inQuad));
    if (kR > 0) {
      c.font = font('mono', 500, 30);
      c.letterSpacing = '0.5px';
      c.textAlign = 'center';
      c.fillStyle = rgba('bone', kR);
      c.fillText('github.com/Lxvi101/WhisprGo', CARD.cx, CARD.taglineY + 110 + (1 - kR) * 10);
      c.fillStyle = rgba('ash', kR);
      c.font = font('mono', 400, 24);
      c.fillText('free and open source  ·  macOS 14+  ·  Apple silicon', CARD.cx, CARD.taglineY + 156 + (1 - kR) * 10);
      c.textAlign = 'left';
    }
    // the caret: appears as the last dot arrives, then blinks on the beat (as at t = 0)
    const last = B(68 + 2.5 + 0.6);
    if (t >= last - 0.02 && caretBlink(f.beatPhase, t < B(71))) {
      c.fillStyle = rgba('bone', 1);
      c.beginPath();
      c.roundRect(CARET.x + 6, CARET.y - CARET.h * 0.8, CARET.w, CARET.h * clamp((t - last + 0.02) / 0.08), 3);
      c.fill();
    }
    void TAGLINE;
    comp.draw(renderer, this.text.upload(), out);
    return { vignette: 0.32, bloom: 0.5, bloomThreshold: 1.2 };
  }
}
