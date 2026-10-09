import type { ImageOptions, Settings } from '../src/types';
export const defaultSettings: Settings = {
  clipboard: true, autoCopy: true, explorerDrag: true, pinned: false, alwaysOnTop: true,
  launchAtLogin: false, corner: 'bottom-right', defaultMode: 'balanced', defaultFormat: 'auto',
};
export const modes = ['balanced', 'aggressive', 'lossless'] as const;
export const formats = ['auto', 'png', 'jpeg', 'webp', 'avif', 'gif'] as const;
export function parseOptions(value: unknown): ImageOptions {
  if (!value || typeof value !== 'object') throw new Error('Choose image settings first.');
  const o = value as ImageOptions;
  if (!modes.includes(o.mode) || !formats.includes(o.format) || !Number.isFinite(o.scale) || o.scale < 0.1 || o.scale > 1) throw new Error('Use a scale between 10% and 100%.');
  if (o.maxEdge !== undefined && (!Number.isInteger(o.maxEdge) || o.maxEdge < 1 || o.maxEdge > 16000)) throw new Error('Use a longest edge between 1 and 16000 pixels.');
  return { mode: o.mode, format: o.format, scale: o.scale, ...(o.maxEdge ? { maxEdge: o.maxEdge } : {}) };
}
export function parseSettings(value: unknown, current: Settings = defaultSettings): Settings {
  if (!value || typeof value !== 'object') return { ...current };
  const v = value as Record<string, unknown>;
  const next = { ...current };
  for (const key of ['clipboard', 'autoCopy', 'explorerDrag', 'pinned', 'alwaysOnTop', 'launchAtLogin'] as const) if (typeof v[key] === 'boolean') next[key] = v[key];
  if (['bottom-right', 'bottom-left', 'top-right', 'top-left'].includes(String(v.corner))) next.corner = v.corner as Settings['corner'];
  if (modes.includes(v.defaultMode as ImageOptions['mode'])) next.defaultMode = v.defaultMode as ImageOptions['mode'];
  if (formats.includes(v.defaultFormat as ImageOptions['format'])) next.defaultFormat = v.defaultFormat as ImageOptions['format'];
  return next;
}
