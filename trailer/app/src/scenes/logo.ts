// Plate 8 — the mark (drop C, beats 53–64). Out of the dive: 55 glossy white spheres in the
// 11×5 grid of the recording pill's meter. They leave column by column and all land in the
// WhisprGo mark (also 55 dots) exactly on the kick at beat 54.5; the camera orbits the mark while
// the spectrum pushes the spheres in depth, then settles front-on with a dolly-zoom on the bass's
// move to Eb (beat 56) into the end-card layout, where the wordmark wipes in and the tagline lands
// a phrase per kick (59, 61, 62.5). The snare roll ripples the mark into the outro.
import * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font } from '../engine/type';
import { ease, lerp, prog, hash, pulse } from '../engine/util';
import { LOGO_DOTS, LOGO_VIEW } from './logo-data';
import { beatT, CARD, loadWordmark, studioEnvironment } from './_kit';

export const TAGLINE: [string, number][] = [['Hold fn.', 59], ['Speak.', 61], ['It types.', 62.5]];

/** Logo dots in world units (mark 10 units tall, centred), sorted left to right. */
export function logoWorld() {
  const s = 10 / (LOGO_VIEW.markBottom - LOGO_VIEW.markTop);
  const mx = LOGO_VIEW.w / 2, my = (LOGO_VIEW.markTop + LOGO_VIEW.markBottom) / 2;
  return LOGO_DOTS.map(([x, y, r]) => ({ x: (x - mx) * s, y: -(y - my) * s, r: r * s }));
}

/** Draw the wordmark and tagline of the end card (shared with the outro). */
export function drawCard(c: CanvasRenderingContext2D, img: HTMLImageElement, t: number, B: (b: number) => number, o: { wipe: number; wipeOut?: number; tagline: (i: number) => number }) {
  const wm = CARD.wordmark;
  if (o.wipe > 0) {
    const a = wm.w * o.wipe, b = wm.w * (o.wipeOut ?? 0);
    c.save();
    c.beginPath(); c.rect(wm.x + b, wm.y - 10, Math.max(0, a - b), wm.h + 20); c.clip();
    c.drawImage(img, wm.x, wm.y, wm.w, wm.h);
    c.restore();
  }
  c.font = font('display', 500, 50);
  c.letterSpacing = '-0.5px';
  const gap = 34;
  const ws = TAGLINE.map(([s]) => c.measureText(s).width);
  let x = CARD.cx - (ws.reduce((a, b) => a + b, 0) + gap * (ws.length - 1)) / 2;
  TAGLINE.forEach(([s], i) => {
    const k = o.tagline(i);
    if (k > 0) {
      c.fillStyle = rgba('bone', k);
      c.fillText(s, x, CARD.taglineY + (1 - k) * 14);
    }
    x += ws[i]! + gap;
  });
  void t; void B;
}

export default class Logo extends Scene {
  scene = new THREE.Scene();
  cam = new THREE.PerspectiveCamera(30, 1920 / 1080, 0.1, 1000);
  mesh!: THREE.InstancedMesh;
  logo = logoWorld();
  grid: { x: number; y: number }[] = [];
  text = new Layer2D();
  img!: HTMLImageElement;
  private m = new THREE.Matrix4();
  private q = new THREE.Quaternion();

