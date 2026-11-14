// Plate 6 — the feature run (drop B, beats 37–50). Sub-cuts on the kicks and the bass stop:
//   37    25 languages: a column of greetings rolls one per 16th
//   40    Your model: the app's segmented control, its pill sliding on each beat
//   42    Hands-free: fn + ⇧ go down on the clap of the bass stop; the field listens when the bass returns
//   44.5  Pro: a messy transcript is struck through on the kicks and resolves to what was meant
//   48    Every shortcut: the default shortcut table, a row per 8th
import type * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font, glyphX } from '../engine/type';
import { clamp, ease, lerp, prog } from '../engine/util';
import { DotBatch, beatT, mirroredBand, rrect, sstep } from './_kit';

const LANGS: [string, string][] = [
  ['Hello', 'English'], ['Bonjour', 'Français'], ['Hallo', 'Deutsch'], ['Hola', 'Español'], ['Ciao', 'Italiano'],
  ['Olá', 'Português'], ['Hej', 'Svenska'], ['Cześć', 'Polski'], ['Ahoj', 'Čeština'], ['Szia', 'Magyar'],
  ['Γεια σας', 'Ελληνικά'], ['Привіт', 'Українська'], ['Tere', 'Eesti'], ['Labas', 'Lietuvių'], ['Sveiki', 'Latviešu'],
  ['Moi', 'Suomi'], ['Bok', 'Hrvatski'], ['Здравей', 'Български'], ['Bună', 'Română'], ['Dobrý deň', 'Slovenčina'],
  ['Živjo', 'Slovenščina'], ['Hej', 'Dansk'], ['Bongu', 'Malti'], ['Привет', 'Русский'], ['Hoi', 'Nederlands'],
];
const MODELS = ['Parakeet', 'Whisper', 'OpenAI', 'Gemini'];
const MODEL_NOTE = ['NVIDIA Parakeet TDT 0.6B v3 · local', 'Whisper Large v3 Turbo · local', 'gpt-4o-mini-transcribe · cloud', 'Gemini 3.5 Transcribe · Pro'];
const SHORTCUTS: [string, string[]][] = [
  ['Push to talk', ['fn']],
  ['Start or stop dictation', ['fn', '⇧']],
  ['Switch Fast / Pro Mode', ['right ⇧']],
  ['Next Pro profile', ['right ⌃', 'right ⇧']],
  ['Paste last dictation', ['⌥', '⌘', 'V']],
];
// the Pro cleanup: [word, struck on beat (or 0), replacement shown after resolve (or undefined = keep)]
const MESSY: [string, number, string?][] = [
  ['so', 45, ''], ['um,', 45, ''], ['we', 0, 'We'], ['should', 0], ['uh', 45, ''], ['ship', 0], ['it', 0],
  ['on', 46, ''], ['Friday,', 46, ''], ['no', 46, ''], ['wait,', 46, ''], ['Thursday', 0, 'Thursday.'],
];

