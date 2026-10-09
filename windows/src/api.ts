import type { AppState, ClopApi } from './types';
async function request(action: string, body?: unknown): Promise<AppState> {
  const response = await fetch(`/api/${action}`, body === undefined ? undefined : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'The image operation failed. Try again.');
  return data;
}
async function importFiles(files: File[]) {
  if (files.length > 20) throw new Error('Drop up to 20 images at a time.');
  for (const file of files) {
    if (file.size > 32 * 1024 * 1024) throw new Error('Use an image smaller than 32 MB in the browser preview.');
    const data = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader(); reader.onload = () => resolve(String(reader.result).split(',')[1]); reader.onerror = () => reject(new Error('Could not read this image.')); reader.readAsDataURL(file);
    });
    await request('import', { name: file.name, data });
  }
}
function download(id: string) { const link = document.createElement('a'); link.href = `/api/output/${id}`; link.download = ''; link.click(); }
const browser: ClopApi = {
  state: () => request('state'),
  subscribe(callback) {
    let active = true, busy = false;
    const timer = setInterval(async () => { if (busy) return; busy = true; try { const state = await request('state'); if (active) callback(state); } catch {} finally { busy = false; } }, 650);
    return () => { active = false; clearInterval(timer); };
  },
  importFiles,
  async pick() {
    const input = document.createElement('input'); input.type = 'file'; input.multiple = true; input.accept = '.png,.jpg,.jpeg,.gif,.webp,.avif,.tif,.tiff';
    return new Promise<void>((resolve, reject) => { input.onchange = () => importFiles(Array.from(input.files || [])).then(resolve, reject); input.addEventListener('cancel', () => resolve()); input.click(); });
  },
  sample: async () => { await request('sample', {}); },
  clipboard: async () => {
    if (!navigator.clipboard?.read) throw new Error('Paste an image with Ctrl+V, or drop an image file here.');
    const items = await navigator.clipboard.read();
    for (const item of items) { const type = item.types.find(t => t.startsWith('image/')); if (type) { await importFiles([new File([await item.getType(type)], 'Clipboard.png', { type })]); return; } }
    throw new Error('Copy an image first, then paste it here.');
  },
  apply: async (id, options) => { await request('apply', { id, options }); },
  restore: async id => { await request('restore', { id }); },
  copy: async id => {
    if (!navigator.clipboard?.write) throw new Error('Clipboard access needs HTTPS. Use Save image in this preview.');
    const response = await fetch(`/api/png/${id}`); if (!response.ok) throw new Error('Could not copy this image.');
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': await response.blob() })]);
  },
  save: async id => download(id), reveal: async id => download(id), drag: () => {},
  dismiss: async id => { await request('dismiss', { id }); },
  settings: async settings => { await request('settings', settings); },
  window: async action => { if (action === 'float') window.open('/?floating=1', 'clop-floating', 'width=420,height=660'); },
};
export const api = window.clop ?? browser;
