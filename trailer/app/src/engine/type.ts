// Typography: the app's own system faces (SF Pro Display / Text / Rounded, SF Mono), drawn through
// Canvas2D. They are the locally installed Apple fonts, never bundled into the repository.

export type Family = 'display' | 'text' | 'rounded' | 'mono';

// Registered from the system font files (served by the dev server at /sysfonts/, see vite.config.ts)
// under private names, so every Chromium build draws exactly these faces.
const FAMILY: Record<Family, string> = {
  display: '"WG Display", sans-serif',
  text: '"WG Text", sans-serif',
  rounded: '"WG Rounded", sans-serif',
  mono: '"WG Mono", monospace',
};

const WEIGHT_NAME: Record<number, string> = { 100: 'Ultralight', 200: 'Thin', 300: 'Light', 400: 'Regular', 500: 'Medium', 600: 'Semibold', 700: 'Bold', 800: 'Heavy', 900: 'Black' };
const FILES: [string, string, number[]][] = [
  ['WG Display', 'SF-Pro-Display', [300, 400, 500, 600, 700, 800, 900]],
  ['WG Text', 'SF-Pro-Text', [400, 500, 600]],
  ['WG Rounded', 'SF-Pro-Rounded', [500, 600, 700]],
  ['WG Mono', 'SF-Mono', [400, 500, 600]],
];

/** CSS font string: font('display', 700, 120). */
export const font = (family: Family, weight: number, px: number) => `${weight} ${px}px ${FAMILY[family]}`;

let probe: CanvasRenderingContext2D | null = null;
function ctx2d() {
  if (!probe) probe = document.createElement('canvas').getContext('2d')!;
  return probe;
}

/** Width of `text` in px (with optional letter spacing in px). */
export function measure(text: string, family: Family, weight: number, px: number, tracking = 0) {
  const c = ctx2d();
  c.font = font(family, weight, px);
  c.letterSpacing = `${tracking}px`;
  return c.measureText(text).width;
}

/** The largest size <= max at which `text` fits in `width`. */
export function fitSize(text: string, family: Family, weight: number, width: number, max = 400, tracking = 0) {
  const w = measure(text, family, weight, 100, (tracking * 100) / max);
  return Math.min(max, (100 * width) / Math.max(1, w));
}

/**
 * Per-glyph x positions of `text` (kerning included: each position is the width of the prefix, so a
 * glyph drawn alone at its x lands exactly where the whole string would draw it).
 */
export function glyphX(text: string, family: Family, weight: number, px: number, tracking = 0) {
  const c = ctx2d();
  c.font = font(family, weight, px);
  c.letterSpacing = `${tracking}px`;
  const chars = [...text];
  const xs: number[] = [];
  let prefix = '';
  for (const ch of chars) { xs.push(c.measureText(prefix).width); prefix += ch; }
  return { chars, xs, width: c.measureText(text).width };
}

/** Register and load every face the video uses (throws if one is missing: a fallback would silently change the look). */
export async function loadFonts() {
  const faces = FILES.flatMap(([family, file, weights]) => weights.map((w) => new FontFace(family, `url(sysfonts/${file}-${WEIGHT_NAME[w]}.otf)`, { weight: String(w) })));
  await Promise.all(faces.map(async (f) => {
    try { document.fonts.add(await f.load()); } catch { throw new Error(`font missing: ${f.family} ${f.weight} (Apple's SF fonts must be installed in /Library/Fonts)`); }
  }));
}
