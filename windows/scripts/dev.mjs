import { spawn } from 'node:child_process';
import electron from 'electron';
import './build.mjs';
const vite = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '5274', '--strictPort'], { stdio: 'inherit' });
let desktop;
const stop = () => { desktop?.kill(); vite.kill(); };
process.on('SIGINT', stop); process.on('SIGTERM', stop);
for (let i = 0; i < 100; i++) {
  try { if ((await fetch('http://127.0.0.1:5274')).ok) break; } catch {}
  await new Promise(resolve => setTimeout(resolve, 100));
}
desktop = spawn(electron, ['.'], { stdio: 'inherit', env: { ...process.env, CLOP_DEV_URL: 'http://127.0.0.1:5274' } });
desktop.on('exit', () => { vite.kill(); });
vite.on('exit', () => { desktop?.kill(); });
