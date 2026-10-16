#!/usr/bin/env node
// Renderiza AeroGrid-Demo-Opus.html cuadro por cuadro con Chrome headless (CDP, sin dependencias npm).
//   node render.mjs video  <salida.mp4> [desde] [hasta]
//   node render.mjs stills <carpeta> t1 t2 ...
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const HTML = path.join(ROOT, 'AeroGrid-Demo-Opus.html');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const FFMPEG = process.env.FFMPEG || '/opt/homebrew/bin/ffmpeg';
const [mode, target, ...rest] = process.argv.slice(2);
if (!mode || !target) { console.error('uso: node render.mjs video out.mp4 [desde hasta] | stills dir t...'); process.exit(2); }

const sleep = ms => new Promise(r => setTimeout(r, ms));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'aerogrid-demo-chrome-'));
const port = 9400 + Math.floor(Math.random() * 400);
const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1200', '--disable-gpu-vsync', 'about:blank'], { stdio: 'ignore' });
const cleanup = () => { try { chrome.kill('SIGTERM'); } catch {} try { fs.rmSync(profile, { recursive: true, force: true }); } catch {} };
process.on('exit', cleanup);

let page;
for (let i = 0; i < 100 && !page; i++) {
  try { page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === 'page'); } catch {}
  if (!page) await sleep(100);
}
if (!page) throw new Error('Chrome no respondió');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let seq = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); const p = pending.get(m.id); if (p) { pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); } };
const send = (method, params = {}) => new Promise((res, rej) => { const id = ++seq; pending.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async expr => { const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }); if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails)); return r.result.value; };

await send('Page.enable');
await send('Page.navigate', { url: pathToFileURL(HTML).href + '?render=1' });
for (let i = 0; i < 200; i++) { if (await evaluate('window.__ready === true').catch(() => false)) break; await sleep(100); }
const duration = await evaluate('window.DURATION'), fps = await evaluate('window.FPS');
const png = async t => Buffer.from((await evaluate(`window.__frame(${t})`)).split(',')[1], 'base64');

if (mode === 'stills') {
  fs.mkdirSync(target, { recursive: true });
  for (const t of rest.map(Number)) { const f = path.join(target, `t${t.toFixed(2).padStart(6, '0')}.png`); fs.writeFileSync(f, await png(t)); console.log(f); }
} else if (mode === 'video') {
  const from = Number(rest[0] ?? 0), to = Number(rest[1] ?? duration);
  const first = Math.round(from * fps), last = Math.round(to * fps);
  const ff = spawn(FFMPEG, ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-tune', 'animation', '-pix_fmt', 'yuv420p', '-r', String(fps),
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-movflags', '+faststart', '-an', target], { stdio: ['pipe', 'inherit', 'inherit'] });
  const started = Date.now();
  for (let f = first; f < last; f++) {
    const buf = await png(f / fps);
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (f % 150 === 0) console.log(`cuadro ${f}/${last} · ${((Date.now() - started) / 1000).toFixed(0)} s`);
  }
  ff.stdin.end();
  const code = await new Promise(r => ff.on('close', r));
  if (code !== 0) throw new Error('ffmpeg falló: ' + code);
  console.log('listo', target, `${((Date.now() - started) / 1000).toFixed(0)} s`);
}
ws.close(); cleanup(); process.exit(0);
