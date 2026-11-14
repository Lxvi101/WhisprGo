// Shared motifs for every plate: the glossy dot (GPU batch), text sampled into dots, the logo mark,
// the app's SignalField formula, and small beat helpers. Read-only for plates: change it here only
// when a motif must change everywhere.
import * as THREE from 'three';
import { W, H, SCALE } from '../engine/gl';
import type { AudioData } from '../engine/audio';
import { font, type Family } from '../engine/type';
import { clamp } from '../engine/util';
import { LOGO_DOTS, LOGO_VIEW } from './logo-data';

// ------------------------------------------------------------------ beat grid
/** Seconds of beat index b (0 = first downbeat; 4 beats a bar, 140 BPM). */
export const beatT = (au: AudioData, b: number) => au.timeOfBeat(b);

// ------------------------------------------------------------------ the dot
/**
 * A batch of screen-space dots drawn as one instanced draw call. Each dot is a disc with an
 * analytic anti-aliased edge and optional gloss: sphere shading plus a specular highlight that is
 * allowed to exceed 1.0 (the only thing in the film that blooms). Coordinates in logical px (y down).
 */
export class DotBatch {
  private geo: THREE.InstancedBufferGeometry;
  private pos: THREE.InstancedBufferAttribute;
  private col: THREE.InstancedBufferAttribute;
  private mesh: THREE.Mesh;
  private scene = new THREE.Scene();
  private cam = new THREE.OrthographicCamera(0, W, 0, H, -1, 1);
  n = 0;

  constructor(public capacity = 20000, opts: { additive?: boolean } = {}) {
    this.geo = new THREE.InstancedBufferGeometry();
    this.geo.setAttribute('position', new THREE.Float32BufferAttribute([-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0], 3));
    this.geo.setIndex([0, 1, 2, 0, 2, 3]);
    this.pos = new THREE.InstancedBufferAttribute(new Float32Array(capacity * 4), 4); // x, y, radius, gloss
    this.col = new THREE.InstancedBufferAttribute(new Float32Array(capacity * 4), 4); // rgb (linear), alpha
    this.pos.setUsage(THREE.DynamicDrawUsage);
    this.col.setUsage(THREE.DynamicDrawUsage);
    this.geo.setAttribute('iPos', this.pos);
    this.geo.setAttribute('iCol', this.col);
    const mat = new THREE.RawShaderMaterial({
      glslVersion: THREE.GLSL3,
      vertexShader: /* glsl */ `precision highp float;
        in vec3 position; in vec4 iPos; in vec4 iCol;
        uniform mat4 projectionMatrix; uniform mat4 modelViewMatrix; uniform float pxScale;
        out vec2 vUv; out vec4 vCol; out float vGloss; out float vR;
        void main() {
          float pad = 1.5 / pxScale;
          float R = iPos.z + pad;
          vUv = position.xy * R / max(iPos.z, 1e-3);
          vCol = iCol; vGloss = iPos.w; vR = iPos.z * pxScale;
          gl_Position = projectionMatrix * modelViewMatrix * vec4(iPos.xy + position.xy * R, 0.0, 1.0);
        }`,
      fragmentShader: /* glsl */ `precision highp float;
        in vec2 vUv; in vec4 vCol; in float vGloss; in float vR;
        out vec4 fragColor;
        void main() {
          float d = length(vUv);
          // coverage: 1 physical px anti-aliasing band; tiny dots keep their ink as a faint disc
          float aa = 1.0 / max(vR, 0.5);
          float cov = clamp((1.0 - d) / (2.0 * aa) + 0.5, 0.0, 1.0);
          if (cov <= 0.0) discard;
          // shading normal of the sphere under this fragment (the AA fringe beyond the rim uses the rim's normal)
          vec2 q = vUv / max(d, 1.0);
          vec3 n = vec3(q.x, -q.y, sqrt(max(0.0, 1.0 - dot(q, q))));
          // sphere shading under a soft key light (upper left) and a rim from the right
          float lam = 0.55 + 0.45 * max(dot(n, normalize(vec3(-0.45, 0.6, 0.66))), 0.0);
          float spec = pow(max(dot(n, normalize(vec3(-0.32, 0.42, 0.85))), 0.0), 48.0) * 2.6;
          float rim = pow(1.0 - n.z, 3.0) * 0.35;
          vec3 c = vCol.rgb * mix(1.0, lam + rim, vGloss) + vec3(spec) * vGloss * max(max(vCol.r, vCol.g), vCol.b);
          float a = vCol.a * cov;
          fragColor = vec4(c * a, a);
        }`,
      uniforms: { pxScale: { value: SCALE } },
      depthTest: false,
      depthWrite: false,
      transparent: true,
      side: THREE.DoubleSide, // the y-down camera flips the winding
      blending: THREE.CustomBlending,
    });
    mat.blendEquation = THREE.AddEquation;
    mat.blendSrc = THREE.OneFactor;
    mat.blendDst = opts.additive ? THREE.OneFactor : THREE.OneMinusSrcAlphaFactor;
    mat.blendSrcAlpha = THREE.OneFactor;
    mat.blendDstAlpha = THREE.OneMinusSrcAlphaFactor;
    this.mesh = new THREE.Mesh(this.geo, mat);
    this.mesh.frustumCulled = false;
    this.scene.add(this.mesh);
  }

