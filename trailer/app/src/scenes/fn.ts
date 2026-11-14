// Plate 2 — "Hold fn." (build, bars 4–5). A macro of the lower-left corner of a Mac keyboard:
// glossy black keycaps on a space-grey deck, lit by three soft boxes. The legends' backlight
// breathes up on every 8th-note hat (the build's tension), "Hold fn." lands on the clap, the
// camera hard-cuts to a top-down push on the bar-5 downbeat, and the key bottoms out exactly on
// the drop. Depth of field comes from jittering a thin-lens camera across motion-blur sub-frames.
import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/examples/jsm/geometries/RoundedBoxGeometry.js';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font } from '../engine/type';
import { clamp, ease, lerp, prog, hash, smoothstep } from '../engine/util';
import { beatT } from './_kit';

interface Key { mesh: THREE.Mesh; legend: THREE.Mesh; legendMat: THREE.MeshBasicMaterial; x: number; z: number; w: number }

type Legend = { top?: string; bottom?: string; globe?: boolean; fn?: boolean; align?: 'left' | 'right' | 'center' };

function legendTexture(w: number, l: Legend) {
  const S = 256;
  const c = document.createElement('canvas');
  c.width = Math.round(S * w); c.height = S;
  const g = c.getContext('2d')!;
  g.fillStyle = '#fff';
  g.strokeStyle = '#fff';
  const pad = 30;
  if (l.fn) {
    g.font = font('text', 500, 58);
    g.textAlign = 'right';
    g.fillText('fn', c.width - pad, pad + 48);
  }
  if (l.globe) {
    const r = 30, cx = pad + r, cy = S - pad - r;
    g.lineWidth = 6;
    g.beginPath(); g.arc(cx, cy, r, 0, Math.PI * 2); g.stroke();
    g.beginPath(); g.ellipse(cx, cy, r * 0.42, r, 0, 0, Math.PI * 2); g.stroke();
    g.beginPath(); g.moveTo(cx - r, cy); g.lineTo(cx + r, cy); g.stroke();
    g.beginPath(); g.moveTo(cx - r * 0.85, cy - r * 0.5); g.lineTo(cx + r * 0.85, cy - r * 0.5); g.stroke();
    g.beginPath(); g.moveTo(cx - r * 0.85, cy + r * 0.5); g.lineTo(cx + r * 0.85, cy + r * 0.5); g.stroke();
  }
  const al = l.align ?? 'right';
  g.textAlign = al;
  const x = al === 'left' ? pad : al === 'right' ? c.width - pad : c.width / 2;
  if (l.top) { g.font = font('text', 400, 64); g.fillText(l.top, x, pad + 52); }
  if (l.bottom) { g.font = font('text', 400, 40); g.fillText(l.bottom, x, S - pad - 4); }
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 8;
  return tex;
}

export default class Fn extends Scene {
  scene = new THREE.Scene();
  cam = new THREE.PerspectiveCamera(28, 1920 / 1080, 0.05, 100);
  keys: Key[] = [];
  fnKey!: Key;
  text = new Layer2D();
  private pmrem!: THREE.PMREMGenerator;

