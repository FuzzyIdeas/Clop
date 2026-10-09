import sharp from 'sharp';
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import type { ImageOptions, ImageResult } from '../src/types';
import { parseOptions } from './settings';

sharp.concurrency(2);
sharp.cache({ memory: 32, files: 0, items: 32 });
const INPUT = new Set(['jpeg', 'png', 'webp', 'avif', 'heif', 'gif', 'tiff']);
const LIMIT = 128 * 1024 * 1024;
const PIXELS = 60_000_000;
const inputOptions = { animated: true, limitInputPixels: PIXELS, failOn: 'error' as const };
interface Entry { result: ImageResult; originalPath: string; outputPath: string; directory: string; inputFormat: string; revision: number }
export class ImageEngine extends EventEmitter {
  private entries = new Map<string, Entry>();
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private root: string) { super(); }
  list() { return [...this.entries.values()].map(e => structuredClone(e.result)).reverse(); }
  get(id: string) { const entry = this.entries.get(id); if (!entry) throw new Error('This image is no longer in the shelf.'); return entry; }
  output(id: string) { const entry = this.get(id); if (entry.result.status !== 'ready') throw new Error('Wait for this image to finish first.'); return entry.outputPath; }
  private changed() { this.emit('change'); }
  private schedule<T>(task: () => Promise<T>): Promise<T> { const run = this.queue.then(task, task); this.queue = run.catch(() => {}); return run; }
  async importPath(file: string, source: ImageResult['source'], options: ImageOptions) {
    const info = await stat(file);
    if (!info.isFile() || info.size > LIMIT) throw new Error('Choose an image file smaller than 128 MB.');
    return this.importBuffer(await readFile(file), path.basename(file), source, options);
  }
  async importBuffer(buffer: Buffer, name: string, source: ImageResult['source'], options: ImageOptions): Promise<string> {
    options = parseOptions(options);
    if (!buffer.length || buffer.length > LIMIT) throw new Error('Choose an image smaller than 128 MB.');
    return this.schedule(async () => {
      const meta = await sharp(buffer, inputOptions).metadata();
      if (!meta.format || !INPUT.has(meta.format) || !meta.width || !meta.height) throw new Error('Use PNG, JPEG, WebP, GIF, AVIF or TIFF. HEIC support depends on the installed codec.');
      if (meta.format === 'heif' && meta.compression !== 'av1') throw new Error('HEIC is not supported by this build. Export it as JPEG or PNG first.');
      const pages = meta.pages ?? 1;
      if (meta.format === 'tiff' && pages > 1) throw new Error('Use a single-page TIFF image. Multi-page documents are not supported.');
      const h = meta.pageHeight ?? meta.height;
      if (pages > 250 || meta.width * h * pages > PIXELS) throw new Error('This image has too many pixels or animation frames. Use an image under 60 megapixels in total.');
      const rotated = (meta.orientation ?? 1) >= 5;
      const width = rotated ? h : meta.width, height = rotated ? meta.width : h;
      const format = meta.format === 'heif' ? 'avif' : meta.format;
      const id = randomUUID(), directory = path.join(this.root, id);
      await mkdir(directory, { recursive: true });
      const originalPath = path.join(directory, `original.${format}`);
      try {
        await writeFile(originalPath, buffer);
        const preview = await thumbnail(originalPath);
        const result: ImageResult = {
          id, name: path.basename(name).slice(0, 160), source, status: 'processing', originalBytes: buffer.length,
          outputBytes: buffer.length, originalWidth: width, originalHeight: height, width, height, format,
          originalPreview: preview, preview, options, animated: pages > 1, createdAt: Date.now(),
        };
        this.entries.set(id, { result, originalPath, outputPath: originalPath, directory, inputFormat: format, revision: 0 });
        this.changed();
        await this.process(id, options);
        return id;
      } catch (error) { if (!this.entries.has(id)) await rm(directory, { recursive: true, force: true }); throw error; }
    });
  }
  apply(id: string, options: ImageOptions) {
    options = parseOptions(options);
    return this.schedule(() => this.process(id, options));
  }
  private async process(id: string, options: ImageOptions) {
    const e = this.get(id), r = e.result;
    r.status = 'processing'; r.error = undefined; this.changed();
    try {
      let format = options.format === 'auto' ? e.inputFormat : options.format;
      if (format === 'tiff') format = 'png';
      const factor = Math.min(options.scale, options.maxEdge ? options.maxEdge / Math.max(r.originalWidth, r.originalHeight) : 1);
      const width = Math.max(1, Math.round(r.originalWidth * factor)), height = Math.max(1, Math.round(r.originalHeight * factor));
      const resized = width !== r.originalWidth || height !== r.originalHeight;
      if (r.animated && !['webp', 'gif'].includes(format)) throw new Error('Choose GIF or WebP to keep all animation frames.');
      // JPEG cannot be re-encoded losslessly. Keep its original bytes, or use PNG after resizing.
      if (options.mode === 'lossless' && format === 'jpeg') {
        if (!resized && options.format === 'auto' && e.inputFormat === 'jpeg') {
          Object.assign(r, { status: 'ready', options, format, width, height, preview: r.originalPreview, outputBytes: r.originalBytes, unchanged: true, restored: false });
          e.outputPath = e.originalPath; this.changed(); this.emit('ready', id); return;
        }
        format = 'png';
      }
      const quality = options.mode === 'aggressive' ? 66 : 85;
      let pipeline = sharp(e.originalPath, inputOptions).autoOrient().resize(width, height, { fit: 'inside', withoutEnlargement: true }).keepIccProfile();
      switch (format) {
        case 'png': pipeline = pipeline.png({ compressionLevel: 9, palette: options.mode !== 'lossless', quality: options.mode === 'aggressive' ? 70 : 95, effort: 7 }); break;
        case 'jpeg': pipeline = pipeline.flatten({ background: '#ffffff' }).jpeg({ quality, mozjpeg: true }); break;
        case 'webp': pipeline = pipeline.webp({ quality, lossless: options.mode === 'lossless', effort: 5 }); break;
        case 'avif': pipeline = pipeline.avif({ quality: options.mode === 'aggressive' ? 45 : 60, lossless: options.mode === 'lossless', effort: 4 }); break;
        case 'gif': pipeline = pipeline.gif({ effort: 7, interFrameMaxError: options.mode === 'aggressive' ? 8 : 0 }); break;
        default: throw new Error('Choose a supported output format.');
      }
      const output = await pipeline.toBuffer();
      const unchanged = !resized && format === e.inputFormat && output.length >= r.originalBytes;
      const nextPath = unchanged ? e.originalPath : path.join(e.directory, `result-${++e.revision}.${format}`);
      if (!unchanged) await writeFile(nextPath, output);
      // Keep earlier results until the session ends: other apps may still be pasting or dragging them.
      e.outputPath = nextPath;
      Object.assign(r, { status: 'ready', options, format, width, height, outputBytes: unchanged ? r.originalBytes : output.length,
        preview: unchanged ? r.originalPreview : await thumbnail(nextPath), unchanged, restored: false });
      this.changed(); this.emit('ready', id);
    } catch (error) { r.status = 'error'; r.error = message(error); this.changed(); }
  }
  restore(id: string) { return this.schedule(async () => {
    const e = this.get(id);
    e.outputPath = e.originalPath;
    Object.assign(e.result, { status: 'ready', width: e.result.originalWidth, height: e.result.originalHeight, outputBytes: e.result.originalBytes,
      format: e.inputFormat, preview: e.result.originalPreview, options: { ...e.result.options, scale: 1, maxEdge: undefined, format: 'auto' }, restored: true, unchanged: true, error: undefined });
    this.changed(); this.emit('ready', id);
  }); }
  dismiss(id: string) { return this.schedule(async () => { this.get(id); this.entries.delete(id); this.changed(); }); }
  async idle() { await this.queue; }
}
async function thumbnail(file: string) {
  const bytes = await sharp(file, { limitInputPixels: PIXELS }).autoOrient().resize({ width: 1000, height: 760, fit: 'inside', withoutEnlargement: true }).png().toBuffer();
  return `data:image/png;base64,${bytes.toString('base64')}`;
}
export function message(error: unknown) { return error instanceof Error ? error.message : String(error); }
export async function sampleImage() {
  const svg = `<svg width="2400" height="1600" xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="sky" x2="0" y2="1"><stop stop-color="#b0cbd5"/><stop offset="1" stop-color="#eee2cf"/></linearGradient><linearGradient id="hill" x2="0" y2="1"><stop stop-color="#65867d"/><stop offset="1" stop-color="#354e56"/></linearGradient></defs><rect width="2400" height="1600" fill="url(#sky)"/><circle cx="1670" cy="440" r="180" fill="#f8ebca"/><path d="M0 1150L540 430 1150 1220 1600 680 2400 1170V1600H0Z" fill="#94a4a0"/><path d="M0 1300L500 900 1000 1320 1550 850 2400 1330V1600H0Z" fill="url(#hill)"/><path d="M0 1450Q550 1110 1250 1450T2400 1360V1600H0Z" fill="#2a434a"/><path d="M390 635L540 430 770 725 540 640 480 705Z" fill="#eff0e6"/></svg>`;
  return sharp(Buffer.from(svg)).png({ compressionLevel: 0 }).toBuffer();
}
