// Plate 4 — "Typed." (bar 8, beats 32–34). The kick and the bass's jump to G land the text:
// the frame inverts to the light surface and the whole dictation is there at once, at the
// cursor, where plate 1 needed a pluck per character. The flat line of dots from the previous
// plate becomes the text's baseline, then the insertion highlight sweeps off it.
import type * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font, glyphX } from '../engine/type';
import { ease, prog, lerp } from '../engine/util';
import { beatT, caretBlink } from './_kit';

const LINES = ['Thursday at 3 works.', 'I’ll bring the deck.'];
const X = 200, Y0 = 470, LH = 150, PX = 128;

export default class Typed extends Scene {
  text = new Layer2D();

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.paper);
    const c = this.text.ctx;
    this.text.clear();

    // insertion highlight: a pale selection block sweeps off the text left to right
    const sweep = prog(t, B(32), B(32) + 0.22, ease.outCubic);
    c.font = font('display', 600, PX);
    c.letterSpacing = '-3px';
    let endX = X;
    LINES.forEach((line, i) => {
      const y = Y0 + i * LH;
      const w = glyphX(line, 'display', 600, PX, -3).width;
      const x0 = X + w * sweep;
      if (sweep < 1) {
        c.fillStyle = rgba('#C7C7CC', 0.6 * (1 - sweep));
        c.fillRect(x0, y - PX * 0.82, X + w - x0, PX * 1.08);
      }
      // text rises 6 px into place with the kick
      const k = prog(t, B(32), B(32) + 0.12, ease.outExpo);
      c.fillStyle = rgba('#0A0A0B', 1);
      c.fillText(line, X, y + (1 - k) * 6);
      endX = X + w;
    });
    // caret at the end of the insertion, blinking on the beat
    if (caretBlink(f.beatPhase, t < B(32) + 0.25)) {
      c.fillStyle = rgba('#0A0A0B', 1);
      c.beginPath();
      c.roundRect(endX + 10, Y0 + LH - PX * 0.8, 6, PX * 0.98, 3);
      c.fill();
    }
    // the receipt
    const kN = prog(t, B(33), B(33) + 0.2, ease.outCubic);
    c.font = font('mono', 500, 26);
    c.letterSpacing = '0.5px';
    c.fillStyle = rgba('#6E6E73', kN);
    c.fillText('8 words  ·  3.0 s of speech  ·  typed at your cursor', X + 4, Y0 + LH + 110 + (1 - kN) * 8);
    // the mono state readout continues from the previous plate
    c.fillStyle = rgba('#0A0A0B', 1);
    c.beginPath(); c.arc(158, 992, 7, 0, Math.PI * 2); c.fill();
    c.font = font('mono', 500, 24);
    c.letterSpacing = '1px';
    c.fillStyle = rgba('#6E6E73', 1);
    c.fillText('DONE', 180, 1000);

    comp.draw(renderer, this.text.upload(), out);
    const kick = au.hit('kick', t, 0.1);
    return { vignette: 0.12, grain: 0.02, zoom: lerp(1.03, 1, prog(t, B(32), B(32) + 0.3, ease.outExpo)) + 0.004 * kick, bloom: 0.2 };
  }
}
