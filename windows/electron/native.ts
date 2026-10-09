import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
export class WindowsBridge extends EventEmitter {
  private process?: ChildProcessWithoutNullStreams;
  private pending = new Map<string, { resolve: (reply: Record<string, unknown>) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  start(script: string) {
    this.process = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', script], { windowsHide: true, stdio: 'pipe' });
    createInterface({ input: this.process.stdout }).on('line', line => {
      try {
        const event = JSON.parse(line);
        if (event.type === 'reply') {
          const waiting = this.pending.get(event.id);
          if (waiting) { clearTimeout(waiting.timer); this.pending.delete(event.id); event.ok ? waiting.resolve(event) : waiting.reject(new Error(event.error)); }
        } else this.emit(event.type, event);
      } catch { this.emit('notice', 'The Windows helper sent an unreadable response.'); }
    });
    let stderr = '';
    this.process.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-4000); });
    this.process.on('error', error => this.emit('notice', `Windows helper could not start: ${error.message}`));
    this.process.on('exit', () => {
      for (const waiting of this.pending.values()) { clearTimeout(waiting.timer); waiting.reject(new Error('Windows helper stopped. Restart Clop to reconnect.')); }
      this.pending.clear(); this.process = undefined;
      this.emit('stopped');
      if (stderr) this.emit('notice', `Windows helper stopped: ${stderr.slice(-600)}`);
    });
  }
  request(command: Record<string, unknown>): Promise<Record<string, unknown>> {
    if (!this.process || !this.process.stdin.writable) return Promise.reject(new Error('Windows helper is unavailable. Restart Clop to reconnect.'));
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('Windows clipboard is busy. Try copying again.')); }, 12000);
      this.pending.set(id, { resolve, reject, timer });
      this.process!.stdin.write(JSON.stringify({ ...command, id }) + '\n');
    });
  }
  stop() { this.process?.stdin.end(); this.process?.kill(); }
}