  override async init() {
    this.img = await loadWordmark();
    this.scene.environment = studioEnvironment(this.ctx.renderer);
    const mat = new THREE.MeshPhysicalMaterial({ color: 0xf2f2f4, roughness: 0.32, metalness: 0, clearcoat: 1, clearcoatRoughness: 0.06, envMapIntensity: 0.9 });
    this.mesh = new THREE.InstancedMesh(new THREE.SphereGeometry(1, 64, 32), mat, this.logo.length);
    this.mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    this.scene.add(this.mesh);
    const key = new THREE.DirectionalLight(0xffffff, 2.2); key.position.set(-4, 5, 6); this.scene.add(key);
    const rim = new THREE.DirectionalLight(0xffffff, 0.8); rim.position.set(6, 1, -3); this.scene.add(rim);
    this.scene.add(new THREE.AmbientLight(0xffffff, 0.12));
    // the pill's meter: 11 columns × 5 rows, assigned to the logo dots column-major (both sorted by x)
    this.logo.sort((a, b) => a.x - b.x || b.y - a.y);
    for (let col = 0; col < 11; col++) for (let row = 0; row < 5; row++) this.grid.push({ x: (col - 5) * 1.25, y: (2 - row) * 1.05 });
  }

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.ink);
    const kick = au.hit('kick', t, 0.1);
    const snare = au.hit('snare', t, 0.09);
    const settle = prog(t, B(56), B(56.6), ease.inOutCubic);
    const react = lerp(1, 0.25, settle);

    // spheres
    const n = this.logo.length;
    for (let i = 0; i < n; i++) {
      const L = this.logo[i]!, G = this.grid[i]!;
      const frac = i / (n - 1);
      const p = prog(t, B(53.35) + 0.32 * frac, B(54.5), ease.inOutCubic);
      const arc = Math.sin(Math.PI * p);
      const x = lerp(G.x, L.x, p);
      const y = lerp(G.y, L.y, p) + arc * 0.8 * (hash(i, 3) - 0.3);
      const band = au.band(3 + 34 * Math.abs(L.x) / 6, t);
      // depth: an arc on the flight, then the spectrum pushes the mark in z while it orbits
      const ripple = Math.sin(t * 9 - L.x * 0.9) * prog(t, B(63), B(63.5)) * (1 - prog(t, B(63.75), B(64)));
      const z = arc * 2.2 * (hash(i, 5) - 0.5) + (1 - settle) * p * (band - 0.35) * 1.6 * react + ripple * 0.6;
      // after the settle every kick sends a ring of swelling dots out from the mark's centre
      let ring = 0;
      if (settle > 0) for (const [tk] of au.events('kick', t - 0.6, t + 1e-4)) {
        const front = (t - tk!) * 26; // world units per second
        ring = Math.max(ring, Math.exp(-Math.pow(Math.hypot(L.x, L.y * 1.4) - front, 2) / 2.2) * Math.exp(-(t - tk!) * 3));
      }
      const rGrid = 0.42, r = lerp(rGrid, L.r, p) * (1 + (0.18 * band + 0.22 * kick) * react + 0.08 * snare * (1 - settle) + 0.35 * ring * settle);
      this.m.compose(new THREE.Vector3(x, y, z), this.q, new THREE.Vector3(r, r, r));
      this.mesh.setMatrixAt(i, this.m);
    }
    this.mesh.instanceMatrix.needsUpdate = true;

    // camera: pull out of the dive → orbit → dolly-zoom settle into the end card
    const fovSettle = 18;
    const focal = 540 / Math.tan(THREE.MathUtils.degToRad(fovSettle / 2));
    const tyS = (CARD.markCy - 540) / CARD.k; // look below the mark so it sits at markCy
    const pull = prog(t, B(53), B(54.5), ease.outExpo);
    const orbitU = prog(t, B(54.5), B(56), ease.inOutQuad);
    const ang = lerp(-0.6, 0.42, orbitU);
    const oPos = new THREE.Vector3(Math.sin(ang) * 24, lerp(1.5, -1, orbitU), Math.cos(ang) * 24);
    const aPos = new THREE.Vector3(0, 0, lerp(11, 24, pull));
    const pre = t < B(54.5) ? aPos : oPos;
    const fovPre = 34;
    // the lens narrows while the camera backs off into the flat end-card view
    const fov = lerp(fovPre, fovSettle, settle);
    const dSettle = focal / CARD.k;
    const dPre = pre.length();
    const d = lerp(dPre, dSettle, settle);
    const dir = pre.clone().normalize().lerp(new THREE.Vector3(0, 0, 1), settle).normalize();
    const pos = dir.multiplyScalar(d);
    const tgt = new THREE.Vector3(0, lerp(0, tyS, settle), 0);
    pos.y += tgt.y;
    this.cam.fov = fov;
    this.cam.position.copy(pos);
    this.cam.lookAt(tgt);
    this.cam.updateProjectionMatrix();
    renderer.setRenderTarget(out);
    renderer.render(this.scene, this.cam);

    // wordmark and tagline
    const c = this.text.ctx;
    this.text.clear();
    drawCard(c, this.img, t, B, {
      wipe: prog(t, B(56.2), B(56.2) + 0.35, ease.outCubic),
      tagline: (i) => prog(t, B(TAGLINE[i]![1]), B(TAGLINE[i]![1]) + 0.2, ease.outExpo),
    });
    comp.draw(renderer, this.text.upload(), out);
    const punch = pulse(t, B(53), 0.08) * 0.05 + pulse(t, B(54.5), 0.08) * 0.03;
    return { bloom: 0.55, bloomThreshold: 1.2, vignette: 0.4, zoom: 1 + punch + 0.008 * kick * react };
  }
}
