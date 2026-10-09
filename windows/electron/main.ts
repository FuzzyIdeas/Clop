import { app, BrowserWindow, clipboard, ClipboardItem, dialog, globalShortcut, ipcMain, Menu, nativeImage, screen, shell, Tray } from 'electron';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile, writeFile, readdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { ImageEngine, message, sampleImage } from './engine';
import { defaultSettings, parseSettings } from './settings';
import { WindowsBridge } from './native';
import type { AppState, ImageOptions, ImageResult, Settings } from '../src/types';

const here = path.dirname(fileURLToPath(import.meta.url));
let main: BrowserWindow, floating: BrowserWindow, tray: Tray, engine: ImageEngine;
let settings = { ...defaultSettings }, notice: string | undefined, quitting = false, bridgeReady = false;
let settingsPath: string, storage: string;
let clipboardBusy = false, lastFingerprint = '', clipboardTimer: NodeJS.Timeout | undefined;
let pendingClipboard: { sequence?: number; paths: string[]; manual: boolean; aggressive: boolean } | undefined;
const bridge = new WindowsBridge();
const devUrl = process.env.CLOP_DEV_URL;
const fingerprint = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');
const defaults = (): ImageOptions => ({ mode: settings.defaultMode, format: settings.defaultFormat, scale: 1 });
const state = (): AppState => ({ items: engine.list(), settings, native: true, platform: process.platform, notice });
function broadcast() { for (const window of [main, floating]) if (window && !window.isDestroyed()) window.webContents.send('clop:state', state()); }
function inform(text: string) { notice = text; broadcast(); }
function positionFloating() {
  const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  const [currentWidth, currentHeight] = floating.getSize();
  floating.setSize(Math.min(currentWidth, area.width - 40), Math.min(currentHeight, area.height - 40));
  const [w, h] = floating.getSize();
  floating.setPosition(settings.corner.endsWith('right') ? area.x + area.width - w - 20 : area.x + 20,
    settings.corner.startsWith('bottom') ? area.y + area.height - h - 20 : area.y + 20);
}
function showFloating(focus = false, reposition = false) {
  if (reposition && !floating.isVisible()) positionFloating();
  if (focus) floating.show(); else floating.showInactive();
}
function configure(window: BrowserWindow) {
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.on('close', event => { if (!quitting) { event.preventDefault(); window.hide(); } });
}
async function createWindows() {
  const webPreferences = { preload: path.join(here, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true };
  main = new BrowserWindow({ width: 1080, height: 790, minWidth: 760, minHeight: 580, show: false, backgroundColor: '#f5f5f8', title: 'Clop for Windows', autoHideMenuBar: true, webPreferences });
  floating = new BrowserWindow({ width: 420, height: 660, minWidth: 360, minHeight: 360, frame: false, resizable: true, show: false, skipTaskbar: true, alwaysOnTop: settings.alwaysOnTop, backgroundColor: '#f5f5f8', webPreferences });
  configure(main); configure(floating);
  if (devUrl) { await main.loadURL(devUrl); await floating.loadURL(`${devUrl}/?floating=1`); }
  else { await main.loadFile(path.join(here, '../dist/index.html')); await floating.loadFile(path.join(here, '../dist/index.html'), { query: { floating: '1' } }); }
  positionFloating();
  if (!process.argv.includes('--hidden')) main.show();
  if (settings.pinned) showFloating();
}
async function copy(id: string, expectedSequence?: number, files?: string[]) {
  const file = engine.output(id);
  if (process.platform === 'win32') {
    if (!bridgeReady) throw new Error('The Windows clipboard helper is unavailable. Save or drag the result instead.');
    const png = path.join(engine.get(id).directory, 'clipboard.png');
    if (engine.get(id).result.format === 'png') await copyFile(file, png);
    else await sharp(file, { limitInputPixels: 60_000_000 }).autoOrient().png().toFile(png);
    await bridge.request({ type: 'copy', file, files, png, ...(expectedSequence === undefined ? {} : { expectedSequence }) });
  } else {
    const image = nativeImage.createFromPath(file);
    if (image.isEmpty()) throw new Error('This format cannot be copied as an image here. Save the result instead.');
    const png = image.toPNG();
    await clipboard.write([new ClipboardItem({ 'image/png': new Blob([new Uint8Array(png)], { type: 'image/png' }) })]);
    const items = await clipboard.read(), item = items.find(item => item.types.includes('image/png'));
    lastFingerprint = fingerprint(item ? Buffer.from(await (await item.getType('image/png')).arrayBuffer()) : png);
  }
}
async function importPaths(files: string[], source: ImageResult['source'] = 'drop', expectedSequence?: number, aggressive = false) {
  if (!Array.isArray(files) || files.length > 20 || files.some(p => typeof p !== 'string' || !path.isAbsolute(p))) throw new Error('Drop up to 20 local image files at a time.');
  if (expectedSequence === undefined && bridgeReady) expectedSequence = Number((await bridge.request({ type: 'sequence' })).sequence);
  const completed: string[] = [];
  for (const file of files) {
    try {
      if (engine.list().length >= 40) throw new Error('The shelf holds 40 images. Dismiss a few before adding more.');
      const id = await engine.importPath(file, source, { ...defaults(), ...(aggressive ? { mode: 'aggressive' } : {}) });
      if (engine.get(id).result.status === 'ready') completed.push(id);
    } catch (error) { inform(`${path.basename(file)}: ${message(error)}`); }
  }
  if (settings.autoCopy && completed.length) await copy(completed[completed.length - 1], expectedSequence, completed.map(id => engine.output(id)));
}
async function optimiseClipboard(sequence?: number, paths: string[] = [], manual = false, aggressive = false) {
  if (clipboardBusy) { pendingClipboard = { sequence, paths, manual, aggressive }; return; }
  if (!manual && !settings.clipboard) return;
  clipboardBusy = true;
  try {
    if (sequence === undefined && bridgeReady) {
      const snapshot = await bridge.request({ type: 'read' });
      sequence = Number(snapshot.sequence); paths = snapshot.paths as string[];
    }
    if (paths.length) { await importPaths(paths, 'clipboard', sequence, aggressive); return; }
    // Prefer an encoded PNG clipboard payload, avoiding an unnecessary bitmap round trip.
    let bytes = Buffer.alloc(0);
    for (const item of await clipboard.read()) {
      const type = item.types.find(type => type === 'image/png' || type === 'electron application/osclipboard;format="PNG"') ?? item.types.find(type => type.startsWith('image/'));
      if (type) { const blob = await item.getType(type); if ('arrayBuffer' in blob) { bytes = Buffer.from(await blob.arrayBuffer()); break; } }
    }
    if (!bytes.length) {
      if (manual) {
        const text = (await clipboard.readText()).trim().replace(/^"|"$/g, '');
        if (path.isAbsolute(text)) await importPaths([text], 'clipboard', sequence);
        else inform('Copy an image or a local image file, then try again.');
      }
      return;
    }
    const hash = fingerprint(bytes);
    if (!manual && hash === lastFingerprint) return;
    lastFingerprint = hash;
    if (engine.list().length >= 40) throw new Error('The shelf holds 40 images. Dismiss a few before adding more.');
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
    { label: 'Open Clop', click: () => main.show() },
    { label: 'Show floating shelf', click: () => showFloating(true) },
    { label: 'Optimise clipboard', accelerator: 'Control+Shift+C', click: () => { void optimiseClipboard(undefined, [], true); } },
    { type: 'separator' },
    { label: 'Watch clipboard', type: 'checkbox', checked: settings.clipboard, click: item => { void updateSettings({ clipboard: item.checked }); } },
    { label: 'Keep drop zone visible', type: 'checkbox', checked: settings.pinned, click: item => { void updateSettings({ pinned: item.checked }); } },
    { label: 'Open originals and results', click: () => { void shell.openPath(storage); } },
    { type: 'separator' }, { label: 'Quit Clop', click: () => app.quit() },
  ]));
}
async function updateSettings(value: Partial<Settings>) {
  settings = parseSettings(value, settings);
  await writeFile(settingsPath, JSON.stringify(settings, null, 2));
  floating.setAlwaysOnTop(settings.alwaysOnTop);
  if (settings.pinned) showFloating();
  if (value.corner) positionFloating();
  if (process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: settings.launchAtLogin, path: process.execPath, args: ['--hidden'] });
  if (bridgeReady) await bridge.request({ type: 'settings', explorerDrag: settings.explorerDrag });
  updateTray(); broadcast();
}
function trusted(sender: Electron.WebContents) { return [main, floating].some(window => window && !window.isDestroyed() && window.webContents === sender); }
ipcMain.handle('clop:action', async (event, action: string, ...args: unknown[]) => {
  if (!trusted(event.sender)) throw new Error('Untrusted window.');
  const id = args[0] as string;
  switch (action) {
    case 'state': return state();
    case 'import': await importPaths(args[0] as string[]); break;
    case 'pick': {
      const result = await dialog.showOpenDialog(BrowserWindow.fromWebContents(event.sender)!, { properties: ['openFile', 'multiSelections'], filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'avif', 'tif', 'tiff'] }] });
      if (!result.canceled) await importPaths(result.filePaths, 'file'); break;
    }
    case 'sample': await engine.importBuffer(await sampleImage(), 'Alpine-study.png', 'sample', defaults()); break;
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
    case 'dismiss': await engine.dismiss(id); break;
    case 'settings': await updateSettings(args[0] as Partial<Settings>); break;
    case 'window':
      switch (args[0]) {
        case 'hide': BrowserWindow.fromWebContents(event.sender)?.hide(); break;
        case 'minimize': BrowserWindow.fromWebContents(event.sender)?.minimize(); break;
        case 'main': main.show(); break;
        case 'float': showFloating(true); break;
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
  app.on('second-instance', (_event, argv) => { main?.show(); const files = argv.filter(arg => /\.(png|jpe?g|webp|gif|avif|tiff?)$/i.test(arg) && path.isAbsolute(arg)); if (files.length) void importPaths(files, 'file'); });
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
    engine.on('change', broadcast);
    engine.on('ready', () => showFloating(false, true));
    await createWindows();
    const icon = nativeImage.createFromPath(path.join(here, 'icon.png'));
    tray = new Tray(icon); tray.setToolTip('Clop for Windows'); tray.on('double-click', () => main.show()); updateTray();
    for (const [key, callback] of [
      ['Control+Shift+C', () => { void optimiseClipboard(undefined, [], true); }],
      ['Control+Shift+A', () => { void optimiseClipboard(undefined, [], true, true); }],
      ['Control+Shift+Space', () => showFloating(true)],
    ] as const) if (!globalShortcut.register(key, callback)) inform(`${key} is already in use. Use the tray menu or floating shelf instead.`);
    if (process.platform === 'win32') {
      bridge.on('ready', () => { bridgeReady = true; void bridge.request({ type: 'settings', explorerDrag: settings.explorerDrag }).catch(error => inform(message(error))); });
      bridge.on('clipboard', event => { if (settings.clipboard) void optimiseClipboard(event.sequence, event.paths); });
      bridge.on('drag-start', () => { if (settings.explorerDrag) showFloating(false, true); });
      bridge.on('drag-end', () => {});
      bridge.on('notice', inform);
      bridge.on('stopped', () => { bridgeReady = false; startClipboardFallback(); });
      bridge.start(path.join(app.isPackaged ? process.resourcesPath : app.getAppPath(), 'native', 'bridge.ps1'));
    } else startClipboardFallback();
    const files = process.argv.slice(1).filter(arg => /\.(png|jpe?g|webp|gif|avif|tiff?)$/i.test(arg) && path.isAbsolute(arg));
    if (files.length) await importPaths(files, 'file');
  }).catch(error => { dialog.showErrorBox('Clop could not start', message(error)); app.quit(); });
  app.on('before-quit', () => { quitting = true; if (clipboardTimer) clearInterval(clipboardTimer); bridge.stop(); globalShortcut.unregisterAll(); });
  app.on('window-all-closed', () => { if (quitting) app.quit(); });
  app.on('activate', () => main?.show());
}