  clear() { this.n = 0; }

  /** Add a dot: centre (px), radius (px), brightness (linear, may exceed 1), alpha, gloss 0..1. */
  add(x: number, y: number, r: number, b = 1, a = 1, gloss = 0, tint: [number, number, number] = [1, 1, 1]) {
    if (this.n >= this.capacity || r <= 0.01 || a <= 0.002) return;
    const i = this.n++;
    const p = this.pos.array as Float32Array, c = this.col.array as Float32Array;
    p[i * 4] = x; p[i * 4 + 1] = y; p[i * 4 + 2] = r; p[i * 4 + 3] = gloss;
    c[i * 4] = b * tint[0]; c[i * 4 + 1] = b * tint[1]; c[i * 4 + 2] = b * tint[2]; c[i * 4 + 3] = a;
  }

  render(renderer: THREE.WebGLRenderer, out: THREE.WebGLRenderTarget) {
    if (this.n === 0) return;
    this.geo.instanceCount = this.n;
    this.pos.addUpdateRange(0, this.n * 4);
    this.col.addUpdateRange(0, this.n * 4);
    this.pos.needsUpdate = true;
    this.col.needsUpdate = true;
    renderer.setRenderTarget(out);
    renderer.render(this.scene, this.cam);
  }
}

// ------------------------------------------------------------------ text → dots
export interface TextDot { x: number; y: number; cov: number; col: number; row: number }

/**
 * Sample `text` on a square dot grid of `pitch` px: one dot per cell whose coverage exceeds `min`.
 * Returns dots in layout px relative to (x, y) as the text's left baseline, plus the grid size.
 */
export function textDots(text: string, family: Family, weight: number, px: number, pitch: number, opts: { tracking?: number; min?: number; align?: 'left' | 'center' } = {}) {
  const c = document.createElement('canvas');
  const ctx = c.getContext('2d', { willReadFrequently: true })!;
  ctx.font = font(family, weight, px);
  ctx.letterSpacing = `${opts.tracking ?? 0}px`;
  const m = ctx.measureText(text);
  const asc = Math.ceil(m.actualBoundingBoxAscent + 2), desc = Math.ceil(m.actualBoundingBoxDescent + 2);
  const w = Math.ceil(m.width + pitch * 2), h = asc + desc;
  c.width = w; c.height = h;
  ctx.font = font(family, weight, px);
  ctx.letterSpacing = `${opts.tracking ?? 0}px`;
  ctx.fillStyle = '#fff';
  ctx.fillText(text, pitch, asc);
  const img = ctx.getImageData(0, 0, w, h).data;
  const dots: TextDot[] = [];
  const ox = opts.align === 'center' ? -m.width / 2 : 0;
  const min = opts.min ?? 0.12;
  for (let row = 0, cy = pitch / 2; cy < h; row++, cy += pitch) {
    for (let col = 0, cx = pitch / 2; cx < w; col++, cx += pitch) {
      // average coverage of the cell
      let s = 0, k = 0;
      const r = Math.max(1, Math.floor(pitch / 2));
      for (let yy = Math.floor(cy - r); yy < cy + r; yy += Math.max(1, r >> 1)) for (let xx = Math.floor(cx - r); xx < cx + r; xx += Math.max(1, r >> 1)) {
        if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
        s += img[(yy * w + xx) * 4 + 3]! / 255; k++;
      }
      const cov = k ? s / k : 0;
      if (cov > min) dots.push({ x: cx - pitch + ox, y: cy - asc, cov, col, row });
    }
  }
  return { dots, width: m.width, ascent: asc, descent: desc };
}

// ------------------------------------------------------------------ the logo mark
/** Logo dots mapped into a box: centre (cx, cy), mark height `h` px. Returns x, y, r in px. */
export function logoDots(cx: number, cy: number, h: number) {
  const s = h / (LOGO_VIEW.markBottom - LOGO_VIEW.markTop);
  const mx = LOGO_VIEW.w / 2, my = (LOGO_VIEW.markTop + LOGO_VIEW.markBottom) / 2;
  return LOGO_DOTS.map(([x, y, r]) => ({ x: cx + (x - mx) * s, y: cy + (y - my) * s, r: r * s }));
}

