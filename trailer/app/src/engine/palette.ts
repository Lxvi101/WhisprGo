import { hexToLinear } from './util';

// WhisprGo is monochrome: ink, greys and white, with the dot as the only ornament.
// Gloss (specular highlights on the dots and keycaps) is the only thing allowed to bloom.
// See docs/TREATMENT.md.
export const HEX = {
  ink: '#050506', // background black
  ink2: '#0E0E10', // raised black (surfaces, the overlay pill)
  graphite: '#2C2C2F', // hairlines, dim dots
  ash: '#8E8E93', // secondary text (the system secondary grey)
  bone: '#F5F5F7', // primary text and lit dots
  paper: '#FAFAFA', // the light-mode surface (DMG background, light plates)
} as const;

export type PaletteKey = keyof typeof HEX;

/** Linear RGB triplets for GL uniforms. */
export const LIN: Record<PaletteKey, [number, number, number]> = Object.fromEntries(
  Object.entries(HEX).map(([k, v]) => [k, hexToLinear(v)]),
) as Record<PaletteKey, [number, number, number]>;

/** CSS rgba() for Canvas2D. */
export function rgba(key: PaletteKey | string, a = 1): string {
  const hex = (HEX as Record<string, string>)[key] ?? key;
  const n = parseInt(hex.replace('#', ''), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}
