// Plate 3 — "Speak." (drop A, bars 6–7). The menu's dot-matrix waveform (SignalField, recording
// mode) blown up into a 3D field of glossy spheres, driven by the track itself: each column is a
// band of the mirrored 44-band spectrum (bass in the middle, hats at the edges), kicks push the
// whole field. The camera cuts on the tresillo kicks (beats 24, 25.5, 27, 28.5, 29, 30.5). On the
// one-beat stop (beat 31) the field collapses to the flat line and the transcribing scan sweeps
// once across it: "Let go." A mono readout top left tracks the app's states.
import * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font } from '../engine/type';
import { clamp, ease, lerp, prog, smoothstep } from '../engine/util';
import { DotBatch, beatT, mirroredBand, sstep } from './_kit';

const COLS = 44, ROWS = 15;

interface Shot { from: number; to: number; pos: (u: number) => [number, number, number]; tgt: (u: number) => [number, number, number]; fov: number; ease?: (x: number) => number; reflect?: number }

export default class Speak extends Scene {
  dots = new DotBatch(4000);
  text = new Layer2D();
  cam = new THREE.PerspectiveCamera(30, 1920 / 1080, 0.1, 500);
  shots: Shot[] = [];
  private v = new THREE.Vector3();

  override init() {
    const B = (b: number) => beatT(this.ctx.audio, b);
    const L = lerp;
    this.shots = [
      // S1 front-on, a slow push
      { from: B(24), to: B(25.5), pos: (u) => [0, 0, L(44, 38, u)], tgt: () => [0, 2.2, 0], fov: 38, ease: ease.outCubic },
      // S2 low, from the left, looking along the field
      { from: B(25.5), to: B(27), pos: (u) => [L(-34, -30, u), L(-5.5, -4.5, u), L(14, 11, u)], tgt: (u) => [L(4, 7, u), 0, 0], fov: 34, reflect: 1 },
      // S3 high, from the right
      { from: B(27), to: B(28.5), pos: (u) => [L(30, 26, u), L(15, 13, u), L(22, 19, u)], tgt: () => [-3, -1, 0], fov: 32, reflect: 0.6 },
      // S4 punch-in, centre
      { from: B(28.5), to: B(29), pos: (u) => [0, L(1.2, 0.6, u), L(20, 16, u)], tgt: () => [0, 0, 0], fov: 40, ease: ease.outExpo },
      // S5 orbit
      { from: B(29), to: B(30.5), pos: (u) => { const a = L(-0.7, 0.35, u); return [Math.sin(a) * 30, L(-3, 2, u), Math.cos(a) * 30]; }, tgt: () => [0, 0, 0], fov: 34, ease: ease.inOutCubic, reflect: 0.8 },
      // S6 pull back to the flat front-on view for the stop
      { from: B(30.5), to: B(32), pos: (u) => [0, 0, L(40, 60, u)], tgt: () => [0, 0, 0], fov: 38, ease: ease.outExpo },
    ];
  }

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.ink);

    const shot = this.shots.find((s) => t >= s.from && t < s.to) ?? this.shots[this.shots.length - 1]!;
    const u = (shot.ease ?? ease.linear)(clamp((t - shot.from) / (shot.to - shot.from)));
    this.cam.fov = shot.fov;
    this.cam.position.set(...shot.pos(u));
    this.cam.lookAt(...shot.tgt(u));
    this.cam.updateProjectionMatrix();
    this.cam.updateMatrixWorld();

    // field state: recording until the stop, then collapse (attention) and one transcribing sweep
    const stop = B(31);
    const collapse = prog(t, stop, stop + 0.09, ease.outCubic);
    const scanU = prog(t, stop + 0.04, B(32), ease.inOutQuad);
    const kick = au.hit('kick', t, 0.1), snare = au.hit('snare', t, 0.1);
    const intro = prog(t, B(24), B(24) + 0.12, ease.outExpo); // the field bursts open on the drop

    const pts: { x: number; y: number; z: number; r: number; b: number; a: number; g: number }[] = [];
    const floorY = -ROWS / 2 - 0.9;
    const reflect = shot.reflect ?? 0;
    for (let col = 0; col < COLS; col++) {
      const x = (col / (COLS - 1)) * 2 - 1;
      const envelope = Math.exp(-x * x * 2.4) * 0.86 + 0.14;
      const band = mirroredBand(au, col, COLS, t, 1, 42);
      const chatter = 0.85 + 0.15 * Math.sin(t * 8.7 + col * 0.93) * Math.sin(t * 3.3 - col * 0.41);
      const level = clamp(0.18 + 0.62 * band + 0.3 * kick + 0.12 * snare) * intro;
      const recording = Math.max(0.07, level * envelope * chatter * 1.15);
      const scan = (0.45 + 0.55 * envelope) * (0.08 + 0.7 * Math.exp(-Math.pow(x - lerp(-1.25, 1.25, scanU), 2) / 0.03));
      const flat = 0.05;
      const active = lerp(recording, t < stop + 0.06 ? flat : scan, collapse);
      for (let row = 0; row < ROWS; row++) {
        const c = (ROWS - 1) / 2;
        const dist = Math.abs(row - c) / c;
        const lit = sstep(active + 0.1, active - 0.06, dist);
        const r = 0.36 * (0.42 + 0.58 * lit);
        const a = 0.12 + 0.88 * lit * (1 - dist * 0.35);
        const wx = col - (COLS - 1) / 2, wy = c - row;
        // lit dots come forward a little: depth for the 3D shots
        const wz = lit * 0.6 * (0.5 + band);
        pts.push({ x: wx, y: wy, z: wz, r, b: 0.35 + 0.65 * lit, a, g: 0.9 });
        if (reflect > 0 && lit > 0.05) pts.push({ x: wx, y: 2 * floorY - wy, z: wz, r, b: 0.35 * lit, a: a * 0.14 * reflect * Math.exp(-(wy - floorY) * 0.12), g: 0.3 });
      }
    }
    // project, sort far → near, draw
    const proj: { sx: number; sy: number; d: number; r: number; b: number; a: number; g: number }[] = [];
    const camPos = this.cam.position;
    const focal = 1080 / 2 / Math.tan(THREE.MathUtils.degToRad(this.cam.fov / 2));
    for (const p of pts) {
      this.v.set(p.x, p.y, p.z);
      const d = this.v.distanceTo(camPos);
      this.v.project(this.cam);
      if (this.v.z > 1 || this.v.z < -1) continue;
      proj.push({ sx: (this.v.x * 0.5 + 0.5) * 1920, sy: (0.5 - this.v.y * 0.5) * 1080, d, r: (p.r * focal) / d, b: p.b, a: p.a, g: p.g });
    }
    proj.sort((a, b) => b.d - a.d);
    this.dots.clear();
    const bright = 1 + 0.25 * kick;
    for (const p of proj) this.dots.add(p.sx, p.sy, p.r, p.b * bright, p.a, p.g);
    this.dots.render(renderer, out);

    // type
    const c = this.text.ctx;
    this.text.clear();
    const kS = prog(t, B(24), B(24) + 0.18, ease.outExpo) * (1 - prog(t, B(25.5) - 0.1, B(25.5), ease.inQuad));
    if (kS > 0) {
      c.font = font('display', 800, 190);
      c.letterSpacing = '-5px';
      c.fillStyle = rgba('bone', kS);
      c.fillText('Speak.', 150, 250 + (1 - kS) * 40);
    }
    const kL = prog(t, stop, stop + 0.16, ease.outExpo);
    if (kL > 0) {
      c.font = font('display', 800, 150);
      c.letterSpacing = '-4px';
      c.textAlign = 'center';
      c.fillStyle = rgba('bone', kL);
      c.fillText('Let go.', 960, 250 + (1 - kL) * 30);
      c.textAlign = 'left';
    }
    // readout: the app's states, as a deadpan instrument
    c.font = font('mono', 500, 24);
    c.letterSpacing = '1px';
    const held = Math.max(0, Math.min(t, stop) - B(24));
    const blink = Math.floor((t - B(24)) / (60 / 140 / 2)) % 2 === 0 ? 1 : 0.35;
    c.fillStyle = rgba('bone', t < stop ? blink : 0.35);
    c.beginPath(); c.arc(158, 1000 - 8, 7, 0, Math.PI * 2); c.fill();
    c.fillStyle = rgba('ash', 1);
    const label = t < stop ? `LISTENING  fn held  ${held.toFixed(2)} s` : `TRANSCRIBING  on-device`;
    c.fillText(label, 180, 1000);
    comp.draw(renderer, this.text.upload(), out);

    const flash = t >= B(24) ? Math.pow(0.5, (t - B(24)) / 0.025) * 0.5 : 0;
    return { bloom: 0.7 + 0.3 * kick, flash, zoom: 1 + 0.012 * kick, vignette: 0.4, shake: [0, 2.5 * kick * Math.sin(t * 90)] as [number, number] };
  }
}
