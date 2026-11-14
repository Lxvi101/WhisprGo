// Plate 7 — "Lives in your menu bar." (break 2, beats 50–53: bass out, hats only). The top of a
// Mac desktop: the menu bar slides in on the clap, the WhisprGo icon is clicked on the next 8th and
// the app's menu drops: its idle SignalField (the exact breathing formula), "Ready", the Fast/Pro
// control and the three most recent dictations, which are the ones this film has made. On the last
// beat the camera dives into the field's dots, which become the logo on the drop.
import type * as THREE from 'three';
import { Scene, type Frame } from '../engine/scene';
import { Layer2D, clearRT } from '../engine/gl';
import { LIN, rgba } from '../engine/palette';
import { font } from '../engine/type';
import { clamp, ease, lerp, prog } from '../engine/util';
import { beatT, rrect, signalField } from './_kit';

const S = 2.3; // points → px
const BAR_H = 24 * S;
const MENU_W = 320 * S;
const ICON_X = 1420; // centre of the WhisprGo status item
const MENU_X = ICON_X - 36 * S; // menu's left edge
const MENU_Y = BAR_H + 6;
const HERO = { x: MENU_X + 16 * S, y: MENU_Y + 16 * S, w: MENU_W - 32 * S, h: 56 * S };
const RECENT = ['Thursday at 3 works. I’ll bring the deck.', 'We should ship it Thursday.', 'Hallo zusammen, kurze Frage zum Release.'];
const AGES = ['now', '1 min', '4 min'];

/** Where the hero field's centre ends up (used by the logo plate to continue the dive). */
export const HERO_CENTER = { x: HERO.x + HERO.w / 2, y: HERO.y + HERO.h / 2 };

export default class Menubar extends Scene {
  text = new Layer2D();

