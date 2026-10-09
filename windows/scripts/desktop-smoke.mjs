import { spawn, execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { WindowsBridge } from '../dist-electron/native-test.js';

// Exercise the actual packaged app and sandboxed preload through local Chrome DevTools.
const profile = await mkdtemp(path.join(os.tmpdir(), 'clop-desktop-'));
const executable = path.resolve('release/win-unpacked/Clop for Windows.exe');
execFileSync('powershell.exe', ['-NoProfile', '-Sta', '-Command', 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::Clear()']);
const app = spawn(executable, ['--remote-debugging-port=9227', `--user-data-dir=${profile}`], { stdio: 'pipe' });
let output = '';
app.stdout.on('data', chunk => { output += chunk; }); app.stderr.on('data', chunk => { output += chunk; });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(task, description) {
  let last;
  for (let i = 0; i < 80; i++) { try { const value = await task(); if (value) return value; } catch (error) { last = error; } await pause(250); }
  throw new Error(`${description}: ${last?.message ?? output.slice(-2000)}`);
}
async function connect(target) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let sequence = 0;
  const pending = new Map();
  ws.addEventListener('message', event => { const reply = JSON.parse(event.data); if (reply.id) { const request = pending.get(reply.id); if (request) { pending.delete(reply.id); clearTimeout(request.timer); reply.error ? request.reject(new Error(reply.error.message)) : request.resolve(reply.result); } } });
  await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, { once: true }); ws.addEventListener('error', reject, { once: true }); });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence; const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 20000);
    pending.set(id, { resolve, reject, timer }); ws.send(JSON.stringify({ id, method, params }));
  });
  return { close: () => ws.close(), send, evaluate: async expression => {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text);
    return result.result.value;
  } };
}
async function click(client, selector) {
  const point = await client.evaluate(`(() => { const rect = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return {x:rect.x + rect.width/2,y:rect.y + rect.height/2}; })()`);
  await client.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...point });
  await client.send('Input.dispatchMouseEvent', { type: 'mousePressed', button: 'left', clickCount: 1, ...point });
  await client.send('Input.dispatchMouseEvent', { type: 'mouseReleased', button: 'left', clickCount: 1, ...point });
}
let main, floating, drag;
const externalClipboard = new WindowsBridge();
try {
  const pages = () => fetch('http://127.0.0.1:9227/json/list').then(response => response.json());
  const target = await until(async () => (await pages()).find(page => page.type === 'page' && page.url.includes('index.html') && !page.url.includes('floating')), 'Main window did not open');
  main = await connect(target);
  await until(() => main.evaluate('Boolean(window.clop && document.querySelector(".preferences"))'), 'Sandboxed preload did not load');
  const initial = await main.evaluate('window.clop.state()'); assert.equal(initial.native, true); assert.equal(initial.platform, 'win32');
  assert.equal(initial.items.length, 0, 'The app should start quietly, with no sample or workbench');
  const ready = once(externalClipboard, 'ready');
  externalClipboard.start(path.resolve('native/bridge.ps1')); await ready;
  await externalClipboard.request({ type: 'settings', explorerDrag: false });
  const sourceFile = path.join(profile, 'screenshot-über-画像.png');
  await sharp('../Clop/Assets.xcassets/preview-image-thumb.imageset/pv-image-thumb.jpg').resize(2400, 1600, { fit: 'cover' }).png({ compressionLevel: 0 }).toFile(sourceFile);
  // An external clipboard write must trigger processing and the corner card without opening Clop.
  await externalClipboard.request({ type: 'copy', file: sourceFile, png: sourceFile });
  const initialImage = await until(async () => (await main.evaluate('window.clop.state()')).items.find(item => item.status === 'ready' && item.source === 'clipboard'), 'Clipboard image did not automatically produce a result');
  assert.equal(initialImage.status, 'ready'); assert.equal(initialImage.width, 2400);
  await until(async () => { await main.evaluate(`window.clop.copy(${JSON.stringify(initialImage.id)})`); return true; }, 'Native clipboard did not connect');
  const floatTarget = await until(async () => (await pages()).find(page => page.type === 'page' && page.url.includes('floating')), 'Floating window did not open');
  floating = await connect(floatTarget);
  await until(() => floating.evaluate('Boolean(document.querySelector(".corner-card"))'), 'Automatic corner card did not render');
  await click(floating, '[aria-label="Convert to WEBP"]');
  await until(async () => (await main.evaluate('window.clop.state()')).items.some(item => item.id === initialImage.id && item.status === 'ready' && item.format === 'webp'), 'In-card format selection did not convert the image');
  await floating.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 1, y: 1 });
  await click(floating, '[aria-label="Downscale"]');
  await until(() => floating.evaluate('Boolean(document.querySelector(".scale-presets"))'), 'In-card downscale controls did not open');
  await click(floating, '.scale-presets button:nth-child(3)');
  await until(async () => (await main.evaluate('window.clop.state()')).items.some(item => item.id === initialImage.id && item.status === 'ready' && item.width === 1200), 'In-card 50% preset did not downscale the image');
  await floating.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 1, y: 1 });
  const afterApply = await main.evaluate('window.clop.state()');
  console.log('After applying WebP and 50%:', JSON.stringify({ notice: afterApply.notice, items: afterApply.items.map(({id,status,error,width,height,format,source,options}) => ({id,status,error,width,height,format,source,options})) }));
  const resized = afterApply.items.find(item => item.id === initialImage.id);
  assert.equal(resized?.status, 'ready', resized?.error);
  assert.deepEqual([resized.width, resized.height, resized.format], [1200, 800, 'webp']);
  assert.ok(resized.outputBytes < initialImage.originalBytes);
  await until(() => floating.evaluate('Boolean(document.querySelector(".corner-card") && document.body.innerText.includes("1200×800"))'), 'Automatic corner card did not render');
  const layout = await floating.evaluate('(() => { const rect = document.querySelector(".corner-card").getBoundingClientRect(); return {width:rect.width,height:rect.height,bottom:rect.bottom,viewport:innerHeight,selected:document.querySelector(".format-bar button.active").innerText}; })()');
  assert.deepEqual([layout.width, layout.height, layout.selected], [196, 166, 'WEBP']);
  assert.ok(layout.bottom <= layout.viewport, 'Corner card should fit its transparent window');
  assert.equal(await floating.evaluate('Boolean(document.querySelector(".sidebar,.dropzone,.image-editor"))'), false, 'No workbench should exist');
  await pause(1000);
  assert.equal((await main.evaluate('window.clop.state()')).items.length, 1, 'Own clipboard writes must not create a loop');
  assert.equal(await floating.evaluate('document.querySelector(".corner-notice")?.textContent ?? ""'), '', 'Fast in-card format and resize actions must not show a clipboard error');
  await until(async () => {
    const snapshot = await externalClipboard.request({ type: 'read' });
    if (!snapshot.paths?.[0]) return false;
    const metadata = await sharp(snapshot.paths[0]).metadata();
    return metadata.width === 1200 && metadata.height === 800 && metadata.format === 'webp';
  }, 'Automatic clipboard output did not match the card’s selected format and downscale');
  await mkdir('release', { recursive: true });
  for (const [name, client] of [['floating', floating]]) {
    const capture = await client.send('Page.captureScreenshot', { format: 'png' });
    await writeFile(`release/Windows-${name}.png`, Buffer.from(capture.data, 'base64'));
  }
  await main.evaluate(`window.clop.restore(${JSON.stringify(initialImage.id)})`);
  const restored = (await main.evaluate('window.clop.state()')).items.find(item => item.id === initialImage.id); assert.equal(restored.restored, true); assert.equal(restored.outputBytes, initialImage.originalBytes);
  // The app's own native helper must reveal the target during an external mouse drag.
  drag = spawn('powershell.exe', ['-NoProfile', '-Command', 'Add-Type -TypeDefinition \'using System; using System.Runtime.InteropServices; public static class ClopDesktopDrag { [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra); }\'; [ClopDesktopDrag]::SetCursorPos(300,300) | Out-Null; try { [ClopDesktopDrag]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 300; [ClopDesktopDrag]::SetCursorPos(400,350) | Out-Null; Start-Sleep -Milliseconds 2500 } finally { [ClopDesktopDrag]::mouse_event(4,0,0,0,[UIntPtr]::Zero) }']);
  const dragFinished = once(drag, 'exit');
  await until(() => floating.evaluate('Boolean(document.querySelector(".drop-target"))'), 'Dragging did not reveal the automatic corner target');
  const dragCapture = await floating.send('Page.captureScreenshot', { format: 'png' });
  await writeFile('release/Windows-drag-target.png', Buffer.from(dragCapture.data, 'base64'));
  await dragFinished;
  await until(() => floating.evaluate('!document.querySelector(".drop-target")'), 'Releasing the drag did not dismiss its target');
  assert.equal((await main.evaluate('window.clop.state()')).items.length, 1, 'Dragging without a drop must not import another image');
  // A browser/screenshot image has no file-drop payload. Copy text between repeated copies
  // of the image so content deduplication does not permanently suppress that image.
  execFileSync('powershell.exe', ['-NoProfile', '-Sta', '-Command', 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::SetText("Clop clipboard smoke")']);
  await pause(1000);
  execFileSync('powershell.exe', ['-NoProfile', '-Sta', '-Command', '$ErrorActionPreference = "Stop"; Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $image = New-Object System.Drawing.Bitmap($env:CLOP_SMOKE_IMAGE); $stream = New-Object System.IO.MemoryStream(,[System.IO.File]::ReadAllBytes($env:CLOP_SMOKE_IMAGE)); try { $data = New-Object System.Windows.Forms.DataObject; $data.SetImage($image); $data.SetData("PNG",$false,$stream); [System.Windows.Forms.Clipboard]::SetDataObject($data,$true,5,100) } finally { $stream.Dispose(); $image.Dispose() }'], { env: { ...process.env, CLOP_SMOKE_IMAGE: sourceFile } });
  const pixelImage = await until(async () => (await main.evaluate('window.clop.state()')).items.find(item => item.id !== initialImage.id && item.status === 'ready' && item.source === 'clipboard'), 'A pixel-only clipboard image did not automatically produce a new card');
  assert.deepEqual([pixelImage.originalWidth, pixelImage.originalHeight], [2400, 1600]);
  await pause(1000);
  const finalState = await main.evaluate('window.clop.state()');
  // The older result may have reached its normal ten-second dismissal by now.
  assert.equal(finalState.items.filter(item => item.id !== initialImage.id).length, 1, 'Pixel-only clipboard writes must produce exactly one new card');
  assert.equal(finalState.notice, undefined, 'Pixel-only clipboard processing must not show an error');
  console.log('Packaged Windows app smoke passed: automatic file and pixel clipboard processing, original card geometry, in-card format/resize, duplicate protection, repeat copying after text, restore and automatic drag target.');
} finally {
  try { if (main) await main.send('Runtime.evaluate', { expression: 'window.clop.window("quit")' }); } catch {}
  main?.close(); floating?.close();
  externalClipboard.stop();
  if (drag && drag.exitCode === null) drag.kill();
  if (app.exitCode === null) { await Promise.race([once(app, 'exit'), pause(3000)]); if (app.exitCode === null) app.kill(); }
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
}
