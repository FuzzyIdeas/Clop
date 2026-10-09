import { contextBridge, ipcRenderer, webUtils } from 'electron';
import type { AppState, ClopApi } from '../src/types';
const invoke = (action: string, ...args: unknown[]) => ipcRenderer.invoke('clop:action', action, ...args);
const api: ClopApi = {
  state: () => invoke('state'),
  subscribe: callback => {
    const listener = (_event: unknown, state: AppState) => callback(state);
    ipcRenderer.on('clop:state', listener);
    return () => { ipcRenderer.removeListener('clop:state', listener); };
  },
  importFiles: (files, aggressive) => invoke('import', files.map(file => webUtils.getPathForFile(file)).filter(Boolean), aggressive),
  importUrl: (url, aggressive) => invoke('import-url', url, aggressive),
  clipboard: () => invoke('clipboard'),
  apply: (id, options) => invoke('apply', id, options), restore: id => invoke('restore', id),
  copy: id => invoke('copy', id), save: id => invoke('save', id), reveal: id => invoke('reveal', id),
  drag: id => ipcRenderer.send('clop:drag', id), dismiss: id => invoke('dismiss', id),
  settings: settings => invoke('settings', settings), window: action => invoke('window', action),
};
contextBridge.exposeInMainWorld('clop', api);
