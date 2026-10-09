import { useCallback, useEffect, useRef, useState, type DragEvent } from 'react';
import { api } from './api';
import { Icon } from './icons';
import type { AppState, ImageOptions, ImageResult, Settings } from './types';

const floating = new URLSearchParams(location.search).has('floating');
const bytes = (value: number) => value >= 1024 * 1024 ? `${(value / 1024 / 1024).toFixed(2)} MB` : `${(value / 1024).toFixed(1)} KB`;
type Run = (task: () => Promise<unknown>, success?: string) => Promise<void>;

export function App() {
  const [state, setState] = useState<AppState>();
  const [section, setSection] = useState<'workspace' | 'shelf' | 'settings'>('workspace');
  const [selected, setSelected] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState('');
  const [error, setError] = useState('');
  const [dragging, setDragging] = useState(false);
  const lastNewest = useRef<string | undefined>(undefined);
  const dragDepth = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const item = state?.items.find(item => item.id === selected) ?? state?.items[0];

  useEffect(() => { api.state().then(setState).catch(error => setError(error.message)); return api.subscribe(setState); }, []);
  useEffect(() => {
    const newest = state?.items[0]?.id;
    if (newest && lastNewest.current !== newest) { setSelected(newest); lastNewest.current = newest; }
  }, [state?.items[0]?.id]);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  const run: Run = useCallback(async (task, success) => {
    setBusy(true); setError(''); setToast('');
    try {
      await task(); setState(await api.state());
      if (success) { setToast(success); if (timer.current) clearTimeout(timer.current); timer.current = setTimeout(() => setToast(''), 3500); }
    } catch (error) { setError(error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': Error: /, '') : String(error)); }
    finally { setBusy(false); }
  }, []);
  useEffect(() => {
    const paste = (event: ClipboardEvent) => {
      if (event.target instanceof HTMLElement && ['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target.tagName)) return;
      const files = Array.from(event.clipboardData?.files ?? []);
      if (files.length || state?.native) { event.preventDefault(); void run(() => state?.native ? api.clipboard() : api.importFiles(files)); }
    };
    document.addEventListener('paste', paste); return () => document.removeEventListener('paste', paste);
  }, [run, state?.native]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.target instanceof HTMLElement && (['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target.tagName) || event.target.isContentEditable)) return;
      if (!item || item.status !== 'ready' || busy || event.ctrlKey || event.metaKey || event.altKey) return;
      if (/^[1-9]$/.test(event.key)) { event.preventDefault(); void run(() => api.apply(item.id, { ...item.options, maxEdge: undefined, scale: Number(event.key) / 10 })); }
      else if (event.key === '-') { event.preventDefault(); void run(() => api.apply(item.id, { ...item.options, maxEdge: undefined, scale: Math.max(.1, Math.round((item.width / item.originalWidth - .1) * 10) / 10) })); }
      else if (event.key.toLowerCase() === 'r') void run(() => api.restore(item.id), 'Original restored');
      else if (event.key.toLowerCase() === 'c') void run(() => api.copy(item.id), 'Copied to clipboard');
      else if (event.key === 'Escape' && floating) void api.window('hide');
    };
    document.addEventListener('keydown', key); return () => document.removeEventListener('keydown', key);
  }, [item, run, busy]);
  function drop(event: DragEvent) { event.preventDefault(); dragDepth.current = 0; setDragging(false); const files = Array.from(event.dataTransfer.files); if (files.length) void run(() => api.importFiles(files)); }
  if (!state) return <div className="loading">{error || 'Opening Clop…'}</div>;
  const ready = state.items.filter(item => item.status === 'ready');
  const saved = ready.reduce((total, item) => total + Math.max(0, item.originalBytes - item.outputBytes), 0);
  const watching = state.native && state.settings.clipboard;
  const choose = (id: string) => { setSelected(id); setSection('workspace'); };
  return <div className={`app ${floating ? 'floating' : ''}`} onDragOver={event => { if (event.dataTransfer.types.includes('Files')) { event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; } }}
    onDragEnter={event => { if (event.dataTransfer.types.includes('Files')) { event.preventDefault(); dragDepth.current++; setDragging(true); } }}
    onDragLeave={() => { dragDepth.current = Math.max(0, dragDepth.current - 1); if (!dragDepth.current) setDragging(false); }} onDrop={drop}>
    {!floating && <aside className="sidebar">
      <div className="brand"><div className="brand-icon"><Icon name="image" size={25}/></div><div><strong>Clop</strong><span>for Windows</span></div></div>
      <nav aria-label="Main navigation">
        <button className={section === 'workspace' ? 'active' : ''} onClick={() => setSection('workspace')}><Icon name="clipboard"/>Image tools</button>
        <button className={section === 'shelf' ? 'active' : ''} onClick={() => setSection('shelf')}><Icon name="shelf"/>Shelf<span className="count">{state.items.length}</span></button>
        <button className={section === 'settings' ? 'active' : ''} onClick={() => setSection('settings')}><Icon name="settings"/>Settings</button>
      </nav>
      <div className="sidebar-bottom">
        <button className="float-launch" onClick={() => void run(() => api.window('float'))}><Icon name="float"/><span>Open floating shelf<small>Ctrl + Shift + Space</small></span></button>
        <div className="watch-state"><span className={`status-dot ${watching ? 'on' : ''}`}/>{watching ? 'Watching your clipboard' : state.native ? 'Clipboard watching paused' : 'Browser preview'}</div>
        <p className="version">0.1 · Images only</p>
      </div>
    </aside>}
    <main className="main">
      <header className="topbar">
        {floating ? <><div className="float-brand"><span className="brand-icon"><Icon name="image" size={18}/></span><strong>Clop</strong><span className={`status-dot ${watching ? 'on' : ''}`} title={watching ? 'Watching clipboard' : 'Clipboard paused'}/></div><div className="window-actions">
          <button className={`icon-button ${state.settings.pinned ? 'selected' : ''}`} aria-label="Keep drop zone visible" title="Keep drop zone visible" disabled={!state.native} onClick={() => void run(() => api.settings({ pinned: !state.settings.pinned }))}><Icon name="pin" size={17}/></button>
          <button className="icon-button" aria-label="Open main window" title="Open main window" onClick={() => void api.window('main')}><Icon name="float" size={17}/></button>
          <button className="icon-button" aria-label="Hide floating shelf" title="Hide floating shelf" onClick={() => void api.window('hide')}><Icon name="close" size={17}/></button>
        </div></> : <><span className="breadcrumb">{section === 'workspace' ? 'Image tools' : section === 'shelf' ? 'Your shelf' : 'Settings'}</span><div className="topbar-actions"><span className="local-label"><span className="status-dot on"/>Processed on this device</span><button className="button small" onClick={() => void run(() => api.pick())} disabled={busy}><Icon name="folder" size={16}/>Open images</button></div></>}
      </header>
      <div className="content">
        {error && <div className="notice error" role="alert"><span>{error}</span><button className="icon-button" aria-label="Dismiss error" onClick={() => setError('')}><Icon name="close" size={16}/></button></div>}
        {state.notice && <div className="notice" role="status">{state.notice}</div>}
        {!state.native && !floating && <div className="preview-note">Image processing works here. Background clipboard watching, Explorer detection and the tray run in the Windows app.</div>}
        {section === 'settings' ? <SettingsPanel settings={state.settings} native={state.native} run={run}/> : section === 'shelf' ? <>
          <div className="section-heading"><div><h1>Your shelf</h1><p>Pick an image to resize it or use it again.</p></div><span className="shelf-total">{saved > 0 ? `${bytes(saved)} saved` : `${state.items.length} images`}</span></div>
          {state.items.length ? <div className="shelf-grid">{state.items.map(image => <button className="shelf-tile" key={image.id} onClick={() => choose(image.id)}><div className="tile-preview"><img src={image.preview} alt=""/></div><strong>{image.name}</strong><span>{image.status === 'processing' ? 'Optimising…' : image.status === 'error' ? 'Needs attention' : `${image.width} × ${image.height} · ${bytes(image.outputBytes)}`}</span></button>)}</div> : <DropZone compact={false} busy={busy} run={run}/>}
        </> : <>
          {!floating && <div className="section-heading"><div><h1>{item ? 'Ready for the next paste.' : 'Copy large. Paste small.'}</h1><p>{item ? 'Optimise, resize and send it on. Your original stays safe.' : 'Drop an image, resize it, and keep the result ready to paste.'}</p></div><div className="format-tags">{['PNG', 'JPEG', 'WebP', 'GIF'].map(format => <span key={format}>{format}</span>)}</div></div>}
          <DropZone compact={!!item || floating} busy={busy} run={run}/>
          {item ? <ImageEditor key={item.id} item={item} native={state.native} busy={busy} run={run}/> : <div className="empty-guide">
            <div className="guide-icon"><Icon name="clipboard" size={24}/></div><h2>{floating ? 'Drop an image. Keep moving.' : 'Your clipboard, a little lighter.'}</h2><p>{watching ? 'Copy an image anywhere. Clop will optimise it and show the result here, ready to paste.' : 'Drop an image above, open a file, or paste one with Ctrl+V.'}</p>
            <button className="text-button" disabled={busy} onClick={() => void run(() => api.sample())}>Try it with a sample image<Icon name="arrow" size={15}/></button>
            {!floating && <div className="shortcut-guide"><span><kbd>1</kbd> through <kbd>9</kbd> to resize</span><span><kbd>C</kbd> to copy</span><span><kbd>R</kbd> to restore</span></div>}
          </div>}
          {state.items.length > 1 && <div className="recent-strip"><div className="mini-heading">On your shelf<span>{state.items.length}</span></div><div className="recent-items">{state.items.slice(0, 8).map(image => <button key={image.id} className={`recent-item ${image.id === item?.id ? 'active' : ''}`} onClick={() => setSelected(image.id)} title={image.name} aria-label={`Select ${image.name}`}><img src={image.preview} alt=""/><span>{image.name}</span></button>)}</div></div>}
        </>}
      </div>
      <footer className="footer"><span>{busy ? 'Working on your image…' : toast || (floating ? 'Ctrl + Shift + C · Optimise clipboard' : 'Originals stay untouched. Everything runs locally.')}</span>{busy ? <span className="spinner"/> : <span>{floating ? `${state.items.length} on shelf` : 'Clop for Windows'}</span>}</footer>
    </main>
    {dragging && <div className="drag-overlay"><div><Icon name="drop" size={46}/><h2>Drop to optimise</h2><p>Images only. Originals stay untouched.</p></div></div>}
  </div>;
}

function DropZone({ compact, busy, run }: { compact: boolean; busy: boolean; run: Run }) {
  return <div className={`dropzone ${compact ? 'compact' : ''}`}>
    <div className="drop-symbol"><Icon name="drop" size={compact ? 22 : 34}/></div>
    <div><strong>{compact ? 'Drop another image here' : 'Drop your images here'}</strong><p>{compact ? 'or paste with Ctrl+V' : 'PNG, JPEG, WebP, GIF, AVIF and TIFF'}</p></div>
    <div className="drop-actions"><button className="button primary" disabled={busy} onClick={() => void run(() => api.pick())}>{compact ? 'Browse' : 'Choose images'}</button>{!compact && <button className="button" disabled={busy} onClick={() => void run(() => api.clipboard())}><Icon name="clipboard" size={16}/>From clipboard</button>}</div>
  </div>;
}

function ImageEditor({ item, native, busy, run }: { item: ImageResult; native: boolean; busy: boolean; run: Run }) {
  const [comparing, setComparing] = useState(false);
  const [compare, setCompare] = useState(50);
  const [scale, setScale] = useState(Math.round(item.options.scale * 100));
  const [edge, setEdge] = useState(item.options.maxEdge?.toString() ?? '');
  useEffect(() => { setScale(Math.round(item.options.scale * 100)); setEdge(item.options.maxEdge?.toString() ?? ''); }, [item.options.scale, item.options.maxEdge]);
  const processing = busy || item.status === 'processing';
  const ready = item.status === 'ready';
  const saving = Math.round((1 - item.outputBytes / item.originalBytes) * 1000) / 10;
  const apply = (options: Partial<ImageOptions>) => { void run(() => api.apply(item.id, { ...item.options, ...options })); };
  return <article className="image-editor" aria-label={`Image tools for ${item.name}`}>
    <div className="image-heading"><div className="image-name"><Icon name="image" size={18}/><strong title={item.name}>{item.name}</strong><span className="source-label">{item.source === 'clipboard' ? 'Clipboard' : item.source === 'sample' ? 'Sample' : 'File'}{item.animated ? ' · animated' : ''}</span></div><button className="icon-button" disabled={processing} title="Dismiss image" aria-label="Dismiss image" onClick={() => void run(() => api.dismiss(item.id))}><Icon name="close" size={16}/></button></div>
    <div className={`image-preview ${processing ? 'processing' : ''}`}>
      <div className="preview-images" draggable={native && ready} title={native ? 'Drag the image into another app' : 'Use Save image to download the result'} onDragStart={event => { event.preventDefault(); if (native && ready) api.drag(item.id); }}>
        <img src={item.preview} alt={`Optimised ${item.name}`} draggable={false}/>
        {comparing && <><img className="original-layer" src={item.originalPreview} alt="Original image" draggable={false} style={{ clipPath: `inset(0 ${100 - compare}% 0 0)` }}/><div className="compare-line" style={{ left: `${compare}%` }}><span>↔</span></div><span className="compare-label left">Original</span><span className="compare-label right">Result</span></>}
      </div>
      <button className={`compare-toggle ${comparing ? 'selected' : ''}`} disabled={processing} onClick={() => setComparing(!comparing)}><Icon name="compare" size={15}/>{comparing ? 'Close comparison' : 'Compare'}</button>
      {processing && <div className="processing-label"><span className="spinner"/>Optimising…</div>}
      {!comparing && native && ready && <span className="drag-hint">Drag into any app</span>}
    </div>
    {comparing && <div className="compare-control"><span>Original</span><input type="range" min="0" max="100" value={compare} onChange={event => setCompare(Number(event.target.value))} aria-label="Comparison position"/><span>Result</span></div>}
    <div className="result-stats"><div><span className="stat-label">File size</span><div className="size-flow"><span>{bytes(item.originalBytes)}</span><Icon name="arrow" size={13}/><strong>{bytes(item.outputBytes)}</strong></div></div><div className="result-dimensions"><span className="stat-label">{item.width} × {item.height} · {item.format.toUpperCase()}</span><span className={`savings ${saving < 0 ? 'larger' : ''}`}>{item.restored ? 'Original restored' : item.unchanged ? 'Already small' : saving > 0 ? `${saving}% smaller` : saving < 0 ? `${Math.abs(saving)}% larger` : 'Same file size'}</span></div></div>
    {item.error && <div className="notice error" role="alert">{item.error} Change the settings or restore the original.</div>}
    <div className="tool-controls">
      <div className="control-heading"><label>Compression</label><span>{item.options.mode === 'lossless' ? 'Keep pixel detail' : item.options.mode === 'aggressive' ? 'Smaller file, less detail' : 'Quality comes first'}</span></div>
      <div className="segmented" role="group" aria-label="Compression mode">{(['balanced', 'aggressive', 'lossless'] as const).map(mode => <button key={mode} disabled={processing} className={item.options.mode === mode ? 'active' : ''} onClick={() => apply({ mode })}>{mode === 'balanced' ? 'Balanced' : mode === 'aggressive' ? 'Smaller' : 'Lossless'}</button>)}</div>
      <div className="control-heading scale-heading"><label htmlFor={`scale-${item.id}`}>Downscale</label><span className="scale-value">{scale}% <small>of original</small></span></div>
      <div className="resize-row"><input id={`scale-${item.id}`} type="range" min="10" max="100" step="5" disabled={processing} value={scale} onChange={event => setScale(Number(event.target.value))} onPointerUp={event => apply({ scale: Number(event.currentTarget.value) / 100, maxEdge: undefined })} onKeyUp={event => { if (['ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown'].includes(event.key)) apply({ scale: Number(event.currentTarget.value) / 100, maxEdge: undefined }); }}/><div className="presets">{[100, 75, 50, 25].map(value => <button disabled={processing} key={value} className={scale === value && !item.options.maxEdge ? 'active' : ''} onClick={() => apply({ scale: value / 100, maxEdge: undefined })}>{value}%</button>)}</div></div>
      <div className="format-row"><div className="edge-control"><label htmlFor={`edge-${item.id}`}>Longest edge</label><div className="input-with-button"><input id={`edge-${item.id}`} type="number" min="1" max="16000" placeholder="Original" value={edge} disabled={processing} onChange={event => setEdge(event.target.value)} onKeyDown={event => { if (event.key === 'Enter' && edge) apply({ maxEdge: Number(edge), scale: 1 }); }}/><span>px</span><button aria-label="Apply longest edge" disabled={processing || !edge} onClick={() => apply({ maxEdge: Number(edge), scale: 1 })}><Icon name="arrow" size={14}/></button></div></div><div className="format-control"><label htmlFor={`format-${item.id}`}>Format</label><select id={`format-${item.id}`} value={item.options.format} disabled={processing} onChange={event => apply({ format: event.target.value as ImageOptions['format'] })}><option value="auto">Keep format</option><option value="png">PNG</option><option value="jpeg">JPEG</option><option value="webp">WebP</option><option value="avif">AVIF</option><option value="gif">GIF</option></select></div></div>
    </div>
    <div className="image-actions"><button className="button primary" disabled={!ready || processing} onClick={() => void run(() => api.copy(item.id), 'Copied to clipboard')}><Icon name="copy" size={16}/>Copy image</button><button className="button" disabled={!ready || processing} onClick={() => void run(() => api.save(item.id))}><Icon name="down" size={16}/>Save image</button><div className="utility-actions"><button className="icon-button" title="Restore original (R)" aria-label="Restore original" disabled={processing} onClick={() => void run(() => api.restore(item.id), 'Original restored')}><Icon name="restore" size={19}/></button>{native && <button className="icon-button" title="Show in Explorer" aria-label="Show in Explorer" disabled={!ready || processing} onClick={() => void run(() => api.reveal(item.id))}><Icon name="folder" size={19}/></button>}</div></div>
  </article>;
}

function SettingsPanel({ settings, native, run }: { settings: Settings; native: boolean; run: Run }) {
  function toggle(key: keyof Settings, title: string, description: string) {
    return <label className="setting-row" key={key}><span><strong>{title}</strong><small>{description}</small></span><input className="switch" type="checkbox" checked={Boolean(settings[key])} disabled={!native} onChange={event => void run(() => api.settings({ [key]: event.target.checked }))}/></label>;
  }
  return <div className="settings-panel"><div className="section-heading"><div><h1>Make Clop yours.</h1><p>Keep it nearby, and let the clipboard do the work.</p></div></div>
    <section className="settings-section"><h2>Clipboard</h2>{toggle('clipboard', 'Optimise copied images', 'Watch for images and image files copied from Explorer.')}{toggle('autoCopy', 'Keep the result ready to paste', 'Copy the result after an optimisation or resize.')}<div className="setting-row"><span><strong>Default compression</strong><small>Used when a new image arrives.</small></span><select aria-label="Default compression" value={settings.defaultMode} onChange={event => void run(() => api.settings({ defaultMode: event.target.value as Settings['defaultMode'] }))}><option value="balanced">Balanced</option><option value="aggressive">Smaller</option><option value="lossless">Lossless</option></select></div><div className="setting-row"><span><strong>Default format</strong><small>Transparent images stay transparent unless you choose JPEG.</small></span><select aria-label="Default format" value={settings.defaultFormat} onChange={event => void run(() => api.settings({ defaultFormat: event.target.value as Settings['defaultFormat'] }))}><option value="auto">Keep format</option><option value="png">PNG</option><option value="jpeg">JPEG</option><option value="webp">WebP</option><option value="avif">AVIF</option><option value="gif">GIF</option></select></div></section>
    <section className="settings-section"><h2>Floating shelf</h2>{toggle('explorerDrag', 'Appear when dragging from Explorer', 'Show the drop target when you drag a selected image file.')}{toggle('pinned', 'Keep the drop zone visible', 'A permanent place to drop images from any app.')}{toggle('alwaysOnTop', 'Stay above other windows', 'Keep the floating shelf within reach.')}<div className="setting-row"><span><strong>Screen corner</strong><small>On the screen where your cursor is. Drag the header to move it.</small></span><select aria-label="Screen corner" disabled={!native} value={settings.corner} onChange={event => void run(() => api.settings({ corner: event.target.value as Settings['corner'] }))}>{(['bottom-right', 'bottom-left', 'top-right', 'top-left'] as const).map(corner => <option key={corner} value={corner}>{corner.replace('-', ' ').replace(/^./, c => c.toUpperCase())}</option>)}</select></div>{toggle('launchAtLogin', 'Start with Windows', 'Open quietly in the tray when you sign in.')}</section>
    <section className="settings-section"><h2>Keyboard shortcuts</h2><div className="shortcut-row"><span>Optimise clipboard</span><kbd>Ctrl + Shift + C</kbd></div><div className="shortcut-row"><span>Use smaller compression</span><kbd>Ctrl + Shift + A</kbd></div><div className="shortcut-row"><span>Show floating shelf</span><kbd>Ctrl + Shift + Space</kbd></div><div className="shortcut-row"><span>Resize selected image</span><kbd>1–9 · 10–90%</kbd></div><div className="shortcut-row"><span>Copy / restore selected image</span><kbd>C / R</kbd></div></section>
    <p className="settings-footnote">Clop keeps source files untouched. Originals and results stay in its local image folder for seven days. The shelf starts fresh when the app restarts.</p>
    {native && <button className="text-button" onClick={() => void api.window('quit')}>Quit Clop</button>}
  </div>;
}
