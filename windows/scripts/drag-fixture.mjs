import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import path from 'node:path';

// A separate native Windows app supplies real image OLE drags, text selection,
// text OLE drags, window movement and resizing. No production test hooks.
export async function dragFixture(image) {
  return sourceFixture('drag-source.ps1', image);
}
export async function explorerFixture(image) {
  return sourceFixture('explorer-source.ps1', image, true);
}
async function sourceFixture(script, image, graceful = false) {
  const source = spawn('powershell.exe', ['-NoProfile', '-Sta', '-File', path.resolve('scripts', script), '-Image', image], { stdio: 'pipe' });
  let output = '';
  source.stderr.on('data', data => { output += data; });
  const lines = createInterface({ input: source.stdout });
  lines.on('line', line => { if (!line.startsWith('{')) console.log(line); });
  const ready = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Drag source did not start: ${output}`)), 35000);
    lines.once('line', line => { clearTimeout(timer); resolve(JSON.parse(line)); });
    source.once('exit', code => { clearTimeout(timer); reject(new Error(`Drag source exited ${code}: ${output}`)); });
  }).catch(error => { source.kill(); lines.close(); throw error; });
  const gestures = new Set();
  return {
    window: ready.window,
    gesture(kind, { hold = 600, escape = false, pressDelay = 300, moveX = 90, moveY = 40 } = {}) {
      const point = ready[kind];
      const args = ['-NoProfile', '-File', path.resolve('scripts/drag-gesture.ps1'), '-Window', String(ready.window), '-Width', String(ready.width), '-Height', String(ready.height), '-X', String(point.x), '-Y', String(point.y), '-Hold', String(hold), '-PressDelay', String(pressDelay), '-MoveX', String(moveX), '-MoveY', String(moveY)];
      if (escape) args.push('-Escape');
      const process = spawn('powershell.exe', args, { stdio: 'pipe' });
      gestures.add(process);
      let errors = ''; process.stderr.on('data', data => { errors += data; }); process.stdout.on('data', data => { errors += data; });
      const timer = setTimeout(() => { errors += '\nGesture exceeded 15 seconds'; process.kill(); }, 15000);
      return once(process, 'exit').then(([code]) => {
        clearTimeout(timer);
        gestures.delete(process);
        if (code !== 0) throw new Error(`Windows ${kind} gesture failed (${code}): ${errors}`);
      });
    },
    async stop() {
      for (const process of gestures) if (process.exitCode === null) process.kill();
      lines.close();
      if (source.exitCode === null) {
        const exited = once(source, 'exit');
        if (graceful) source.stdin.end(); else source.kill();
        const timer = setTimeout(() => source.kill(), 5000);
        await exited; clearTimeout(timer);
      }
    },
  };
}
