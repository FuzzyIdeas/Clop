import { build } from 'esbuild';
import { mkdir, writeFile } from 'node:fs/promises';
import sharp from 'sharp';
await mkdir('dist-electron', { recursive: true });
await build({ entryPoints: ['electron/main.ts'], bundle: true, platform: 'node', format: 'esm', target: 'node22', external: ['electron', 'sharp'], outdir: 'dist-electron' });
await build({ entryPoints: ['electron/native.ts'], bundle: true, platform: 'node', format: 'esm', target: 'node22', outfile: 'dist-electron/native-test.js' });
await build({ entryPoints: ['electron/preload.ts'], bundle: true, platform: 'node', format: 'cjs', target: 'node22', external: ['electron'], outfile: 'dist-electron/preload.cjs' });
await mkdir('assets', { recursive: true });
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><rect width="256" height="256" rx="64" fill="#7762c9"/><rect x="52" y="64" width="152" height="128" rx="20" fill="#f7f5ff"/><circle cx="95" cy="107" r="16" fill="#b9a9ea"/><path d="M65 176l46-46 26 26 31-38 25 58z" fill="#7762c9"/></svg>`;
const png = await sharp(Buffer.from(svg)).png().toBuffer();
await writeFile('assets/icon.png', png);
await writeFile('dist-electron/icon.png', png);
// Windows ICO supports a PNG payload. Include a 256x256 image directory entry.
const header = Buffer.alloc(22); header.writeUInt16LE(1, 2); header.writeUInt16LE(1, 4); header[8] = 0; header.writeUInt16LE(1, 10); header.writeUInt16LE(32, 12); header.writeUInt32LE(png.length, 14); header.writeUInt32LE(22, 18);
await writeFile('assets/icon.ico', Buffer.concat([header, png]));
