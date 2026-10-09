import { test } from 'node:test';
import assert from 'node:assert/strict';
import { defaultSettings, parseOptions, parseSettings } from './settings';
test('ignores unrecognised settings and malformed persisted values', () => {
  assert.deepEqual(parseSettings({ clipboard: 'yes', corner: 'outside', launchAtLogin: true, defaultMode: 'invalid', injected: 'no' }), { ...defaultSettings, launchAtLogin: true });
  assert.deepEqual(parseSettings(null), defaultSettings);
});
test('rejects invalid dimensions, formats and non-finite scales', () => {
  for (const bad of [0, -1, NaN, Infinity, 1.01]) assert.throws(() => parseOptions({ mode: 'balanced', format: 'auto', scale: bad }));
  assert.throws(() => parseOptions({ mode: 'balanced', format: 'mp4', scale: 1 }));
  assert.throws(() => parseOptions({ mode: 'balanced', format: 'png', scale: 1, maxEdge: 1.5 }));
  assert.throws(() => parseOptions({ mode: 'balanced', format: 'png', scale: 1, maxEdge: 20000 }));
});
