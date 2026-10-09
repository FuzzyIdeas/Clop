import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';
import { ImageEngine, message } from './electron/engine';
import { defaultSettings, parseSettings } from './electron/settings';
import type { ImageOptions } from './src/types';

function localImagePreview(): Plugin {
  let settings = { ...defaultSettings };
  const engine = new ImageEngine(path.resolve('.preview-data', `session-${Date.now()}`));
  return {
    name: 'clop-local-image-preview',
    transformIndexHtml(html, context) {
      // Vite's React refresh preamble is inline in development only.
      return context.server ? html.replace("script-src 'self';", "script-src 'self' 'unsafe-inline'; worker-src 'self' blob:;") : html;
    },
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        if (!req.url?.startsWith('/api/')) return next();
        res.setHeader('Cache-Control', 'no-store');
        const origin = req.headers.origin;
        if (origin && origin !== `http://${req.headers.host}` && origin !== `https://${req.headers.host}`) { res.statusCode = 403; res.end('Forbidden'); return; }
        try {
          if (req.method === 'GET' && req.url.startsWith('/api/output/')) {
            const id = req.url.split('/').pop()!;
            const file = engine.output(id), result = engine.get(id).result;
            res.setHeader('Content-Type', `image/${result.format}`);
            res.setHeader('Content-Disposition', `attachment; filename="${encodeURIComponent(path.parse(result.name).name)}-clop.${result.format === 'jpeg' ? 'jpg' : result.format}"`);
            res.end(await readFile(file)); return;
          }
          if (req.method === 'GET' && req.url.startsWith('/api/png/')) {
            res.setHeader('Content-Type', 'image/png'); res.end(await sharp(engine.output(req.url.split('/').pop()!)).png().toBuffer()); return;
          }
          if (req.url !== '/api/state') {
            if (req.method !== 'POST' || !String(req.headers['content-type']).startsWith('application/json')) throw new Error('Send an image operation as JSON.');
            let size = 0; const chunks: Buffer[] = [];
            for await (const chunk of req) { size += chunk.length; if (size > 48 * 1024 * 1024) throw new Error('Use an image smaller than 32 MB in the browser preview.'); chunks.push(Buffer.from(chunk)); }
            const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            switch (req.url) {
              case '/api/import':
                if (engine.list().length >= 40) throw new Error('Dismiss some images before adding more.');
                await engine.importBuffer(Buffer.from(body.data, 'base64'), String(body.name), 'drop', { mode: settings.defaultMode, format: settings.defaultFormat, scale: 1 }); break;
              case '/api/apply': await engine.apply(body.id, body.options as ImageOptions); break;
              case '/api/restore': await engine.restore(body.id); break;
              case '/api/dismiss': await engine.dismiss(body.id); break;
              case '/api/settings': settings = parseSettings(body, settings); break;
              default: throw new Error('Unknown image operation.');
            }
          }
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ items: engine.list(), settings, native: false, platform: 'preview' }));
        } catch (error) { res.statusCode = 400; res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ error: message(error) })); }
      });
    },
  };
}
export default defineConfig({ base: './', plugins: [react(), localImagePreview()], server: { host: '127.0.0.1', port: 5274, strictPort: true, allowedHosts: ['outposttwo.tail19dab3.ts.net'] } });