let wordmark: HTMLImageElement | null = null;
/** The WhisprGo wordmark (white paths on transparent), aspect 870:190. */
export async function loadWordmark() {
  if (wordmark) return wordmark;
  const img = new Image();
  img.src = 'brand/wordmark.svg';
  await img.decode();
  wordmark = img;
  return img;
}
export const WORDMARK_ASPECT = 870 / 190;
/** Height of the wordmark's x-height-free cap box relative to the image height (the W spans y 572-702 of 560-750). */
export const WORDMARK_CAP = (702 - 572) / 190;

// ------------------------------------------------------------------ SignalField (the app's menu waveform)
/**
 * Port of Sources/WhisprGo/UI/SignalField.swift: brightness of the dot at (column, row) for phase
 * weights (recording, transcribing, attention) and an input level. Returns { lit, radius01, opacity }.
 */
export function signalField(column: number, row: number, columns: number, rows: number, time: number, w: { recording: number; transcribing: number; attention: number; level: number }, levelOverride?: number) {
  const x = (column / (columns - 1)) * 2 - 1;
  const envelope = Math.exp(-x * x * 2.4) * 0.86 + 0.14;
  const idle = envelope * (0.52 + 0.2 * Math.sin(time * 1.15 - x * 3.4) + 0.1 * Math.sin(time * 0.61 + x * 7.3));
  const chatter = 0.62 + 0.38 * Math.sin(time * 8.7 + column * 0.93) * Math.sin(time * 3.3 - column * 0.41);
  const recording = Math.max(0.07, (levelOverride ?? w.level) * envelope * chatter);
  const sweep = Math.sin(time * 2.1) * 0.92;
  const scan = envelope * (0.1 + 0.62 * Math.exp(-Math.pow(x - sweep, 2) / 0.018));
  const flat = 0.05;
  const rest = 1 - w.recording - w.transcribing;
  const active = Math.max(0, rest) * (idle * (1 - w.attention) + flat * w.attention) + recording * w.recording + scan * w.transcribing;
  const centerRow = (rows - 1) / 2;
  const distance = Math.abs(row - centerRow) / centerRow;
  const lit = sstep(active + 0.1, active - 0.06, distance);
  return { lit, radius01: 0.42 + 0.58 * lit, opacity: 0.1 + 0.88 * lit * (1 - distance * 0.35) };
}

