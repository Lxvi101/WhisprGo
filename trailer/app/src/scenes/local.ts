// Plate 5 — "On your Mac." (break 1, beats 34–37: bass out, hats only). The app's own recording
// pill, large, its 11×5 meter driven by the hats exactly as RecordingOverlay drives it from the
// microphone; it switches to the transcribing spinner and is dismissed with the app's timings.
// The spec lines type out in bursts on the hats.
import type * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font } from '../engine/type';
import { clamp, ease, prog } from '../engine/util';
import { beatT, drawOverlayPill, presentSpring } from './_kit';

const SPEC = ['Parakeet TDT 0.6B v3  ·  Core ML  ·  Neural Engine', 'Local models: your audio never leaves the Mac.'];

export default class Local extends Scene {
  text = new Layer2D();

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.ink);
    const c = this.text.ctx;
    this.text.clear();

    // the pill: present on the clap, meter on the hats, spinner from beat 35.5, dismiss at 36.6
    const tIn = B(34), tSpin = B(35.5), tOut = B(36.6);
    const level = clamp(0.18 + 0.9 * au.hit('hat', t, 0.07) + 0.4 * au.env('high', t));
    const dis = prog(t, tOut, tOut + 0.2, ease.inQuad);
    const scale = t < tOut ? presentSpring(t - tIn) : 1 - 0.1 * dis;
    const alpha = Math.min(prog(t, tIn, tIn + 0.14, ease.outQuad), 1 - dis);
    const spin = t >= tSpin ? (((t - tSpin) / 0.72) * Math.PI * 2) % (Math.PI * 2) : -1;
    drawOverlayPill(c, 960, 380, 5.2, level, { spin, scale, alpha });

    // title and spec
    const kT = prog(t, tIn, tIn + 0.25, ease.outExpo);
    c.textAlign = 'center';
    c.font = font('display', 700, 132);
    c.letterSpacing = '-3px';
    c.fillStyle = rgba('bone', kT);
    c.fillText('On your Mac.', 960, 740 + (1 - kT) * 24);
    c.font = font('mono', 500, 30);
    c.letterSpacing = '0.5px';
    // spec lines appear in bursts: a chunk of characters per hat
    const hats = au.events('hat', B(34.4), B(37)).map((e) => e[0]!);
    SPEC.forEach((line, i) => {
      const my = hats.filter((h, k) => h <= t && (i === 0 ? k < 3 : k >= 3));
      const per = Math.ceil(line.length / 3);
      const n = Math.min(line.length, my.length * per);
      if (n <= 0) return;
      c.fillStyle = rgba(i === 0 ? 'ash' : 'bone', 1);
      const full = c.measureText(line).width;
      c.textAlign = 'left';
      c.fillText(line.slice(0, n), 960 - full / 2, 830 + i * 52);
    });
    c.textAlign = 'left';
    comp.draw(renderer, this.text.upload(), out);
    return { vignette: 0.35 };
  }
}
