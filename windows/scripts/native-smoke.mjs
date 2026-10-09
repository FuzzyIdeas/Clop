import { WindowsBridge } from '../dist-electron/native-test.js';
import { mkdtemp, rm } from 'node:fs/promises';
import { once } from 'node:events';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import sharp from 'sharp';
import { dragFixture, explorerFixture } from './drag-fixture.mjs';
const bridge = new WindowsBridge();
const dir = await mkdtemp(path.join(os.tmpdir(), 'clop-native-'));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let fixture;
try {
  const ready = once(bridge, 'ready');
  bridge.on('notice', notice => process.stderr.write(notice + '\n'));
  bridge.start(path.resolve('native/bridge.ps1'));
  await Promise.race([ready, new Promise((_, reject) => { const timeout = setTimeout(() => reject(new Error('Windows bridge did not start')), 15000); timeout.unref(); })]);
  await bridge.request({ type: 'settings', explorerDrag: false });
  const png = path.join(dir, 'clipboard-über-画像.png'); await sharp({ create: { width: 64, height: 32, channels: 4, background: '#7864bf80' } }).png().toFile(png);
  const current = await bridge.request({ type: 'sequence' });
  const skipped = await bridge.request({ type: 'copy', file: png, png, expectedSequence: Number(current.sequence) + 1000 });
  assert.equal(skipped.skipped, true);
  const copied = await bridge.request({ type: 'copy', file: png, png }); assert.equal(copied.ok, true);
  const snapshot = await bridge.request({ type: 'read' }); assert.deepEqual(snapshot.paths, [png]);
  const inspection = execFileSync('powershell.exe', ['-NoProfile', '-Sta', '-Command', 'Add-Type -AssemblyName System.Windows.Forms; $d = [System.Windows.Forms.Clipboard]::GetDataObject(); @{ image = $d.GetDataPresent([System.Windows.Forms.DataFormats]::Bitmap); png = $d.GetDataPresent("PNG"); files = $d.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop) } | ConvertTo-Json -Compress'], { encoding: 'utf8' });
  assert.deepEqual(JSON.parse(inspection), { image: true, png: true, files: true });
  await bridge.request({ type: 'settings', explorerDrag: true });
  fixture = await dragFixture(png);
  const events = [];
  bridge.on('drag-start', event => events.push(event.type)); bridge.on('drag-end', event => events.push(event.type));
  // Keep a supported image in the clipboard throughout. It must not authorise other gestures.
  for (const kind of ['text', 'textDrag', 'blank', 'unsupported', 'title', 'resize']) {
    events.length = 0;
    await fixture.gesture(kind); await pause(250);
    assert.deepEqual(events, [], `${kind} must not announce an image drag`);
    console.log(`No image target for ${kind}.`);
  }
  for (const escape of [false, true]) {
    events.length = 0;
    await fixture.gesture('image', { escape }); await pause(250);
    assert.deepEqual(events, ['drag-start', 'drag-end'], `A real image drag must appear and finish (${escape ? 'Escape' : 'release'})`);
  }
  events.length = 0;
  await fixture.gesture('image', { moveX: 0, moveY: 0 }); await pause(250);
  assert.deepEqual(events, [], 'Clicking an image without dragging must stay quiet');
  events.length = 0;
  await fixture.gesture('title', { pressDelay: 20, moveX: 0, moveY: -60 }); await pause(250);
  assert.deepEqual(events, [], 'A fast title-bar drag must not mistake the image moved underneath its original point for a source');
  await bridge.request({ type: 'settings', explorerDrag: true, ownWindows: [fixture.window] });
  events.length = 0; await fixture.gesture('image'); await pause(250);
  assert.deepEqual(events, [], 'Clop’s own windows must not announce an external drag');
  await bridge.request({ type: 'settings', explorerDrag: false, ownWindows: [] });
  events.length = 0; await fixture.gesture('image'); await pause(250);
  assert.deepEqual(events, [], 'Disabling automatic drag detection must keep the target quiet');
  await fixture.stop(); fixture = await explorerFixture(png);
  await bridge.request({ type: 'settings', explorerDrag: true });
  const paths = []; bridge.on('drag-start', event => paths.push(event.paths));
  events.length = 0; await fixture.gesture('image'); await pause(250);
  assert.deepEqual(events, ['drag-start', 'drag-end'], 'A real Explorer image drag must still announce and finish');
  assert.deepEqual(paths, [[png]], 'Explorer must identify the actual supported image file');
  for (const kind of ['title', 'resize', 'text', 'blank']) {
    events.length = 0; await fixture.gesture(kind); await pause(250);
    assert.deepEqual(events, [], `Explorer ${kind} must not announce a drag, even with an image selected`);
  }
  console.log('Windows native smoke passed: clipboard formats, sequence protection, real image/Explorer drags, release/Escape and suppression of text, unsupported images, empty space, window movement and resizing.');
} finally { await fixture?.stop(); bridge.stop(); await rm(dir, { recursive: true, force: true }); }
