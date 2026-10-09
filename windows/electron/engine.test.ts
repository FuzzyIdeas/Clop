import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { ImageEngine, sampleImage } from './engine';
const balanced = { mode: 'balanced', format: 'auto', scale: 1 } as const;
async function fixture(t: { after: (fn: () => Promise<void>) => void }) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'clop-engine-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return { engine: new ImageEngine(dir), dir };
}
test('optimises an image, resizes from the original and restores exact source bytes', async t => {
  const { engine } = await fixture(t), original = await sampleImage();
  const id = await engine.importBuffer(original, 'study.png', 'drop', balanced);
  assert.equal(engine.get(id).result.status, 'ready');
  assert.ok(engine.get(id).result.outputBytes < original.length);
  await engine.apply(id, { ...balanced, scale: .25 });
  assert.deepEqual([engine.get(id).result.width, engine.get(id).result.height], [600, 400]);
  await engine.apply(id, { ...balanced, scale: .75 });
  assert.deepEqual([engine.get(id).result.width, engine.get(id).result.height], [1800, 1200]);
  await engine.restore(id);
  assert.deepEqual(await readFile(engine.output(id)), original);
  assert.equal(engine.get(id).result.restored, true);
});
test('respects maximum edge, aspect ratio and never enlarges', async t => {
  const { engine } = await fixture(t);
  const id = await engine.importBuffer(await sampleImage(), 'image.png', 'drop', balanced);
  await engine.apply(id, { ...balanced, maxEdge: 900 });
  assert.deepEqual([engine.get(id).result.width, engine.get(id).result.height], [900, 600]);
  await engine.apply(id, { ...balanced, maxEdge: 8000 });
  assert.deepEqual([engine.get(id).result.width, engine.get(id).result.height], [2400, 1600]);
});
test('source file stays untouched and no-op optimisation never increases its size', async t => {
  const { engine, dir } = await fixture(t);
  const original = await sharp({ create: { width: 32, height: 32, channels: 4, background: '#66449980' } }).png().toBuffer();
  const file = path.join(dir, 'source.png'); await writeFile(file, original);
  const id = await engine.importPath(file, 'file', { ...balanced, mode: 'lossless' });
  assert.ok(engine.get(id).result.outputBytes <= original.length);
  assert.deepEqual(await readFile(file), original);
  await engine.apply(id, { ...balanced, scale: .5, format: 'webp' });
  assert.deepEqual(await readFile(file), original);
});
test('lossless PNG preserves pixels and transparency', async t => {
  const { engine } = await fixture(t);
  const original = await sharp({ create: { width: 81, height: 55, channels: 4, background: '#74609b80' } }).png({ compressionLevel: 0 }).toBuffer();
  const id = await engine.importBuffer(original, 'alpha.png', 'drop', { ...balanced, mode: 'lossless' });
  assert.deepEqual(await sharp(engine.output(id)).raw().toBuffer(), await sharp(original).raw().toBuffer());
  assert.equal((await sharp(engine.output(id)).metadata()).hasAlpha, true);
});
test('lossless JPEG keeps exact bytes; resized lossless JPEG becomes PNG', async t => {
  const { engine } = await fixture(t);
  const original = await sharp(await sampleImage()).jpeg().toBuffer();
  const id = await engine.importBuffer(original, 'image.jpg', 'drop', { ...balanced, mode: 'lossless' });
  assert.deepEqual(await readFile(engine.output(id)), original);
  await engine.apply(id, { ...balanced, mode: 'lossless', scale: .5 });
  assert.equal(engine.get(id).result.format, 'png');
  assert.equal((await sharp(engine.output(id)).metadata()).format, 'png');
});
test('EXIF orientation defines displayed and resized dimensions', async t => {
  const { engine } = await fixture(t);
  const original = await sharp({ create: { width: 120, height: 80, channels: 3, background: '#376677' } }).withMetadata({ orientation: 6 }).jpeg().toBuffer();
  const id = await engine.importBuffer(original, 'rotated.jpg', 'drop', balanced);
  assert.deepEqual([engine.get(id).result.originalWidth, engine.get(id).result.originalHeight], [80, 120]);
  await engine.apply(id, { ...balanced, scale: .5 });
  assert.deepEqual([engine.get(id).result.width, engine.get(id).result.height], [40, 60]);
  const meta = await sharp(engine.output(id)).metadata(); assert.deepEqual([meta.width, meta.height], [40, 60]);
});
test('keeps animation frames and rejects conversion that would flatten them', async t => {
  const { engine } = await fixture(t);
  const a = await sharp({ create: { width: 48, height: 32, channels: 3, background: '#335566' } }).png().toBuffer();
  const b = await sharp({ create: { width: 48, height: 32, channels: 3, background: '#aa6688' } }).png().toBuffer();
  const original = await sharp([a, b], { join: { animated: true } }).gif({ delay: [100, 200], loop: 0 }).toBuffer();
  const id = await engine.importBuffer(original, 'animation.gif', 'drop', balanced);
  assert.equal(engine.get(id).result.animated, true);
  await engine.apply(id, { ...balanced, scale: .5, format: 'webp' });
  assert.equal(engine.get(id).result.status, 'ready', engine.get(id).result.error);
  const meta = await sharp(engine.output(id), { animated: true }).metadata();
  assert.equal(meta.pages, 2); assert.equal(meta.width, 24); assert.equal(meta.pageHeight, 16);
  assert.deepEqual(meta.delay, [100, 200]);
  await engine.apply(id, { ...balanced, format: 'jpeg' });
  assert.equal(engine.get(id).result.status, 'error');
  assert.match(engine.get(id).result.error!, /animation/);
  await engine.restore(id); assert.deepEqual(await readFile(engine.output(id)), original);
});
test('rejects unsupported files and invalid scale without losing existing results', async t => {
  const { engine } = await fixture(t);
  await assert.rejects(engine.importBuffer(Buffer.from('not an image'), 'file.txt', 'drop', balanced));
  await assert.rejects(engine.importBuffer(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"/>'), 'file.svg', 'drop', balanced), /Use PNG/);
  const id = await engine.importBuffer(await sampleImage(), 'image.png', 'drop', balanced);
  assert.throws(() => engine.apply(id, { ...balanced, scale: 2 }), /10%/);
  assert.equal(engine.get(id).result.status, 'ready');
});
test('serialises resize operations and serves the last requested result', async t => {
  const { engine } = await fixture(t);
  const id = await engine.importBuffer(await sampleImage(), 'image.png', 'drop', balanced);
  await Promise.all([engine.apply(id, { ...balanced, scale: .2 }), engine.apply(id, { ...balanced, scale: .8 })]);
  assert.equal(engine.get(id).result.width, 1920);
  const snapshot = engine.list(); snapshot[0].width = 1;
  assert.equal(engine.get(id).result.width, 1920);
});