export default class Montage extends Scene {
  text = new Layer2D();
  dots = new DotBatch(2000);

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.ink);
    const c = this.text.ctx;
    this.text.clear();
    this.dots.clear();
    const beat = au.beatAt(t);

    const title = (s: string, at: number, x = 150, y = 250, px = 120) => {
      const k = prog(t, at, at + 0.22, ease.outExpo);
      c.font = font('display', 700, px);
      c.letterSpacing = `${-px / 40}px`;
      c.fillStyle = rgba('bone', k);
      c.fillText(s, x, y + (1 - k) * 24);
    };
    const mono = (s: string, x: number, y: number, a = 1, col = 'ash', px = 28, align: CanvasTextAlign = 'left') => {
      c.font = font('mono', 500, px);
      c.letterSpacing = '0.5px';
      c.textAlign = align;
      c.fillStyle = rgba(col, a);
      c.fillText(s, x, y);
      c.textAlign = 'left';
    };

    if (beat < 40) {
      // ---- 25 languages: a rolling column, one greeting per 16th
      const idx = (beat - 37) * 4; // continuous 16th index
      const i0 = Math.floor(idx);
      const settle = ease.outExpo(clamp((idx - i0) * 2.4));
      const pos = i0 - 1 + settle; // eases onto each new word
      const LH = 230;
      for (let k = i0 - 3; k <= i0 + 3; k++) {
        if (k < 0 || k >= LANGS.length) continue;
        const y = 680 + (k - pos) * LH;
        const d = Math.abs(k - pos);
        const a = clamp(1 - d * 0.62);
        if (a <= 0) continue;
        c.font = font('display', 700, 220);
        c.letterSpacing = '-5px';
        c.fillStyle = rgba('bone', a);
        c.fillText(LANGS[k]![0], 150, y);
        mono(LANGS[k]![1], 1770, y - 12, a * 0.9, 'ash', 30, 'right');
      }
      // mask bands top and bottom so the column reads as a window
      const g = c.createLinearGradient(0, 0, 0, 1080);
      g.addColorStop(0.18, 'rgba(5,5,6,1)'); g.addColorStop(0.42, 'rgba(5,5,6,0)'); g.addColorStop(0.75, 'rgba(5,5,6,0)'); g.addColorStop(0.95, 'rgba(5,5,6,1)');
      c.fillStyle = g; c.fillRect(0, 0, 1920, 1080);
      const n = Math.min(25, i0 + 1);
      mono(`${String(n).padStart(2, '0')} / 25`, 1770, 140, 1, 'bone', 30, 'right');
      title('25 languages.', B(37), 150, 150, 72);
      mono('detected automatically', 154, 200, prog(t, B(37.5), B(37.5) + 0.2));
    } else if (beat < 42) {
      // ---- your model: the segmented control, pill moving each beat (Signal.motion: critically damped)
      const sel = beat < 40.5 ? 1 : beat < 41 ? 2 : beat < 41.5 ? 3 : 0;
      const from = beat < 40.5 ? 0 : beat < 41 ? 1 : beat < 41.5 ? 2 : 3;
      const at = B(beat < 40.5 ? 40 : beat < 41 ? 40.5 : beat < 41.5 ? 41 : 41.5);
      const s = 3.4, ow = 280, h = 26 * s, pad = 2 * s;
      const W0 = ow * MODELS.length + pad * 2 + 2 * s * (MODELS.length - 1);
      const x0 = 960 - W0 / 2, y0 = 520;
      c.fillStyle = 'rgba(255,255,255,0.07)';
      rrect(c, x0, y0, W0, h + pad * 2, 9 * s); c.fill();
      // critically damped spring, response 0.42 s
      const dt = t - at, w = (2 * Math.PI) / 0.42;
      const k = 1 - (1 + w * dt) * Math.exp(-w * dt);
      const px = lerp(from, sel, k);
      const pillX = x0 + pad + px * (ow + 2 * s);
      c.shadowColor = 'rgba(0,0,0,0.5)'; c.shadowBlur = 2 * s; c.shadowOffsetY = s;
      c.fillStyle = '#3a3a3e';
      rrect(c, pillX, y0 + pad, ow, h, 7 * s); c.fill();
      c.shadowColor = 'transparent';
      MODELS.forEach((m, i) => {
        const on = 1 - clamp(Math.abs(px - i));
        c.font = font('text', 500, 12 * s);
        c.letterSpacing = '0px';
        c.textAlign = 'center';
        c.fillStyle = rgba('bone', 0.55 + 0.45 * on);
        c.fillText(m, x0 + pad + i * (ow + 2 * s) + ow / 2, y0 + pad + h / 2 + 4.2 * s);
      });
      c.textAlign = 'left';
      title('Your model.', B(40), 150, 300);
      mono(MODEL_NOTE[sel]!, 960, y0 + h + 150, clamp(dt / 0.12), 'bone', 32, 'center');
      mono('local or cloud · choose in Settings', 960, y0 + h + 210, 1, 'ash', 26, 'center');
    } else if (beat < 44.5) {
      // ---- hands-free: fn + ⇧ on the clap; the field listens when the bass comes back
      const down = prog(t, B(42), B(42) + 0.06, ease.outQuad) * (1 - prog(t, B(42.6), B(42.75), ease.inOutQuad));
      const keys = ['fn', '⇧'];
      keys.forEach((k, i) => {
        const size = 230, x = 960 + (i - 0.5) * 300 - size / 2, y = 330;
        const sc = 1 - 0.06 * down;
        c.save();
        c.translate(x + size / 2, y + size / 2); c.scale(sc, sc);
        c.fillStyle = down > 0.5 ? rgba('bone', 0.95) : 'rgba(255,255,255,0.08)';
        rrect(c, -size / 2, -size / 2, size, size, 40); c.fill();
        c.strokeStyle = 'rgba(255,255,255,0.14)'; c.lineWidth = 2;
        rrect(c, -size / 2 + 1, -size / 2 + 1, size - 2, size - 2, 40); c.stroke();
        c.font = font('rounded', 500, 96);
        c.textAlign = 'center';
        c.fillStyle = down > 0.5 ? '#0A0A0B' : rgba('bone', 1);
        c.fillText(k, 0, 34);
        c.restore();
      });
      c.font = font('rounded', 500, 80); c.textAlign = 'center'; c.fillStyle = rgba('ash', 1);
      c.fillText('+', 960, 470); c.textAlign = 'left';
      title('Hands-free.', B(42), 960 - glyphX('Hands-free.', 'display', 700, 120, -3).width / 2, 200);
      mono('press once to start · again to stop', 960, 900, prog(t, B(42.5), B(42.5) + 0.2), 'ash', 28, 'center');
      // the listening field (menu SignalField, recording) under the keys, from the bass's return
      const on = prog(t, B(43.5), B(43.5) + 0.15, ease.outCubic);
      const COLS = 44, ROWS = 7, pitch = 26, fx = 960 - (COLS - 1) * pitch / 2, fy = 720;
      for (let col = 0; col < COLS; col++) {
        const x = (col / (COLS - 1)) * 2 - 1;
        const env = Math.exp(-x * x * 2.4) * 0.86 + 0.14;
        const lvl = Math.max(0.07, clamp(0.15 + 0.7 * mirroredBand(au, col, COLS, t) + 0.3 * au.hit('kick', t, 0.1)) * env * on);
        for (let row = 0; row < ROWS; row++) {
          const dist = Math.abs(row - 3) / 3;
          const lit = sstep(lvl + 0.1, lvl - 0.06, dist);
          this.dots.add(fx + col * pitch, fy + (row - 3) * pitch, pitch * 0.32 * (0.42 + 0.58 * lit), 0.4 + 0.6 * lit, 0.1 + 0.88 * lit * (1 - dist * 0.35), 0.8);
        }
      }
    } else if (beat < 48) {
      // ---- Pro: what you said → what you meant
      const resolve = prog(t, B(46.5), B(46.5) + 0.3, ease.inOutCubic);
      const px = lerp(62, 104, resolve);
      c.font = font('display', 500, px);
      c.letterSpacing = '-1px';
      const space = c.measureText(' ').width;
      let x = 150;
      const y = 560;
      for (const [w, strikeAt, rep] of MESSY) {
        const struck = strikeAt > 0 ? prog(t, B(strikeAt), B(strikeAt) + 0.12, ease.outCubic) : 0;
        const gone = strikeAt > 0 ? resolve : 0;
        const word = rep !== undefined && rep !== '' && resolve > 0.5 ? rep : w;
        c.font = font('display', resolve > 0.5 ? 600 : 500, px);
        const ww = c.measureText(word).width;
        const shrink = 1 - gone;
        if (shrink > 0.01) {
          c.save();
          c.globalAlpha = (struck > 0 ? 1 - 0.55 * struck : 1) * shrink;
          c.fillStyle = rgba(struck > 0 ? 'ash' : 'bone', 1);
          c.fillText(word, x, y);
          if (struck > 0) {
            c.fillStyle = rgba('bone', 1);
            c.fillRect(x - 4, y - px * 0.32, (ww + 8) * struck, 5);
          }
          c.restore();
        }
        x += (ww + space) * (strikeAt > 0 ? shrink : 1);
      }
      c.globalAlpha = 1;
      title('Pro cleans it up.', B(44.5), 150, 300);
      mono(resolve > 0.5 ? 'what you meant' : 'what you said', 154, y + 90, 1, resolve > 0.5 ? 'bone' : 'ash');
      mono('Instruct Pro · your profiles, your vocabulary', 154, 1000, prog(t, B(45), B(45) + 0.2));
    } else {
      // ---- every shortcut: the Settings table, one row per 8th
      title('Every shortcut, yours.', B(48), 150, 230, 104);
      SHORTCUTS.forEach(([label, keys], i) => {
        const at = B(48 + i * 0.4);
        const k = prog(t, at, at + 0.18, ease.outExpo);
        if (k <= 0) return;
        const y = 390 + i * 118;
        c.globalAlpha = k;
        c.fillStyle = 'rgba(255,255,255,0.04)';
        rrect(c, 150, y, 1620, 96, 20); c.fill();
        c.font = font('text', 500, 38); c.letterSpacing = '0px';
        c.fillStyle = rgba('bone', 1);
        c.fillText(label, 190 + (1 - k) * 20, y + 62);
        let kx = 1730;
        for (let j = keys.length - 1; j >= 0; j--) {
          c.font = font('rounded', 500, 34);
          const w = Math.max(64, c.measureText(keys[j]!).width + 36);
          kx -= w;
          c.fillStyle = 'rgba(255,255,255,0.1)';
          rrect(c, kx, y + 18, w, 60, 12); c.fill();
          c.textAlign = 'center'; c.fillStyle = rgba('bone', 1);
          c.fillText(keys[j]!, kx + w / 2, y + 60);
          c.textAlign = 'left';
          kx -= 12;
        }
        c.globalAlpha = 1;
      });
    }

    this.dots.render(renderer, out);
    comp.draw(renderer, this.text.upload(), out);
    const kick = au.hit('kick', t, 0.09);
    return { zoom: 1 + 0.01 * kick, vignette: 0.35, bloom: 0.5 };
  }
}
