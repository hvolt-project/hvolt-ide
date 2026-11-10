// The shell's palette. System tokens on this device resolve to their light values
// even under a dark system, so both sets live here and the page picks one from the
// (correctly reporting) dark-mode media query.
export const GAP: number = 8;
export const RADIUS: number = 16;

export class Palette {
  bg: string = '';
  bar: string = '';
  pane: string = '';
  card: string = '';
  status: string = '';
  surface: string = '';
  textPrimary: string = '';
  textSecondary: string = '';
  textTertiary: string = '';
  brand: string = '';
  brandSoft: string = '';
  divider: string = '';
  ok: string = '#3FA45B';
  fail: string = '#D9534F';
  busy: string = '#E0A100';
}

// One dark surface, not a gradient: every pane floats on `bg`, so any gap between
// rounded cards must read as the same colour as the chrome. A gradient made those
// gaps shift tone along the diagonal.
export const GLASS_TINT_DARK: string = '#B3141A22';
export const GLASS_TINT_LIGHT: string = '#CCFFFFFF';
export const GLASS_EDGE_DARK: string = '#26FFFFFF';
export const GLASS_EDGE_LIGHT: string = '#1A000000';

export const DARK: Palette = {
  bg: '#0D1116', bar: '#B3141A22', pane: '#B3141A22', card: '#D91B2230', status: '#B310151C',
  surface: '#12171F',
  textPrimary: '#F3F5F7', textSecondary: '#C2CAD4', textTertiary: '#8B95A2',
  brand: '#6FB0FF', brandSoft: '#3D2F6BA8', divider: '#333B47',
  ok: '#4FBF6B', fail: '#F06A62', busy: '#F0B429'
} as Palette;

export const LIGHT: Palette = {
  bg: '#F2F4F7', bar: '#CCFFFFFF', pane: '#CCFFFFFF', card: '#E6FFFFFF', status: '#CCF7F9FC',
  surface: '#FFFFFF',
  textPrimary: '#111827', textSecondary: '#556070', textTertiary: '#8A94A3',
  brand: '#0A59F7', brandSoft: '#1F0A59F7', divider: '#1A000000',
  ok: '#3FA45B', fail: '#D9534F', busy: '#E0A100'
} as Palette;

export function palette(dark: boolean): Palette {
  return dark ? DARK : LIGHT;
}

// The edge highlight that makes a translucent plate read as glass.
export function glassEdge(dark: boolean): string {
  return dark ? GLASS_EDGE_DARK : GLASS_EDGE_LIGHT;
}

// 0 disconnected, 1 connecting, 2 connected, 3 failed — the connection dot.
export function linkColor(p: Palette, link: number): string {
  if (link === 2) {
    return p.ok;
  }
  if (link === 3) {
    return p.fail;
  }
  if (link === 1) {
    return p.busy;
  }
  return p.textTertiary;
}

// 0 idle, 1 busy, 2 ok, 3 fail.
export function toneColor(p: Palette, tone: number): string {
  if (tone === 2) {
    return p.ok;
  }
  if (tone === 3) {
    return p.fail;
  }
  if (tone === 1) {
    return p.busy;
  }
  return p.textTertiary;
}
