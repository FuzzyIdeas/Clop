import { app, BrowserWindow, clipboard, ClipboardItem, dialog, globalShortcut, ipcMain, Menu, nativeImage, screen, shell, Tray } from 'electron';
import { createHash, randomUUID } from 'node:crypto';
import { copyFile, mkdir, readFile, writeFile, readdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { ImageEngine, message } from './engine';
import { defaultSettings, parseSettings } from './settings';
import { WindowsBridge } from './native';
import type { AppState, ImageOptions, ImageResult, Settings } from '../src/types';

const here = path.dirname(fileURLToPath(import.meta.url));
let main: BrowserWindow, floating: BrowserWindow, tray: Tray, engine: ImageEngine;
let settings = { ...defaultSettings }, notice: string | undefined, quitting = false, bridgeReady = false;
let settingsPath: string, storage: string;
let dropActive = false, dragging = false, importsRunning = 0, hovered = false;
const hidden = new Set<string>();
const hideTimers = new Map<string, NodeJS.Timeout>();
let clipboardBusy = false, lastFingerprint = '', lastOwnFingerprint = '', clipboardTimer: NodeJS.Timeout | undefined;
let lastClipboardSequence: number | undefined;
let pendingClipboard: { sequence?: number; paths: string[]; manual: boolean; aggressive: boolean } | undefined;
let clipboardWrites: Promise<void> = Promise.resolve();
const bridge = new WindowsBridge();
const devUrl = process.env.CLOP_DEV_URL;
const fingerprint = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');
const defaults = (): ImageOptions => ({ mode: settings.defaultMode, format: settings.defaultFormat, scale: 1 });
const state = (): AppState => ({ items: engine.list().filter(item => !hidden.has(item.id)), settings, native: true, platform: process.platform, dropActive, notice });
function broadcast() { for (const window of [main, floating]) if (window && !window.isDestroyed()) window.webContents.send('clop:state', state()); }
function inform(text: string) { notice = text; syncFloating(); broadcast(); }
function positionFloating() {
  const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  const [w, h] = floating.getSize();
  floating.setPosition(settings.corner.endsWith('right') ? area.x + area.width - w : area.x,
    settings.corner.startsWith('bottom') ? area.y + area.height - h : area.y);
}
function showFloating(focus = false, reposition = false) {
  if (reposition && !floating.isVisible()) positionFloating();
  if (focus) floating.show(); else floating.showInactive();
}
function syncFloating() {
  if (!floating || floating.isDestroyed()) return;
  const target = dropActive || settings.pinned;
  const count = Math.min(target ? 2 : 3, state().items.length);
  const height = count * 166 + Math.max(0, count - 1) * 4 + (target ? 160 : 0) + (count > 1 ? 28 : 0) + (notice ? 85 : 0) + 40;
  const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  floating.setSize(236, Math.min(height, area.height));
  positionFloating();
  if (count || target || notice || importsRunning) showFloating(); else floating.hide();
}
function showLatest() {
  for (const item of engine.list().slice(0, 3)) hidden.delete(item.id);
  dropActive = !engine.list().length;
  syncFloating(); broadcast();
}
function scheduleHide(id: string) {
  const existing = hideTimers.get(id); if (existing) clearTimeout(existing);
  const check = () => {
    if (hovered || dragging) { hideTimers.set(id, setTimeout(check, 1000)); return; }
    hidden.add(id); hideTimers.delete(id); syncFloating(); broadcast();
  };
  hideTimers.set(id, setTimeout(check, engine.get(id).result.source === 'clipboard' ? 10000 : 30000));
}
async function makeRoom() {
  const oldest = engine.list().at(-1);
  if (engine.list().length >= 40 && oldest) { const timer = hideTimers.get(oldest.id); if (timer) clearTimeout(timer); hideTimers.delete(oldest.id); hidden.delete(oldest.id); await engine.dismiss(oldest.id); }
}
async function importUrl(value: unknown, aggressive = false) {
  if (typeof value !== 'string' || value.length > 8192) throw new Error('Drop an HTTP or HTTPS image link.');
  const url = new URL(value);
  if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Drop an HTTP or HTTPS image link.');
  importsRunning++; dropActive = false;
  try {
    const sequence = bridgeReady ? Number((await bridge.request({ type: 'sequence' })).sequence) : undefined;
    const response = await fetch(url, { signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error('Could not download this image. Copy the image instead.');
    if (Number(response.headers.get('content-length')) > 128 * 1024 * 1024) throw new Error('Use an image smaller than 128 MB.');
    const chunks: Buffer[] = []; let length = 0;
    if (!response.body) throw new Error('This link did not return an image.');
    const reader = response.body.getReader();
    try {
      while (true) { const chunk = await reader.read(); if (chunk.done) break; length += chunk.value.length; if (length > 128 * 1024 * 1024) throw new Error('Use an image smaller than 128 MB.'); chunks.push(Buffer.from(chunk.value)); }
    } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
    await makeRoom();
    const id = await engine.importBuffer(Buffer.concat(chunks), path.basename(url.pathname) || 'Image.png', 'drop', { ...defaults(), ...(aggressive ? { mode: 'aggressive' } : {}) });
    if (settings.autoCopy && engine.get(id).result.status === 'ready') await copy(id, sequence);
  } finally { importsRunning--; syncFloating(); broadcast(); }
}
function configure(window: BrowserWindow) {
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.on('close', event => { if (!quitting) { event.preventDefault(); window.hide(); } });
}
async function createWindows() {
  const webPreferences = { preload: path.join(here, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true };
  main = new BrowserWindow({ width: 390, height: 500, resizable: false, show: false, backgroundColor: '#f3f1ef', title: 'Clop settings', autoHideMenuBar: true, webPreferences });
  floating = new BrowserWindow({ width: 236, height: 206, frame: false, resizable: false, transparent: true, show: false, skipTaskbar: true, alwaysOnTop: settings.alwaysOnTop, backgroundColor: '#00000000', webPreferences });
  configure(main); configure(floating);
  if (devUrl) { await main.loadURL(`${devUrl}/?preferences=1`); await floating.loadURL(`${devUrl}/?floating=1`); }
  else { await main.loadFile(path.join(here, '../dist/index.html'), { query: { preferences: '1' } }); await floating.loadFile(path.join(here, '../dist/index.html'), { query: { floating: '1' } }); }
  positionFloating();
  floating.setIgnoreMouseEvents(true, { forward: true });
  if (settings.pinned) { syncFloating(); floating.setIgnoreMouseEvents(false); }
}
async function copy(id: string, expectedSequence?: number, files?: string[]) {
  const file = engine.output(id);
  const { directory, result: { format } } = engine.get(id);
  if (process.platform === 'win32') {
    // Image processing can finish before the previous Windows clipboard write has flushed.
    // Snapshot its immutable output, then serialize encoding and native writes in action order.
    const write = async () => {
      if (!bridgeReady) throw new Error('The Windows clipboard helper is unavailable. Save or drag the result instead.');
      const png = path.join(directory, `clipboard-${randomUUID()}.png`);
      try {
        if (format === 'png') await copyFile(file, png);
        else await sharp(file, { limitInputPixels: 60_000_000 }).autoOrient().png().toFile(png);
        const reply = await bridge.request({ type: 'copy', file, files, png, ...(expectedSequence === undefined ? {} : { expectedSequence }) });
        if (!reply.skipped) { lastClipboardSequence = Number(reply.sequence); lastOwnFingerprint = fingerprint(await readFile(png)); }
      } finally { await rm(png, { force: true }); }
    };
    const job = clipboardWrites.then(write, write);
    clipboardWrites = job.catch(() => {});
    await job;
  } else {
    const image = nativeImage.createFromPath(file);
    if (image.isEmpty()) throw new Error('This format cannot be copied as an image here. Save the result instead.');
    const png = image.toPNG();
    await clipboard.write([new ClipboardItem({ 'image/png': new Blob([new Uint8Array(png)], { type: 'image/png' }) })]);
    const items = await clipboard.read(), item = items.find(item => item.types.includes('image/png'));
    lastOwnFingerprint = fingerprint(item ? Buffer.from(await (await item.getType('image/png')).arrayBuffer()) : png);
  }
}
async function importPaths(files: string[], source: ImageResult['source'] = 'drop', expectedSequence?: number, aggressive = false) {
  if (!Array.isArray(files) || files.length > 20 || files.some(p => typeof p !== 'string' || !path.isAbsolute(p))) throw new Error('Drop up to 20 local image files at a time.');
  dropActive = false; importsRunning++; broadcast();
  try {
  if (expectedSequence === undefined && bridgeReady) expectedSequence = Number((await bridge.request({ type: 'sequence' })).sequence);
  const completed: string[] = [];
  for (const file of files) {
    try {
      await makeRoom();
      const id = await engine.importPath(file, source, { ...defaults(), ...(aggressive ? { mode: 'aggressive' } : {}) });
      if (engine.get(id).result.status === 'ready') completed.push(id);
    } catch (error) { inform(`${path.basename(file)}: ${message(error)}`); }
  }
  if (settings.autoCopy && completed.length) await copy(completed[completed.length - 1], expectedSequence, completed.map(id => engine.output(id)));
  } finally { importsRunning--; syncFloating(); broadcast(); }
}
async function optimiseClipboard(sequence?: number, paths: string[] = [], manual = false, aggressive = false) {
  if (clipboardBusy) { pendingClipboard = { sequence, paths, manual, aggressive }; return; }
  if (!manual && !settings.clipboard) return;
  clipboardBusy = true;
  try {
    if (sequence === undefined && bridgeReady) {
      const snapshot = await bridge.request({ type: 'read' });
      if (!manual && snapshot.owned) return;
      sequence = Number(snapshot.sequence); paths = snapshot.paths as string[];
    }
    if (!manual && sequence !== undefined && sequence === lastClipboardSequence) return;
    if (sequence !== undefined) lastClipboardSequence = sequence;
    if (!manual && paths.length && paths.every(file => path.resolve(file).toLowerCase().startsWith(path.resolve(storage).toLowerCase() + path.sep))) return;
    if (paths.length) {
      if (!manual) {
        const hashes: string[] = [];
        for (const file of paths.slice(0, 20)) {
          const info = await stat(file);
          if (!info.isFile() || info.size > 128 * 1024 * 1024) throw new Error('Copy an image smaller than 128 MB.');
          hashes.push(fingerprint(await readFile(file)));
        }
        const hash = hashes.length === 1 ? hashes[0] : fingerprint(Buffer.from(hashes.join('\n')));
        if (hash === lastFingerprint || hash === lastOwnFingerprint) return;
        lastFingerprint = hash;
      }
      await importPaths(paths, 'clipboard', sequence, aggressive); return;
    }
    // Prefer an encoded PNG clipboard payload, avoiding an unnecessary bitmap round trip.
    let bytes = Buffer.alloc(0);
    for (const item of await clipboard.read()) {
      const type = item.types.find(type => type === 'image/png' || type === 'electron application/osclipboard;format="PNG"') ?? item.types.find(type => type.startsWith('image/'));
      if (type) { const blob = await item.getType(type); if ('arrayBuffer' in blob) { bytes = Buffer.from(await blob.arrayBuffer()); break; } }
    }
    // Reading a delayed image format can change the sequence. Also, a new external copy may
    // arrive while the async Electron read is pending. Re-read that snapshot before importing.
    if (!manual && bridgeReady && sequence !== undefined) {
      const snapshot = await bridge.request({ type: 'read' });
      if (snapshot.owned) return;
      if (Number(snapshot.sequence) !== sequence) {
        pendingClipboard = { sequence: Number(snapshot.sequence), paths: snapshot.paths as string[], manual: false, aggressive };
        return;
      }
    }
    if (!bytes.length) {
      if (!manual) { lastFingerprint = ''; lastOwnFingerprint = ''; }
      if (manual) {
        const text = (await clipboard.readText()).trim().replace(/^"|"$/g, '');
        if (path.isAbsolute(text)) await importPaths([text], 'clipboard', sequence);
        else inform('Copy an image or a local image file, then try again.');
      }
      return;
    }
    const hash = fingerprint(bytes);
    if (!manual && (hash === lastFingerprint || hash === lastOwnFingerprint)) return;
    lastFingerprint = hash;
    await makeRoom();
    const id = await engine.importBuffer(bytes, `Clipboard-${new Date().toISOString().replace(/[:.]/g, '-')}.png`, 'clipboard', { ...defaults(), ...(aggressive ? { mode: 'aggressive' } : {}) });
    if (settings.autoCopy && engine.get(id).result.status === 'ready') await copy(id, sequence);
  } catch (error) { inform(message(error)); }
  finally {
    clipboardBusy = false;
    if (pendingClipboard) { const next = pendingClipboard; pendingClipboard = undefined; void optimiseClipboard(next.sequence, next.paths, next.manual, next.aggressive); }
  }
}
function startClipboardFallback() {
  if (clipboardTimer) return;
  clipboardTimer = setInterval(() => { if (settings.clipboard) void optimiseClipboard(); }, 900);
  clipboardTimer.unref();
}
function updateTray() {
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Show latest results', click: showLatest },
    { label: 'Optimise clipboard', accelerator: 'Control+Shift+C', click: () => { void optimiseClipboard(undefined, [], true); } },
    { type: 'separator' },
    { label: 'Watch clipboard', type: 'checkbox', checked: settings.clipboard, click: item => { void updateSettings({ clipboard: item.checked }); } },
    { label: 'Keep drop zone visible', type: 'checkbox', checked: settings.pinned, click: item => { void updateSettings({ pinned: item.checked }); } },
    { label: 'Settings…', click: () => main.show() },
    { label: 'Open originals and results', click: () => { void shell.openPath(storage); } },
    { type: 'separator' }, { label: 'Quit Clop', click: () => app.quit() },
  ]));
}
async function updateSettings(value: Partial<Settings>) {
  settings = parseSettings(value, settings);
  await writeFile(settingsPath, JSON.stringify(settings, null, 2));
  floating.setAlwaysOnTop(settings.alwaysOnTop);
  syncFloating();
  if (process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: settings.launchAtLogin, path: process.execPath, args: ['--hidden'] });
  if (bridgeReady) await bridge.request(nativeSettings());
  updateTray(); broadcast();
}
function nativeSettings() {
  return { type: 'settings', explorerDrag: settings.explorerDrag, ownWindows: [main, floating].map(window => Number(window.getNativeWindowHandle().readBigUInt64LE())) };
}
function trusted(sender: Electron.WebContents) { return [main, floating].some(window => window && !window.isDestroyed() && window.webContents === sender); }
ipcMain.handle('clop:action', async (event, action: string, ...args: unknown[]) => {
  if (!trusted(event.sender)) throw new Error('Untrusted window.');
  const id = args[0] as string;
  switch (action) {
    case 'state': return state();
    case 'import': await importPaths(args[0] as string[], 'drop', undefined, args[1] === true); break;
    case 'import-url': await importUrl(args[0], args[1] === true); break;
    case 'clipboard': await optimiseClipboard(undefined, [], true); break;
    case 'apply': await engine.apply(id, args[1] as ImageOptions); if (settings.autoCopy && engine.get(id).result.status === 'ready') await copy(id); break;
    case 'restore': await engine.restore(id); if (settings.autoCopy) await copy(id); break;
    case 'copy': await copy(id); break;
    case 'save': {
      const entry = engine.get(id), file = engine.output(id);
      const name = `${path.parse(entry.result.name).name}-clop.${entry.result.format === 'jpeg' ? 'jpg' : entry.result.format}`;
      const result = await dialog.showSaveDialog(BrowserWindow.fromWebContents(event.sender)!, { defaultPath: name });
      if (result.filePath && !result.canceled) await copyFile(file, result.filePath); break;
    }
    case 'reveal': shell.showItemInFolder(engine.output(id)); break;
    case 'dismiss': { const timer = hideTimers.get(id); if (timer) clearTimeout(timer); hideTimers.delete(id); hidden.delete(id); await engine.dismiss(id); break; }
    case 'settings': await updateSettings(args[0] as Partial<Settings>); break;
    case 'window':
      switch (args[0]) {
        case 'hide': BrowserWindow.fromWebContents(event.sender)?.hide(); break;
        case 'minimize': BrowserWindow.fromWebContents(event.sender)?.minimize(); break;
        case 'main': main.show(); break;
        case 'float': showLatest(); break;
        case 'interactive': hovered = true; floating.setIgnoreMouseEvents(false); break;
        case 'passthrough': hovered = false; if (!dropActive) floating.setIgnoreMouseEvents(true, { forward: true }); break;
        case 'dismiss-notice': notice = undefined; syncFloating(); broadcast(); break;
        case 'quit': app.quit(); break;
        default: throw new Error('Unknown window action.');
      } break;
    default: throw new Error('Unknown Clop action.');
  }
});
ipcMain.on('clop:drag', (event, id: string) => {
  if (!trusted(event.sender)) return;
  try { const file = engine.output(id); event.sender.startDrag({ file, icon: nativeImage.createFromDataURL(engine.get(id).result.preview).resize({ width: 96 }) }); }
  catch (error) { inform(message(error)); }
});
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', (_event, argv) => { if (engine) showLatest(); const files = argv.filter(arg => /\.(png|jpe?g|webp|gif|avif|tiff?)$/i.test(arg) && path.isAbsolute(arg)); if (files.length) void importPaths(files, 'file'); });
  app.whenReady().then(async () => {
    Menu.setApplicationMenu(null);
    storage = path.join(app.getPath('userData'), 'images');
    settingsPath = path.join(app.getPath('userData'), 'settings.json');
    await mkdir(storage, { recursive: true });
    try { settings = parseSettings(JSON.parse(await readFile(settingsPath, 'utf8'))); } catch {}
    // Retain originals for seven days. Never touch the source files dropped into Clop.
    for (const dir of await readdir(storage, { withFileTypes: true })) if (dir.isDirectory()) {
      const file = path.join(storage, dir.name);
      if ((await stat(file)).mtimeMs < Date.now() - 7 * 86400000) await rm(file, { recursive: true, force: true });
    }
    engine = new ImageEngine(path.join(storage, `session-${Date.now()}`));
    engine.on('change', () => { syncFloating(); broadcast(); });
    engine.on('ready', (id: string) => { hidden.delete(id); scheduleHide(id); syncFloating(); broadcast(); });
    await createWindows();
    const icon = nativeImage.createFromPath(path.join(here, 'icon.png'));
    tray = new Tray(icon); tray.setToolTip('Clop'); tray.on('double-click', showLatest); updateTray();
    for (const [key, callback] of [
      ['Control+Shift+C', () => { void optimiseClipboard(undefined, [], true); }],
      ['Control+Shift+A', () => { void optimiseClipboard(undefined, [], true, true); }],
      ['Control+Shift+Space', showLatest],
    ] as const) if (!globalShortcut.register(key, callback)) inform(`${key} is already in use. Use the tray menu or floating shelf instead.`);
    if (process.platform === 'win32') {
      bridge.on('ready', () => { bridgeReady = true; void bridge.request(nativeSettings()).then(() => { if (settings.clipboard) void optimiseClipboard(); }).catch(error => inform(message(error))); });
      bridge.on('clipboard', event => { if (settings.clipboard) void optimiseClipboard(event.sequence, event.paths); });
      bridge.on('drag-start', () => { if (settings.explorerDrag) { dragging = true; dropActive = true; floating.setIgnoreMouseEvents(false); syncFloating(); broadcast(); } });
      bridge.on('drag-end', () => { dragging = false; setTimeout(() => { if (!dragging) { dropActive = false; syncFloating(); broadcast(); } }, 180); });
      bridge.on('notice', inform);
      bridge.on('stopped', () => { bridgeReady = false; startClipboardFallback(); });
      bridge.start(path.join(app.isPackaged ? process.resourcesPath : app.getAppPath(), 'native', 'bridge.ps1'));
    } else startClipboardFallback();
    const files = process.argv.slice(1).filter(arg => /\.(png|jpe?g|webp|gif|avif|tiff?)$/i.test(arg) && path.isAbsolute(arg));
    if (files.length) await importPaths(files, 'file');
  }).catch(error => { dialog.showErrorBox('Clop could not start', message(error)); app.quit(); });
  app.on('before-quit', () => { quitting = true; if (clipboardTimer) clearInterval(clipboardTimer); for (const timer of hideTimers.values()) clearTimeout(timer); bridge.stop(); globalShortcut.unregisterAll(); });
  app.on('window-all-closed', () => { if (quitting) app.quit(); });
  app.on('activate', () => { if (engine) showLatest(); });
}
