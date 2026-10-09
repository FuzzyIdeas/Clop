import { build } from 'esbuild';
import { mkdir, writeFile } from 'node:fs/promises';
import sharp from 'sharp';
await mkdir('dist-electron', { recursive: true });
await build({ entryPoints: ['electron/main.ts'], bundle: true, platform: 'node', format: 'esm', target: 'node22', external: ['electron', 'sharp'], outdir: 'dist-electron' });
await build({ entryPoints: ['electron/native.ts'], bundle: true, platform: 'node', format: 'esm', target: 'node22', outfile: 'dist-electron/native-test.js' });
await build({ entryPoints: ['electron/preload.ts'], bundle: true, platform: 'node', format: 'cjs', target: 'node22', external: ['electron'], outfile: 'dist-electron/preload.cjs' });
await mkdir('assets', { recursive: true });
const png = await sharp('../Clop/Assets.xcassets/clop.imageset/clop_256.png').resize(256, 256).png().toBuffer();
await writeFile('assets/icon.png', png);
await writeFile('dist-electron/icon.png', png);
// Windows ICO supports a PNG payload. Include a 256x256 image directory entry.
const header = Buffer.alloc(22); header.writeUInt16LE(1, 2); header.writeUInt16LE(1, 4); header[8] = 0; header.writeUInt16LE(1, 10); header.writeUInt16LE(32, 12); header.writeUInt32LE(png.length, 14); header.writeUInt32LE(22, 18);
await writeFile('assets/icon.ico', Buffer.concat([header, png]));
