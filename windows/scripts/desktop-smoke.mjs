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
let main, floating;
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
  const sourceFile = path.join(profile, 'screenshot.png');
  await sharp('../Clop/Assets.xcassets/preview-image-thumb.imageset/pv-image-thumb.jpg').resize(2400, 1600, { fit: 'cover' }).png({ compressionLevel: 0 }).toFile(sourceFile);
  // An external clipboard write must trigger processing and the corner card without opening Clop.
  await externalClipboard.request({ type: 'copy', file: sourceFile, png: sourceFile });
  const initialImage = await until(async () => (await main.evaluate('window.clop.state()')).items.find(item => item.status === 'ready' && item.source === 'clipboard'), 'Clipboard image did not automatically produce a result');
  assert.equal(initialImage.status, 'ready'); assert.equal(initialImage.width, 2400);
  await until(async () => { await main.evaluate(`window.clop.copy(${JSON.stringify(initialImage.id)})`); return true; }, 'Native clipboard did not connect');
  await main.evaluate(`window.clop.apply(${JSON.stringify(initialImage.id)}, {mode:"balanced",format:"webp",scale:0.5})`);
  const resized = (await main.evaluate('window.clop.state()')).items[0];
  assert.deepEqual([resized.width, resized.height, resized.format], [1200, 800, 'webp']);
  assert.ok(resized.outputBytes < initialImage.originalBytes);
  const floatTarget = await until(async () => (await pages()).find(page => page.type === 'page' && page.url.includes('floating')), 'Floating window did not open');
  floating = await connect(floatTarget);
  await until(() => floating.evaluate('Boolean(document.querySelector(".corner-card") && document.body.innerText.includes("1200×800"))'), 'Automatic corner card did not render');
  const layout = await floating.evaluate('(() => { const rect = document.querySelector(".corner-card").getBoundingClientRect(); return {width:rect.width,height:rect.height,bottom:rect.bottom,viewport:innerHeight,selected:document.querySelector(".format-bar button.active").innerText}; })()');
  assert.deepEqual([layout.width, layout.height, layout.selected], [196, 166, 'WEBP']);
  assert.ok(layout.bottom <= layout.viewport, 'Corner card should fit its transparent window');
  assert.equal(await floating.evaluate('Boolean(document.querySelector(".sidebar,.dropzone,.image-editor"))'), false, 'No workbench should exist');
  await pause(1000);
  assert.equal((await main.evaluate('window.clop.state()')).items.length, 1, 'Own clipboard writes must not create a loop');
  await mkdir('release', { recursive: true });
  for (const [name, client] of [['floating', floating]]) {
    const capture = await client.send('Page.captureScreenshot', { format: 'png' });
    await writeFile(`release/Windows-${name}.png`, Buffer.from(capture.data, 'base64'));
  }
  await main.evaluate(`window.clop.restore(${JSON.stringify(initialImage.id)})`);
  const restored = (await main.evaluate('window.clop.state()')).items[0]; assert.equal(restored.restored, true); assert.equal(restored.outputBytes, initialImage.originalBytes);
  console.log('Packaged Windows app smoke passed: automatic clipboard processing, original card geometry, selected format, clipboard loop protection and restore.');
} finally {
  try { if (main) await main.send('Runtime.evaluate', { expression: 'window.clop.window("quit")' }); } catch {}
  main?.close(); floating?.close();
  externalClipboard.stop();
  if (app.exitCode === null) { await Promise.race([once(app, 'exit'), pause(3000)]); if (app.exitCode === null) app.kill(); }
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
}