  override init() {
    const { renderer } = this.ctx;
    // studio: black room with soft boxes (key upper left, strip right, a faint top fill)
    const env = new THREE.Scene();
    env.background = new THREE.Color(0x000000);
    const box = (w: number, h: number, x: number, y: number, z: number, k: number) => {
      const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(k, k, k), side: THREE.DoubleSide }));
      m.position.set(x, y, z); m.lookAt(0, 0, 0); env.add(m);
    };
    box(6, 3, -6, 7, 4, 6); // key
    box(1.2, 8, 8, 3, -2, 4); // strip
    box(10, 10, 0, 12, 0, 0.35); // top fill
    box(4, 1, 2, 2, 9, 1.5); // front kicker (catches the key fronts)
    this.pmrem = new THREE.PMREMGenerator(renderer);
    this.scene.environment = this.pmrem.fromScene(env, 0.02).texture;
    this.scene.background = null;

    // deck: space-grey anodised aluminium
    const deck = new THREE.Mesh(new THREE.BoxGeometry(30, 0.4, 16), new THREE.MeshPhysicalMaterial({ color: 0x2a2b2e, metalness: 1, roughness: 0.46 }));
    deck.position.set(4, -0.2, -3);
    this.scene.add(deck);
    // key wells: a dark recess under every key
    const well = new THREE.MeshStandardMaterial({ color: 0x020203, roughness: 0.9 });
    const capMat = new THREE.MeshPhysicalMaterial({ color: 0x0a0a0b, roughness: 0.3, metalness: 0, clearcoat: 1, clearcoatRoughness: 0.08, envMapIntensity: 1.0 });

    const P = 1.0, GAP = 0.13;
    const add = (col: number, row: number, w: number, l: Legend) => {
      const kw = w * P - GAP, kd = P - GAP;
      const x = col * P + kw / 2, z = -row * P;
      const wl = new THREE.Mesh(new THREE.BoxGeometry(kw + 0.06, 0.02, kd + 0.06), well);
      wl.position.set(x, 0.005, z);
      this.scene.add(wl);
      const mesh = new THREE.Mesh(new RoundedBoxGeometry(kw, 0.34, kd, 5, 0.09), capMat);
      mesh.position.set(x, 0.2, z);
      this.scene.add(mesh);
      const legendMat = new THREE.MeshBasicMaterial({ map: legendTexture(w, l), transparent: true, toneMapped: false, depthWrite: false });
      const legend = new THREE.Mesh(new THREE.PlaneGeometry(kw * 0.92, kd * 0.92), legendMat);
      legend.rotation.x = -Math.PI / 2;
      legend.position.set(x, 0.371, z);
      this.scene.add(legend);
      const k = { mesh, legend, legendMat, x, z, w };
      this.keys.push(k);
      return k;
    };
    // bottom row: fn · control · option · command · space
    this.fnKey = add(0, 0, 1, { fn: true, globe: true });
    add(1, 0, 1, { top: '⌃', bottom: 'control' });
    add(2, 0, 1, { top: '⌥', bottom: 'option' });
    add(3, 0, 1.25, { top: '⌘', bottom: 'command' });
    add(4.25, 0, 5, {});
    // shift row
    add(0, 1, 2.3, { bottom: 'shift', align: 'left' });
    ['Z', 'X', 'C', 'V', 'B', 'N'].forEach((k, i) => add(2.3 + i, 1, 1, { top: k, align: 'center' }));
    // caps row
    add(0, 2, 1.8, { bottom: 'caps lock', align: 'left' });
    ['A', 'S', 'D', 'F', 'G', 'H'].forEach((k, i) => add(1.8 + i, 2, 1, { top: k, align: 'center' }));
    add(0, 3, 1.5, { bottom: 'tab', align: 'left' });
    ['Q', 'W', 'E', 'R', 'T', 'Y'].forEach((k, i) => add(1.5 + i, 3, 1, { top: k, align: 'center' }));
  }

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.ink);

    // backlight: builds across the two bars, breathing up on every hat
    const build = prog(t, B(16), B(24), ease.inQuad);
    const hat = au.hit('hat', t, 0.07);
    const light = 0.18 + 0.5 * build + 0.35 * hat * (0.4 + build);
    const press = prog(t, B(23.5), B(24) - 0.004, ease.inCubic);
    for (const k of this.keys) {
      const isFn = k === this.fnKey;
      const lv = isFn ? light * 1.25 + press * 1.2 : light * 0.75;
      k.legendMat.color.setScalar(lv);
      const dy = isFn ? -0.1 * press : 0;
      k.mesh.position.y = 0.2 + dy;
      k.legend.position.y = 0.371 + dy;
    }

    // camera: A (beats 16–20) low three-quarter push; B (20–24) top-down, accelerating into the key
    const fx = this.fnKey.x, fz = this.fnKey.z;
    let pos: THREE.Vector3, tgt: THREE.Vector3, focus: number, aperture: number;
    if (t < B(20)) {
      const u = prog(t, B(16), B(20), ease.inOutCubic);
      pos = new THREE.Vector3(lerp(-3.2, -1.7, u) + fx, lerp(1.9, 1.25, u), lerp(4.6, 3.1, u) + fz);
      tgt = new THREE.Vector3(fx + lerp(0.9, 0.55, u), 0.3, fz - 0.2);
      aperture = 0.05;
    } else {
      const u = prog(t, B(20), B(24), ease.inCubic);
      pos = new THREE.Vector3(fx + lerp(1.1, 0.3, u), lerp(3.4, 1.95, u), fz + lerp(2.2, 0.95, u));
      tgt = new THREE.Vector3(fx + lerp(0.5, 0.02, u), 0.3, fz + lerp(-0.4, -0.02, u));
      aperture = 0.035;
    }
    focus = pos.distanceTo(new THREE.Vector3(fx, 0.37, fz));
    // thin lens: every sub-frame looks through a different point of the aperture, all focused on the fn key
    const h1 = hash(Math.round(t * 48000), 1), h2 = hash(Math.round(t * 48000), 2);
    const ang = h1 * Math.PI * 2, rad = Math.sqrt(h2) * aperture;
    const fwd = tgt.clone().sub(pos).normalize();
    const right = new THREE.Vector3().crossVectors(fwd, new THREE.Vector3(0, 1, 0)).normalize();
    const up = new THREE.Vector3().crossVectors(right, fwd);
    const off = right.multiplyScalar(Math.cos(ang) * rad).add(up.multiplyScalar(Math.sin(ang) * rad));
    const focal = pos.clone().add(fwd.multiplyScalar(focus));
    // (the aperture jitter only exists in the export: the preview renders one sub-frame, sharp)
    const jitter = f.dt > 0 && f.dt < 1 / 61 ? 1 : 0;
    this.cam.position.copy(pos.clone().add(off.multiplyScalar(jitter)));
    this.cam.lookAt(jitter ? focal : tgt);
    this.cam.updateProjectionMatrix();
    renderer.setRenderTarget(out);
    renderer.render(this.scene, this.cam);

    // caption
    const c = this.text.ctx;
    this.text.clear();
    const k1 = prog(t, B(18), B(18) + 0.28, ease.outExpo);
    const kOut = prog(t, B(20) - 0.12, B(20), ease.inQuad);
    if (k1 > 0 && kOut < 1) {
      c.font = font('display', 700, 156);
      c.letterSpacing = '-4px';
      c.fillStyle = rgba('bone', k1 * (1 - kOut));
      c.fillText('Hold', 150, 900 + (1 - k1) * 30);
      const hw = c.measureText('Hold ').width;
      const k2 = prog(t, B(19), B(19) + 0.28, ease.outExpo);
      c.fillStyle = rgba('bone', k2 * (1 - kOut));
      c.fillText('fn.', 150 + hw, 900 + (1 - k2) * 30);
    }
    comp.draw(renderer, this.text.upload(), out);
    const flash = smoothstep(B(24) - 0.035, B(24), t) * 0.25;
    return { bloom: 0.6, vignette: 0.45, flash, grain: 0.04 };
  }

  override dispose() { this.pmrem?.dispose(); }
}
