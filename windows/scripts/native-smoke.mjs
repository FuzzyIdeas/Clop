import { WindowsBridge } from '../dist-electron/native-test.js';
import { mkdtemp, rm } from 'node:fs/promises';
import { once } from 'node:events';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import sharp from 'sharp';
const bridge = new WindowsBridge();
const dir = await mkdtemp(path.join(os.tmpdir(), 'clop-native-'));
try {
  const ready = once(bridge, 'ready');
  bridge.on('notice', notice => process.stderr.write(notice + '\n'));
  bridge.start(path.resolve('native/bridge.ps1'));
  await Promise.race([ready, new Promise((_, reject) => { const timeout = setTimeout(() => reject(new Error('Windows bridge did not start')), 15000); timeout.unref(); })]);
  await bridge.request({ type: 'settings', explorerDrag: false });
  const png = path.join(dir, 'clipboard.png'); await sharp({ create: { width: 64, height: 32, channels: 4, background: '#7864bf80' } }).png().toFile(png);
  const current = await bridge.request({ type: 'sequence' });
  const skipped = await bridge.request({ type: 'copy', file: png, png, expectedSequence: Number(current.sequence) + 1000 });
  assert.equal(skipped.skipped, true);
  const copied = await bridge.request({ type: 'copy', file: png, png }); assert.equal(copied.ok, true);
  const snapshot = await bridge.request({ type: 'read' }); assert.deepEqual(snapshot.paths, [png]);
  const inspection = execFileSync('powershell.exe', ['-NoProfile', '-Sta', '-Command', 'Add-Type -AssemblyName System.Windows.Forms; $d = [System.Windows.Forms.Clipboard]::GetDataObject(); @{ image = $d.GetDataPresent([System.Windows.Forms.DataFormats]::Bitmap); png = $d.GetDataPresent("PNG"); files = $d.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop) } | ConvertTo-Json -Compress'], { encoding: 'utf8' });
  assert.deepEqual(JSON.parse(inspection), { image: true, png: true, files: true });
  console.log('Windows clipboard smoke passed: image, PNG payload, file list and sequence protection.');
} finally { bridge.stop(); await rm(dir, { recursive: true, force: true }); }