export function sstep(e0: number, e1: number, v: number) {
  const t = clamp((v - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}

/** Spectrum level for a column of a mirrored field (low frequencies in the middle). */
export function mirroredBand(au: AudioData, column: number, columns: number, t: number, lo = 2, hi = 40) {
  const x = Math.abs((column / (columns - 1)) * 2 - 1); // 0 centre .. 1 edge
  return au.band(lo + x * (hi - lo), t);
}

// ------------------------------------------------------------------ drawing helpers (Canvas2D)
/** Rounded rectangle path. */
export function rrect(c: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  const rr = Math.min(r, w / 2, h / 2);
  c.beginPath();
  c.roundRect(x, y, w, h, rr);
}

/** Text drawn glyph by glyph with a per-glyph reveal function (0..1: opacity & rise). */
export function drawReveal(c: CanvasRenderingContext2D, text: string, x: number, y: number, fam: Family, weight: number, px: number, reveal: (i: number) => number, opts: { tracking?: number; rise?: number; color?: string } = {}) {
  c.font = font(fam, weight, px);
  c.letterSpacing = `${opts.tracking ?? 0}px`;
  const chars = [...text];
  let prefix = '';
  const color = opts.color ?? '#f5f5f7';
  chars.forEach((ch, i) => {
    const gx = c.measureText(prefix).width;
    prefix += ch;
    const k = clamp(reveal(i));
    if (k <= 0.001) return;
    c.globalAlpha = k;
    c.fillStyle = color;
    c.fillText(ch, x + gx, y + (1 - k) * (opts.rise ?? 0));
  });
  c.globalAlpha = 1;
}

/** Caret visibility: solid while `solid` (typing), otherwise on for the first half of every beat. */
export const caretBlink = (beatPhase: number, solid = false) => solid || beatPhase < 0.5;

/**
 * The recording overlay pill (Sources/WhisprGo/UI/RecordingOverlay.swift) drawn at `s` times its
 * 104×40 pt size, centred at (cx, cy). `level` 0..1 drives the 11×5 meter exactly like the app;
 * `spin` >= 0 shows the transcribing spinner at that angle instead of the dots. `k` = present
 * progress (scale 0.82→1 spring in the app), `alpha` overall opacity.
 */
export function drawOverlayPill(c: CanvasRenderingContext2D, cx: number, cy: number, s: number, level: number, o: { spin?: number; scale?: number; alpha?: number; light?: boolean } = {}) {
  const env = [0.35, 0.5, 0.68, 0.84, 0.96, 1.0, 0.96, 0.84, 0.68, 0.5, 0.35];
  const W0 = 104 * s, H0 = 40 * s;
  const a = o.alpha ?? 1;
  if (a <= 0) return;
  c.save();
  c.translate(cx, cy);
  c.scale(o.scale ?? 1, o.scale ?? 1);
  c.globalAlpha = a;
  // soft shadow, surface, hairline
  c.shadowColor = 'rgba(0,0,0,0.55)';
  c.shadowBlur = 9 * s;
  c.shadowOffsetY = 3 * s;
  c.fillStyle = o.light ? 'rgba(255,255,255,0.97)' : 'rgba(20,20,20,0.96)';
  rrect(c, -W0 / 2, -H0 / 2, W0, H0, H0 / 2);
  c.fill();
  c.shadowColor = 'transparent';
  c.lineWidth = s;
  c.strokeStyle = o.light ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.1)';
  rrect(c, -W0 / 2 + s / 2, -H0 / 2 + s / 2, W0 - s, H0 - s, H0 / 2);
  c.stroke();
  const ink = o.light ? '0,0,0' : '255,255,255';
  if ((o.spin ?? -1) >= 0) {
    c.strokeStyle = `rgba(${ink},1)`;
    c.lineWidth = 2 * s;
    c.lineCap = 'round';
    c.beginPath();
    const r = 8 * s, st = o.spin!;
    c.arc(0, 0, r, st + 0.3 * Math.PI * 2, st + Math.PI * 2);
    c.stroke();
  } else {
    const amp = Math.max(0.06, Math.min(1, level));
    const cs = 5.8 * s, rs = 4.9 * s, tw = (env.length - 1) * cs;
    env.forEach((e, ci) => {
      for (let row = -2; row <= 2; row++) {
        const rd = Math.abs(row);
        const dia = Math.max(2.1, 2.55 + e * 0.65 - rd * 0.12) * s;
        const vis = Math.max(0.1, Math.min(1, (amp * e * 3.2 - rd * 0.36) * 1.55));
        const sc = 0.76 + vis * 0.24;
        c.fillStyle = `rgba(${ink},${0.92 * vis})`;
        c.beginPath();
        c.arc(-tw / 2 + ci * cs, row * rs, (dia / 2) * sc, 0, Math.PI * 2);
        c.fill();
      }
    });
  }
  c.restore();
}

/** The app's present spring (CASpringAnimation mass 1, stiffness 320, damping 26) from 0.82 to 1. */
export function presentSpring(dt: number) {
  if (dt <= 0) return 0.82;
  const w0 = Math.sqrt(320), zeta = 26 / (2 * Math.sqrt(320));
  const wd = w0 * Math.sqrt(1 - zeta * zeta);
  const x = Math.exp(-zeta * w0 * dt) * (Math.cos(wd * dt) + ((zeta * w0) / wd) * Math.sin(wd * dt));
  return 1 - 0.18 * x;
}

// ------------------------------------------------------------------ the end-card layout (logo → outro)
/**
 * Where the mark, wordmark and tagline sit on the end card, in px. The mark keeps the SVG's own
 * proportions to the wordmark: `k` px per world unit when the mark is 10 world units tall.
 */
export const CARD = (() => {
  const markH = 330, cx = 960, markCy = 400;
  const s = markH / (LOGO_VIEW.markBottom - LOGO_VIEW.markTop); // px per svg unit
  const top = markCy - markH / 2;
  // wordmark image covers svg x 40..910, y 560..750
  const wm = { x: cx + (40 - LOGO_VIEW.w / 2) * s, y: top + (560 - LOGO_VIEW.markTop) * s, w: 870 * s, h: 190 * s };
  return { cx, markCy, markH, k: markH / 10, svgScale: s, wordmark: wm, taglineY: wm.y + wm.h + 96 };
})();

/** Glossy studio environment (soft boxes in a black room) as a PMREM texture. */
export function studioEnvironment(renderer: THREE.WebGLRenderer) {
  const env = new THREE.Scene();
  env.background = new THREE.Color(0x000000);
  const box = (w: number, h: number, x: number, y: number, z: number, k: number) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(k, k, k), side: THREE.DoubleSide }));
    m.position.set(x, y, z); m.lookAt(0, 0, 0); env.add(m);
  };
  box(6, 3, -6, 7, 4, 6); // key, upper left
  box(1.2, 8, 8, 3, -2, 4); // strip, right
  box(10, 10, 0, 12, 0, 0.35); // top fill
  box(4, 1, 2, 2, 9, 1.5); // front kicker
  const pmrem = new THREE.PMREMGenerator(renderer);
  const tex = pmrem.fromScene(env, 0.02).texture;
  pmrem.dispose();
  return tex;
}