  render(f: Frame, out: THREE.WebGLRenderTarget) {
    const { renderer, comp, audio: au } = this.ctx;
    const t = f.t;
    const B = (b: number) => beatT(au, b);
    clearRT(renderer, out, LIN.ink);
    const c = this.text.ctx;
    this.text.clear();

    // the dive: zoom about the hero field's centre, accelerating into the downbeat
    const dive = prog(t, B(52), B(53), ease.inExpo);
    const Z = lerp(1, 26, dive);
    const px = HERO_CENTER.x, py = HERO_CENTER.y;
    // before the dive the desktop is shifted left so the menu sits right of the title; during the
    // dive the field's centre travels to the frame's centre while the zoom grows
    const SHIFT = -346;
    const m = ease.inOutCubic(clamp(dive * 1.6));
    const sx0 = lerp(px + SHIFT, 960, m), sy0 = lerp(py, 540, m);
    c.setTransform(Z, 0, 0, Z, sx0 - Z * px, sy0 - Z * py);

    // desktop: a quiet graphite gradient
    const g = c.createRadialGradient(1300, 200, 50, 1100, 500, 1500);
    g.addColorStop(0, '#26262a'); g.addColorStop(1, '#070708');
    c.fillStyle = g;
    c.fillRect(-400, 0, 2800, 1300);

    // menu bar: slides down on the clap
    const kBar = prog(t, B(50), B(50) + 0.2, ease.outCubic);
    const by = (kBar - 1) * BAR_H;
    c.fillStyle = 'rgba(28,28,30,0.86)';
    c.fillRect(-400, by, 2800, BAR_H);
    c.fillStyle = 'rgba(255,255,255,0.08)';
    c.fillRect(-400, by + BAR_H - 1, 2800, 1);
    c.font = font('text', 600, 13 * S);
    c.letterSpacing = '0px';
    c.fillStyle = rgba('bone', 0.92);
    let mx = 40;
    ['Finder', 'File', 'Edit', 'View', 'Go', 'Window', 'Help'].forEach((m, i) => {
      c.font = font('text', i === 0 ? 700 : 400, 13 * S);
      c.fillText(m, mx, by + 17 * S);
      mx += c.measureText(m).width + 20 * S;
    });
    // status items, right to left: clock, control centre, battery, WhisprGo
    c.font = font('text', 400, 13 * S);
    c.textAlign = 'right';
    c.fillText('Thu 1 Oct  9:41', 1880, by + 17 * S);
    c.textAlign = 'left';
    const iy = by + BAR_H / 2;
    // control centre: two pills
    c.strokeStyle = rgba('bone', 0.9); c.lineWidth = 1.4 * S;
    rrect(c, 1560, iy - 7 * S, 16 * S, 5.5 * S, 3 * S); c.stroke();
    rrect(c, 1560, iy + 1.5 * S, 16 * S, 5.5 * S, 3 * S); c.stroke();
    // battery
    rrect(c, 1480, iy - 5.5 * S, 22 * S, 11 * S, 3 * S); c.stroke();
    c.fillStyle = rgba('bone', 0.9); rrect(c, 1483, iy - 3.5 * S, 15 * S, 7 * S, 1.5 * S); c.fill();
    // WhisprGo: the template icon (a dotted waveform), pressed highlight when the menu is open
    const click = B(50.5);
    const open = prog(t, click, click + 0.16, ease.outCubic);
    if (t >= click) {
      c.fillStyle = 'rgba(255,255,255,0.18)';
      rrect(c, ICON_X - 18 * S, iy - 10 * S, 36 * S, 20 * S, 5 * S); c.fill();
    }
    const pulse = au.hit('hat', t, 0.08);
    const icon = [0.25, 0.45, 0.7, 0.55, 0.95, 1.0, 0.75, 0.5, 0.8, 0.45, 0.25];
    icon.forEach((h, i) => {
      const n = Math.max(1, Math.round(h * 3));
      for (let k = -n + 1; k <= n - 1; k++) {
        c.fillStyle = rgba('bone', 0.95);
        c.beginPath();
        c.arc(ICON_X + (i - 5) * 2.3 * S, iy + k * 2.3 * S, (0.72 + 0.08 * pulse) * S, 0, Math.PI * 2);
        c.fill();
      }
    });

    // the menu (macOS menu material: dark, translucent, rounded, a hairline)
    if (open > 0) {
      const mh = 318 * S;
      c.save();
      c.globalAlpha = open;
      c.translate(0, (1 - open) * -6);
      c.shadowColor = 'rgba(0,0,0,0.5)'; c.shadowBlur = 30; c.shadowOffsetY = 10;
      c.fillStyle = 'rgba(38,38,40,0.94)';
      rrect(c, MENU_X, MENU_Y, MENU_W, mh, 11 * S); c.fill();
      c.shadowColor = 'transparent';
      c.strokeStyle = 'rgba(255,255,255,0.12)'; c.lineWidth = 1;
      rrect(c, MENU_X + 0.5, MENU_Y + 0.5, MENU_W - 1, mh - 1, 11 * S); c.stroke();
      // hero SignalField (idle), 44×11
      const cols = 44, rows = 11;
      const sx = HERO.w / cols, sy = HERO.h / rows, maxR = Math.min(sx, sy) * 0.3;
      for (let col = 0; col < cols; col++) for (let row = 0; row < rows; row++) {
        const v = signalField(col, row, cols, rows, t * 1.6, { recording: 0, transcribing: 0, attention: 0, level: 0 });
        c.fillStyle = rgba('bone', v.opacity);
        c.beginPath();
        c.arc(HERO.x + (col + 0.5) * sx, HERO.y + (row + 0.5) * sy, maxR * v.radius01, 0, Math.PI * 2);
        c.fill();
      }
      let y = HERO.y + HERO.h + 12 * S + 22 * S;
      c.font = font('display', 600, 24 * S); c.letterSpacing = `${-0.6 * S}px`;
      c.fillStyle = rgba('bone', 1);
      c.fillText('Ready', HERO.x, y);
      y += 20 * S;
      c.font = font('text', 400, 12 * S); c.letterSpacing = '0px';
      c.fillStyle = rgba('ash', 1);
      c.fillText('Hold fn, or fn ⇧ to toggle', HERO.x, y);
      // Fast / Pro
      y += 18 * S;
      c.fillStyle = 'rgba(255,255,255,0.07)';
      rrect(c, HERO.x, y, HERO.w, 30 * S, 9 * S); c.fill();
      c.fillStyle = '#48484c';
      rrect(c, HERO.x + 2 * S, y + 2 * S, HERO.w / 2 - 3 * S, 26 * S, 7 * S); c.fill();
      c.font = font('text', 500, 12 * S); c.textAlign = 'center';
      c.fillStyle = rgba('bone', 1); c.fillText('Fast', HERO.x + HERO.w / 4, y + 19.5 * S);
      c.fillStyle = rgba('ash', 1); c.fillText('Pro', HERO.x + (HERO.w * 3) / 4, y + 19.5 * S);
      c.textAlign = 'left';
      // recent
      y += 30 * S + 26 * S;
      c.fillStyle = 'rgba(255,255,255,0.1)'; c.fillRect(MENU_X, y - 14 * S, MENU_W, 1);
      c.font = font('text', 600, 11 * S); c.fillStyle = rgba('ash', 1);
      c.fillText('Recent', HERO.x, y);
      c.textAlign = 'right'; c.font = font('text', 400, 11 * S); c.fillText('See All', HERO.x + HERO.w, y); c.textAlign = 'left';
      RECENT.forEach((r, i) => {
        const k = prog(t, click + 0.1 + i * 0.07, click + 0.3 + i * 0.07, ease.outCubic);
        const ry = y + 14 * S + i * 34 * S;
        c.globalAlpha = open * k;
        c.fillStyle = 'rgba(255,255,255,0.04)';
        rrect(c, HERO.x - 4 * S, ry, HERO.w + 8 * S, 28 * S, 7 * S); c.fill();
        c.font = font('text', 400, 12 * S); c.fillStyle = rgba('bone', 1);
        let s = r;
        while (c.measureText(s + '…').width > HERO.w - 60 * S && s.length > 4) s = s.slice(0, -1);
        c.fillText(s === r ? r : s.trimEnd() + '…', HERO.x + 4 * S, ry + 18.5 * S);
        c.font = font('text', 400, 11 * S); c.fillStyle = rgba('ash', 1); c.textAlign = 'right';
        c.fillText(AGES[i]!, HERO.x + HERO.w - 2 * S, ry + 18.5 * S); c.textAlign = 'left';
      });
      c.globalAlpha = open;
      // footer
      const fy = MENU_Y + mh - 26 * S;
      c.fillStyle = 'rgba(255,255,255,0.1)'; c.fillRect(MENU_X, fy - 14 * S, MENU_W, 1);
      c.font = font('text', 400, 12 * S); c.fillStyle = rgba('ash', 1);
      c.fillText('Settings', HERO.x + 18 * S, fy + 4 * S);
      c.restore();
    }

    // title, in screen space (does not zoom with the desktop)
    c.setTransform(1, 0, 0, 1, 0, 0);
    const kT = prog(t, B(50), B(50) + 0.25, ease.outExpo) * (1 - prog(t, B(52), B(52.35), ease.inQuad));
    if (kT > 0) {
      c.font = font('display', 700, 112); c.letterSpacing = '-3px';
      c.fillStyle = rgba('bone', kT);
      c.fillText('Lives in your', 150, 560 + (1 - kT) * 20);
      c.fillText('menu bar.', 150, 680 + (1 - kT) * 20);
    }
    comp.draw(renderer, this.text.upload(), out);
    return { vignette: 0.4, fade: 0 };
  }
}
