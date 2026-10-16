'use strict';
// AeroGrid · recreación animada (motion design). Todo es determinístico: frame(t) dibuja el instante t.
// Coordenadas: el lienzo es 1920×1080 px; cada pantalla se dibuja en puntos propios (MacBook 1512×945)
// y una "cámara" la transforma al lienzo.

const W = 1920, H = 1080, FPS = 30, DURATION = 80;
const SW = 1512, SH = 945, MENU = 34;
const UW = 2560, UH = 1080; // monitor externo (ultrawide)
const PINK = '#f0559c', PINKA = a => `rgba(240,85,156,${a})`;
const UI = 'BlinkMacSystemFont, -apple-system, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif';
const MONO = '"SF Mono", Menlo, Monaco, monospace';

// ------------------------------------------------------------------ utilidades
const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const lerp = (a, b, p) => a + (b - a) * p;
const ease = p => p < .5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2;
const easeOut = p => 1 - Math.pow(1 - p, 3);
const easeIn = p => p * p * p;
const backOut = p => { const c1 = 1.5, c3 = c1 + 1; return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2); };
const seg = (t, a, b) => clamp((t - a) / (b - a));
const win = (t, a, b, fi = .25, fo = .25) => Math.min(seg(t, a, a + fi), 1 - seg(t, b - fo, b));
function mix(a, b, p) {
  if (typeof a === 'number') return lerp(a, b, p);
  if (Array.isArray(a)) return a.map((v, i) => mix(v, b[i], p));
  const o = {}; for (const k in a) o[k] = mix(a[k], b[k], p); return o;
}
function track(keys, t, fn = ease) {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 0; i < keys.length - 1; i++) {
    const [t0, v0] = keys[i], [t1, v1] = keys[i + 1];
    if (t <= t1) return mix(v0, v1, fn(clamp((t - t0) / Math.max(1e-6, t1 - t0))));
  }
  return keys[keys.length - 1][1];
}
function rr(ctx, x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, Math.max(0, w), Math.max(0, h), r); }
function fillRR(ctx, x, y, w, h, r, fill) { rr(ctx, x, y, w, h, r); ctx.fillStyle = fill; ctx.fill(); }
function strokeRR(ctx, x, y, w, h, r, stroke, lw = 1) { rr(ctx, x, y, w, h, r); ctx.strokeStyle = stroke; ctx.lineWidth = lw; ctx.stroke(); }
function font(ctx, size, weight = 400, family = UI) { ctx.font = `${weight} ${size}px ${family}`; }
function txt(ctx, s, x, y, o = {}) {
  font(ctx, o.size || 13, o.weight || 400, o.family || UI);
  ctx.fillStyle = o.color || '#fff'; ctx.textAlign = o.align || 'left'; ctx.textBaseline = o.base || 'alphabetic';
  if (o.ls) ctx.letterSpacing = o.ls + 'px';
  let str = s;
  if (o.max && ctx.measureText(str).width > o.max) {
    while (str.length > 1 && ctx.measureText(str + '…').width > o.max) str = str.slice(0, -1);
    str += '…';
  }
  ctx.fillText(str, x, y);
  if (o.ls) ctx.letterSpacing = '0px';
  return ctx.measureText(str).width;
}
function measure(ctx, s, size, weight = 400, family = UI) { font(ctx, size, weight, family); return ctx.measureText(s).width; }
function clip(ctx, x, y, w, h, r = 0) { ctx.save(); rr(ctx, x, y, w, h, r); ctx.clip(); }

// ------------------------------------------------------------------ íconos
const IMG = {};
const ICON_OF = { browser: 'Safari', dash: 'Safari', terminal: 'Terminal', chat: 'Messages', mail: 'Mail', calendar: 'Calendar', notes: 'Notes', music: 'Music', sheet: 'Numbers' };
function makeEditorIcon() {
  const c = document.createElement('canvas'); c.width = c.height = 256; const g = c.getContext('2d');
  const grd = g.createLinearGradient(0, 20, 0, 236); grd.addColorStop(0, '#5b8cff'); grd.addColorStop(1, '#2747c9');
  g.shadowColor = 'rgba(0,0,0,.25)'; g.shadowBlur = 8; g.shadowOffsetY = 3;
  fillRR(g, 26, 22, 204, 204, 46, grd); g.shadowColor = 'transparent';
  fillRR(g, 50, 58, 156, 128, 16, 'rgba(10,18,60,.55)');
  g.strokeStyle = '#fff'; g.lineWidth = 15; g.lineCap = 'round'; g.lineJoin = 'round';
  g.beginPath(); g.moveTo(98, 92); g.lineTo(72, 122); g.lineTo(98, 152); g.stroke();
  g.beginPath(); g.moveTo(158, 92); g.lineTo(184, 122); g.lineTo(158, 152); g.stroke();
  g.strokeStyle = '#ffd66b'; g.beginPath(); g.moveTo(138, 84); g.lineTo(118, 160); g.stroke();
  return c;
}
function loadImages() {
  const ps = [];
  for (const [k, src] of Object.entries(window.ICONS || {})) {
    const im = new Image(); ps.push(new Promise(r => { im.onload = r; im.onerror = r; })); im.src = src; IMG[k] = im;
  }
  IMG.Editor = makeEditorIcon();
  return Promise.all(ps);
}
function icon(ctx, app, cx, cy, size) {
  const im = app === 'editor' ? IMG.Editor : IMG[ICON_OF[app]];
  if (im && (im.width || im.naturalWidth)) ctx.drawImage(im, cx - size / 2, cy - size / 2, size, size);
  else fillRR(ctx, cx - size / 2, cy - size / 2, size, size, size * .22, '#888');
}

// ------------------------------------------------------------------ apps y espacios (contenido ficticio)
const APP = {
  editor: 'Editor', terminal: 'Terminal', browser: 'Navegador', dash: 'Navegador', chat: 'Chat', mail: 'Correo',
  calendar: 'Calendario', notes: 'Notas', music: 'Música', sheet: 'Planilla'
};
const T_D0 = { d: 'h', c: ['editor', 'terminal'], w: [.6, .4] };
const T_D1 = { d: 'h', c: ['editor', { d: 'v', c: ['browser', 'terminal'], w: [1, 1] }], w: [.6, .4] };
const T_DSTACK = { d: 'h', c: ['editor', { d: 'stack', c: ['terminal', 'browser'] }], w: [.6, .4] };
const T_A = { d: 'h', c: ['mail', 'calendar'], w: [1, 1] };
function leaves(tree, out = []) { if (!tree) return out; if (typeof tree === 'string') out.push(tree); else tree.c.forEach(c => leaves(c, out)); return out; }
function title(tree) { return tree ? leaves(tree).map(a => APP[a]).join(' · ') : 'Espacio vacío'; }

// ------------------------------------------------------------------ guion (segundos)
const K = {
  titleOut: 3.4, screenIn: 4.4,
  mapIn: 8.0, mapOut: 11.3,
  flick1: { down: 14.35, lift: 14.8, hudIn: 14.5, commit: 15.0 },
  held: { down: 20.3, hudIn: 20.85, step2: 23.0, lift: 26.75, commit: 27.0 },
  dwell: 34.95, panelIn: 35.6,
  wGrab: 37.85, wDragStart: 38.1, wEdge: 41.2, wDrop: 43.0,
  sGrab: 47.0, sDrop: 50.5, swapEnd: 51.1,
  click: 54.7, panelOut: 54.85, openD: 55.0,
  flick2: { down: 60.55, lift: 60.95, hudIn: 60.7, commit: 61.2 },
  dual: 65.0,
  flick4: { down: 68.15, lift: 68.6, hudIn: 68.35, commit: 68.85 },
  end: 74.0,
};
// qué espacio muestra el MacBook en cada momento
const DESK = [
  [0, { key: 'D', tree: T_D0, focus: 'terminal' }],
  [K.flick1.commit, { key: 'E', tree: 'browser', focus: 'browser' }],
  [K.held.commit, { key: 'C', tree: 'chat', focus: 'chat' }],
  [K.openD, { key: 'D', tree: T_D1, focus: 'editor' }],
  [K.flick2.commit, { key: 'C', tree: 'chat', focus: 'chat' }],
  [K.flick4.commit, { key: 'B', tree: 'notes', focus: 'notes' }],
];
const UWDESK = [[0, { key: 'X2', tree: 'dash', focus: 'dash' }], [K.flick4.commit, { key: 'X1', tree: 'sheet', focus: 'sheet' }]];
function deskAt(list, t) {
  let i = 0; for (let j = 0; j < list.length; j++) if (t >= list[j][0]) i = j;
  const cur = list[i][1], since = t - list[i][0];
  const prev = i > 0 && since < .14 ? list[i - 1][1] : null;
  return { cur, prev, p: prev ? easeOut(since / .14) : 1 };
}
// tablero del MacBook (posición fija por espacio)
function boardAt(t) {
  const sw = ease(seg(t, K.sDrop, K.swapEnd));
  const dropped = t >= K.wDrop;
  return {
    A: { pos: [0, 0], tree: T_A }, B: { pos: [0, 1], tree: 'notes' }, C: { pos: [0, 2], tree: 'chat' },
    D: { pos: [1, lerp(0, 2, sw)], tree: dropped ? T_D1 : T_D0 },
    E: { pos: [1, 1], tree: dropped ? null : 'browser' },
    F: { pos: [1, lerp(2, 0, sw)], tree: 'music' },
  };
}
const UWBOARD = { X1: { pos: [0, 0], tree: 'sheet' }, X2: { pos: [0, 1], tree: 'dash' } };

// ------------------------------------------------------------------ cámara
const CAM = {
  LOW: { s: .86, x: 310, y: 1160 },
  DEVICE: { s: .86, x: 310, y: 58 },
  MAP: { s: .376, x: 50, y: 470 },
  FULL: { s: 1.143, x: 960 - 756 * 1.143, y: 0 },
  ORG: { s: 1.62, x: 960 - 756 * 1.62, y: 0 },
  DUAL: { s: .5, x: 1124, y: 214 },
};
const camKeys = [
  [0, CAM.LOW], [K.titleOut, CAM.LOW], [K.screenIn, CAM.DEVICE],
  [K.mapIn, CAM.DEVICE], [K.mapIn + 1.4, CAM.MAP], [K.mapOut, CAM.MAP], [K.mapOut + 1.3, CAM.FULL],
  [K.dwell - .2, CAM.FULL], [K.panelIn + .7, CAM.ORG], [K.panelOut - .1, CAM.ORG], [K.openD + .8, CAM.FULL],
  [K.dual, CAM.FULL], [K.dual + 1.3, CAM.DUAL],
];
const bezelKeys = [[0, 1], [K.mapIn + .1, 1], [K.mapIn + .9, 0], [K.dual + .2, 0], [K.dual + 1.2, 1]];
const UWCAM = { s: .4, x: 64, y: 236 };

// ------------------------------------------------------------------ gestos (para el panel de trackpad y el HUD)
const GESTURES = [
  { n: 3, down: K.flick1.down, lift: K.flick1.lift, path: [[K.flick1.down, -.28, .05], [K.flick1.down + .12, -.24, .05], [K.flick1.lift - .02, .3, .05]], label: [['deslizá', 0]] },
  { n: 3, down: K.held.down, lift: K.held.lift, path: [[K.held.down, -.36, .28], [K.held.down + .35, -.35, .28], [21.35, .02, .28], [22.35, .02, .28], [23.15, .04, -.28], [K.held.lift, .04, -.28]],
    label: [['mantené apoyado', 0], ['seguí moviendo', 22.35], ['quieto: no cambia nada', 23.3], ['soltá', 26.2]] },
  { n: 3, down: K.flick2.down, lift: K.flick2.lift, path: [[K.flick2.down, 0, .3], [K.flick2.down + .1, 0, .27], [K.flick2.lift - .02, 0, -.3]], label: [['deslizá hacia arriba', 0]] },
  { n: 4, down: K.flick4.down, lift: K.flick4.lift, path: [[K.flick4.down, .3, .05], [K.flick4.down + .1, .27, .05], [K.flick4.lift - .02, -.32, .05]], label: [['4 dedos · deslizá', 0]] },
];
const HUDS = [
  { a: K.flick1.hudIn, b: K.flick1.commit, origin: 'D', sel: [[K.flick1.hudIn, 'E']] },
  { a: K.held.hudIn, b: K.held.commit, origin: 'E', sel: [[K.held.hudIn, 'F'], [K.held.step2, 'C']] },
  { a: K.flick2.hudIn, b: K.flick2.commit, origin: 'D', sel: [[K.flick2.hudIn, 'C']] },
  { a: K.flick4.hudIn, b: K.flick4.commit, origin: 'C', sel: [[K.flick4.hudIn, 'B']], uw: { origin: 'X2', sel: 'X1' } },
];
function hudAt(t) {
  for (const h of HUDS) {
    if (t >= h.a - .01 && t < h.b + .2) {
      let sel = h.sel[0][1], since = t - h.sel[0][0];
      for (const [tt, k] of h.sel) if (t >= tt) { sel = k; since = t - tt; }
      const alpha = Math.min(seg(t, h.a, h.a + .12), 1 - seg(t, h.b, h.b + .18));
      return { ...h, selKey: sel, since, alpha };
    }
  }
  return null;
}

// ------------------------------------------------------------------ puntero (en puntos de la pantalla del MacBook)
const P_REST = [1040, 640];
const pointerKeys = [
  [0, P_REST], [33.4, P_REST], [34.85, [756, 9]], [36.4, [756, 9]], [37.55, [756, 360]], [38.15, [752, 362]],
  [39.35, [588, 360]], [40.95, [588, 360]], [41.45, [588, 324]], [K.wDrop, [588, 324]], [43.6, [610, 345]],
  [46.0, [610, 345]], [46.85, [431, 293]], [47.25, [431, 293]], [47.85, [560, 428]], [48.6, [905, 428]], [49.15, [986, 372]],
  [K.sDrop, [986, 372]], [51.35, [986, 372]], [52.15, [1072, 70]], [53.55, [1072, 70]], [54.45, [944, 360]],
  [56.2, [944, 360]], [57.6, P_REST],
];
function pointerAt(t) { return track(pointerKeys, t); }

// ------------------------------------------------------------------ fondo y fondos de pantalla
let BG, WP, WPUW;
function makeBG() {
  const c = document.createElement('canvas'); c.width = W; c.height = H; const g = c.getContext('2d');
  const lg = g.createLinearGradient(0, 0, 0, H); lg.addColorStop(0, '#0b0b16'); lg.addColorStop(1, '#120f22'); g.fillStyle = lg; g.fillRect(0, 0, W, H);
  let rg = g.createRadialGradient(960, 1150, 50, 960, 1150, 900); rg.addColorStop(0, 'rgba(240,85,156,.16)'); rg.addColorStop(1, 'rgba(240,85,156,0)');
  g.fillStyle = rg; g.fillRect(0, 0, W, H);
  rg = g.createRadialGradient(300, 80, 20, 300, 80, 700); rg.addColorStop(0, 'rgba(90,110,255,.10)'); rg.addColorStop(1, 'rgba(90,110,255,0)');
  g.fillStyle = rg; g.fillRect(0, 0, W, H);
  return c;
}
function makeWallpaper(w, h) {
  const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d');
  const lg = g.createLinearGradient(0, 0, w, h); lg.addColorStop(0, '#1d2259'); lg.addColorStop(.55, '#3a1f5c'); lg.addColorStop(1, '#5e2456'); g.fillStyle = lg; g.fillRect(0, 0, w, h);
  const blobs = [[.18, .2, .5, 'rgba(80,130,255,.55)'], [.82, .78, .6, 'rgba(240,85,156,.42)'], [.6, .05, .4, 'rgba(150,90,240,.45)'], [.35, .95, .45, 'rgba(60,40,140,.6)']];
  for (const [x, y, r, col] of blobs) {
    const rg = g.createRadialGradient(x * w, y * h, 0, x * w, y * h, r * w); rg.addColorStop(0, col); rg.addColorStop(1, 'rgba(0,0,0,0)'); g.fillStyle = rg; g.fillRect(0, 0, w, h);
  }
  return c;
}

// ------------------------------------------------------------------ ventanas
function tileTree(tree, r, gap, out) {
  if (!tree) return out;
  if (typeof tree === 'string') { out.push({ app: tree, r }); return out; }
  if (tree.d === 'stack') { tree.c.forEach(ch => tileTree(ch, r, gap, out)); return out; }
  const v = tree.d === 'v', n = tree.c.length, w = tree.w || tree.c.map(() => 1), tot = w.reduce((a, b) => a + b, 0);
  const len = (v ? r.h : r.w) - gap * (n - 1); let p = v ? r.y : r.x;
  tree.c.forEach((ch, i) => {
    const e = len * w[i] / tot;
    tileTree(ch, v ? { x: r.x, y: p, w: r.w, h: e } : { x: p, y: r.y, w: e, h: r.h }, gap, out); p += e + gap;
  });
  return out;
}
let SHADOW_SCALE = 1;
function windowFrame(ctx, r, bg) {
  ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.45)'; ctx.shadowBlur = 28 * SHADOW_SCALE; ctx.shadowOffsetY = 8 * SHADOW_SCALE;
  fillRR(ctx, r.x, r.y, r.w, r.h, 11, bg); ctx.restore();
}
function lights(ctx, x, y, focused) {
  const cols = focused ? ['#ff5f57', '#febc2e', '#28c840'] : ['#5a5a63', '#5a5a63', '#5a5a63'];
  cols.forEach((c, i) => { ctx.beginPath(); ctx.arc(x + i * 20, y, 6, 0, Math.PI * 2); ctx.fillStyle = c; ctx.fill(); });
}
function drawWindow(ctx, app, r, focused, t) {
  const dark = ['editor', 'terminal', 'music'].includes(app);
  windowFrame(ctx, r, dark ? '#1e1f27' : '#fbfbfd');
  clip(ctx, r.x, r.y, r.w, r.h, 11);
  (APPDRAW[app] || (() => {}))(ctx, r, focused, t);
  ctx.restore();
  strokeRR(ctx, r.x + .5, r.y + .5, r.w - 1, r.h - 1, 11, dark ? 'rgba(255,255,255,.12)' : 'rgba(0,0,0,.18)', 1);
}
function titleBar(ctx, r, focused, label, bg, fg) {
  ctx.fillStyle = bg; ctx.fillRect(r.x, r.y, r.w, 32);
  lights(ctx, r.x + 18, r.y + 16, focused);
  if (label && r.w > 260) txt(ctx, label, r.x + r.w / 2, r.y + 20.5, { size: 13, weight: 600, color: fg, align: 'center', max: r.w - 140 });
}

// --- Editor
const CODE = [
  'import { Carrito } from "./carrito";',
  'import { costoEnvio } from "./envio";',
  '',
  'export function total(carrito: Carrito): number {',
  '  const subtotal = carrito.items.reduce(',
  '    (suma, item) => suma + item.precio * item.cantidad,',
  '    0,',
  '  );',
  '  // Envío gratis desde $50.000',
  '  return subtotal + costoEnvio(subtotal);',
  '}',
  '',
  'export function resumen(carrito: Carrito) {',
  '  return `${carrito.items.length} productos`;',
  '}',
];
const KW = new Set(['import', 'from', 'export', 'function', 'const', 'return', 'let', 'number']);
function tokens(line) {
  const out = []; const re = /(\/\/.*$)|("[^"]*"|`[^`]*`)|([A-Za-z_$][\w$]*)|(\d[\d_.]*)|(\s+)|(.)/g; let m;
  while ((m = re.exec(line))) {
    let c = '#d6deeb';
    if (m[1]) c = '#7f87a8'; else if (m[2]) c = '#c3e88d';
    else if (m[3]) { const after = line.slice(re.lastIndex).trimStart(); c = KW.has(m[3]) ? '#c792ea' : /^[A-Z]/.test(m[3]) ? '#ffcb6b' : after.startsWith('(') ? '#82aaff' : '#d6deeb'; }
    else if (m[4]) c = '#f78c6c'; else if (m[6]) c = '#89ddff';
    out.push([m[0], c]);
  }
  return out;
}
function appEditor(ctx, r, focused, t) {
  ctx.fillStyle = '#1e1f27'; ctx.fillRect(r.x, r.y, r.w, r.h);
  titleBar(ctx, r, focused, 'checkout.ts — tienda', '#17181e', '#c9cbd6');
  const side = r.w > 560 ? Math.min(200, r.w * .25) : 0, top = r.y + 32;
  if (side) {
    ctx.fillStyle = '#18191f'; ctx.fillRect(r.x, top, side, r.h - 32);
    txt(ctx, 'EXPLORADOR', r.x + 16, top + 26, { size: 10.5, weight: 600, color: '#7d8196', ls: 1 });
    const files = [['▾ tienda', 0, 0], ['▾ src', 1, 0], ['carrito.ts', 2, 0], ['checkout.ts', 2, 1], ['envio.ts', 2, 0], ['▾ tests', 1, 0], ['checkout.test.ts', 2, 0], ['package.json', 1, 0]];
    files.forEach(([n, ind, sel], i) => {
      const y = top + 48 + i * 25;
      if (sel) { ctx.fillStyle = 'rgba(120,140,255,.18)'; ctx.fillRect(r.x, y - 16, side, 23); }
      txt(ctx, n, r.x + 16 + ind * 14, y, { size: 12.5, color: sel ? '#fff' : '#aeb2c4', max: side - 20 - ind * 14 });
    });
  }
  const cx = r.x + side;
  ctx.fillStyle = '#18191f'; ctx.fillRect(cx, top, r.w - side, 32);
  ctx.fillStyle = '#1e1f27'; ctx.fillRect(cx, top, 132, 32); ctx.fillStyle = '#6f8cff'; ctx.fillRect(cx, top, 132, 2);
  txt(ctx, 'checkout.ts', cx + 16, top + 21, { size: 12.5, color: '#e6e8f0' });
  txt(ctx, 'envio.ts', cx + 150, top + 21, { size: 12.5, color: '#6f7387' });
  const lh = 22, y0 = top + 32 + 26;
  CODE.forEach((line, i) => {
    const y = y0 + i * lh;
    if (i === 9) { ctx.fillStyle = 'rgba(255,255,255,.045)'; ctx.fillRect(cx, y - 16, r.w - side, lh); }
    txt(ctx, String(i + 1), cx + 34, y, { size: 12.5, family: MONO, color: i === 9 ? '#c9cbd6' : '#555a6e', align: 'right' });
    let x = cx + 50; font(ctx, 13.5, 400, MONO);
    for (const [s, c] of tokens(line)) { ctx.fillStyle = c; ctx.textAlign = 'left'; ctx.fillText(s, x, y); x += ctx.measureText(s).width; }
    if (i === 9 && focused && Math.floor(t * 1.6) % 2 === 0) { ctx.fillStyle = '#c9cbd6'; ctx.fillRect(x + 1, y - 14, 2, 18); }
  });
  ctx.fillStyle = '#2b3bb5'; ctx.fillRect(r.x, r.y + r.h - 24, r.w, 24);
  txt(ctx, '⎇ main    ✓ 0 problemas', r.x + 14, r.y + r.h - 8, { size: 11.5, color: '#e9ecff' });
  if (r.w > 420) txt(ctx, 'TypeScript   Ln 10, Col 41', r.x + r.w - 14, r.y + r.h - 8, { size: 11.5, color: '#e9ecff', align: 'right' });
}
// --- Terminal
const TERM_OUT = [
  ['', ''], ['> tienda@1.4.0 test', '#8b8f9c'], ['> vitest run', '#8b8f9c'], ['', ''],
  [' ✓ tests/checkout.test.ts (3)', '#7ee787'], ['   ✓ suma los productos del carrito', '#c9d1d9'], ['   ✓ envío gratis desde $50.000', '#c9d1d9'], ['   ✓ cobra envío en compras chicas', '#c9d1d9'], ['', ''],
  [' Test Files  1 passed (1)', '#7ee787'], ['      Tests  3 passed (3)', '#7ee787'], ['   Duration  412ms', '#8b8f9c'], ['', ''],
];
function appTerminal(ctx, r, focused, t) {
  ctx.fillStyle = '#121317'; ctx.fillRect(r.x, r.y, r.w, r.h);
  titleBar(ctx, r, focused, 'tienda — zsh', '#26272d', '#b9bcc8');
  const typeStart = 5.3, cmd = 'npm test';
  const typed = t < 12 ? cmd.slice(0, clamp(Math.floor((t - typeStart) / .085), 0, cmd.length)) : cmd;
  const outN = t < 12 ? clamp(Math.floor((t - 6.35) / .06), 0, TERM_OUT.length) : TERM_OUT.length;
  const lines = [[['~/tienda', '#7ee787'], [' $ ', '#c9d1d9'], [typed, '#fff']]];
  for (let i = 0; i < outN; i++) lines.push([[TERM_OUT[i][0], TERM_OUT[i][1]]]);
  if (outN >= TERM_OUT.length) lines.push([['~/tienda', '#7ee787'], [' $ ', '#c9d1d9']]);
  const lh = 21, y0 = r.y + 32 + 28;
  lines.forEach((parts, i) => {
    let x = r.x + 16; font(ctx, 13.5, 400, MONO);
    for (const [s, c] of parts) { ctx.fillStyle = c; ctx.textAlign = 'left'; ctx.fillText(s, x, y0 + i * lh); x += ctx.measureText(s).width; }
    if (i === lines.length - 1 && focused && (Math.floor(t * 1.6) % 2 === 0 || (t > typeStart && t < 6.4))) { ctx.fillStyle = '#d0d0d0'; ctx.fillRect(x + 1, y0 + i * lh - 14, 8, 17); }
  });
}
// --- Navegador (documentación)
function browserChrome(ctx, r, focused, url) {
  ctx.fillStyle = '#efeef3'; ctx.fillRect(r.x, r.y, r.w, 46);
  ctx.fillStyle = 'rgba(0,0,0,.1)'; ctx.fillRect(r.x, r.y + 46, r.w, 1);
  lights(ctx, r.x + 20, r.y + 23, focused);
  if (r.w > 330) txt(ctx, '‹   ›', r.x + 92, r.y + 29, { size: 18, color: '#8a8a93' });
  const pw = Math.min(440, r.w - 230); if (pw > 90) {
    const px = r.x + (r.w - pw) / 2 + 40;
    fillRR(ctx, px, r.y + 10, pw, 27, 8, '#e1e0e6');
    txt(ctx, '🔒︎ ' + url, px + pw / 2, r.y + 28, { size: 12.5, color: '#4a4a52', align: 'center', max: pw - 20 });
  }
}
function appBrowser(ctx, r, focused) {
  ctx.fillStyle = '#ffffff'; ctx.fillRect(r.x, r.y, r.w, r.h);
  browserChrome(ctx, r, focused, 'docs.ejemplo.dev/envios');
  const top = r.y + 47, nav = r.w > 640 ? 190 : 0;
  if (nav) {
    ctx.fillStyle = '#f6f6f9'; ctx.fillRect(r.x, top, nav, r.h - 47);
    txt(ctx, 'Documentación', r.x + 20, top + 34, { size: 12, weight: 700, color: '#1d1d1f' });
    ['Primeros pasos', 'Carrito', 'Pagos', 'Envíos', 'Webhooks', 'Errores'].forEach((s, i) => {
      const y = top + 66 + i * 30;
      if (s === 'Envíos') fillRR(ctx, r.x + 10, y - 19, nav - 20, 27, 6, 'rgba(240,85,156,.13)');
      txt(ctx, s, r.x + 22, y, { size: 13, weight: s === 'Envíos' ? 600 : 400, color: s === 'Envíos' ? '#c2185b' : '#55555f' });
    });
  }
  const x = r.x + nav + Math.min(48, r.w * .06), mw = Math.min(620, r.x + r.w - x - 30);
  let y = top + Math.min(58, r.h * .09);
  txt(ctx, 'Costos de envío', x, y, { size: Math.min(28, r.w / 16), weight: 700, color: '#1d1d1f' }); y += 34;
  ['Calculá el envío según el subtotal del carrito.', 'Las compras desde $50.000 no pagan envío.'].forEach(s => { txt(ctx, s, x, y, { size: 14.5, color: '#4b4b55', max: mw }); y += 23; });
  y += 14;
  const rows = [['Subtotal', 'Envío'], ['Menos de $50.000', '$2.500'], ['Desde $50.000', 'Gratis']];
  rows.forEach((row, i) => {
    if (i === 0) { ctx.fillStyle = '#f3f3f7'; ctx.fillRect(x, y - 19, mw, 30); }
    txt(ctx, row[0], x + 14, y, { size: 13.5, weight: i ? 400 : 600, color: '#2c2c33', max: mw * .6 });
    txt(ctx, row[1], x + mw * .62, y, { size: 13.5, weight: i ? (row[1] === 'Gratis' ? 700 : 400) : 600, color: row[1] === 'Gratis' ? '#1a8f4a' : '#2c2c33' });
    ctx.fillStyle = 'rgba(0,0,0,.08)'; ctx.fillRect(x, y + 11, mw, 1); y += 32;
  });
  y += 16;
  fillRR(ctx, x, y - 4, mw, 64, 8, '#f4f4f8');
  txt(ctx, 'costoEnvio(32000)  // → 2500', x + 16, y + 22, { size: 13, family: MONO, color: '#3b3b6b', max: mw - 30 });
  txt(ctx, 'costoEnvio(64000)  // → 0', x + 16, y + 44, { size: 13, family: MONO, color: '#3b3b6b', max: mw - 30 });
  y += 96;
  for (let i = 0; i < 6; i++) { ctx.fillStyle = '#ececf1'; ctx.fillRect(x, y + i * 22, mw * (i % 3 === 2 ? .55 : .92), 9); }
}
// --- Chat
function chatState(t) {
  const msg = 'Listo: tests en verde. Lo subo en 5 min.';
  if (t < 29.0) return { typing: '', sent: false, reply: 0 };
  if (t < 31.15) return { typing: msg.slice(0, Math.floor((t - 29.0) / 2.0 * msg.length)), sent: false, reply: 0 };
  return { typing: '', sent: true, reply: t < 31.9 ? 0 : t < 32.75 ? 1 : 2, msg };
}
function bubble(ctx, s, x, y, maxW, mine, name) {
  font(ctx, 14.5); const w = Math.min(maxW, ctx.measureText(s).width + 28), h = 34;
  const bx = mine ? x - w : x;
  if (name) txt(ctx, name, bx + 12, y - 6, { size: 11.5, color: '#86868e' });
  fillRR(ctx, bx, y, w, h, 17, mine ? '#0a84ff' : '#e9e9ed');
  txt(ctx, s, bx + 14, y + 22, { size: 14.5, color: mine ? '#fff' : '#1d1d1f', max: w - 26 });
  return h;
}
function appChat(ctx, r, focused, t) {
  const st = chatState(t);
  ctx.fillStyle = '#ffffff'; ctx.fillRect(r.x, r.y, r.w, r.h);
  const side = r.w > 600 ? 250 : 0;
  if (side) {
    ctx.fillStyle = '#f1f0f5'; ctx.fillRect(r.x, r.y, side, r.h);
    lights(ctx, r.x + 20, r.y + 23, focused);
    fillRR(ctx, r.x + 14, r.y + 48, side - 28, 28, 8, '#e3e2e8'); txt(ctx, '⌕  Buscar', r.x + 26, r.y + 67, { size: 13, color: '#8a8a92' });
    const conv = [['Equipo tienda', st.sent ? 'Vos: Listo: tests en verde…' : 'Martín: Si sale hoy, lo anunc…', '#f0559c', 'ET'], ['Lucía Paz', 'Te paso el banner nuevo', '#7a5cff', 'LP'], ['Martín Gómez', '¿Mañana a las 10?', '#20a37c', 'MG'], ['Diseño', 'Sofía: Subí las variantes', '#f59e0b', 'D']];
    conv.forEach(([n, p, c, ini], i) => {
      const y = r.y + 92 + i * 64;
      if (i === 0) fillRR(ctx, r.x + 8, y, side - 16, 58, 10, '#0a84ff');
      ctx.beginPath(); ctx.arc(r.x + 38, y + 29, 19, 0, Math.PI * 2); ctx.fillStyle = c; ctx.fill();
      txt(ctx, ini, r.x + 38, y + 34, { size: 13, weight: 700, color: '#fff', align: 'center' });
      txt(ctx, n, r.x + 66, y + 24, { size: 14, weight: 600, color: i === 0 ? '#fff' : '#1d1d1f', max: side - 80 });
      txt(ctx, p, r.x + 66, y + 43, { size: 12.5, color: i === 0 ? 'rgba(255,255,255,.85)' : '#86868e', max: side - 80 });
    });
  } else lights(ctx, r.x + 20, r.y + 23, focused);
  const mx = r.x + side, mw = r.w - side;
  ctx.fillStyle = 'rgba(0,0,0,.08)'; ctx.fillRect(mx, r.y + 58, mw, 1);
  txt(ctx, 'Equipo tienda', mx + mw / 2, r.y + 28, { size: 14, weight: 700, color: '#1d1d1f', align: 'center' });
  txt(ctx, 'Lucía, Martín y vos', mx + mw / 2, r.y + 46, { size: 11.5, color: '#86868e', align: 'center' });
  const pad = Math.min(40, mw * .06), bw = mw * .72;
  let y = r.y + 96;
  txt(ctx, 'Hoy 10:31', mx + mw / 2, y - 14, { size: 11.5, color: '#9a9aa2', align: 'center' });
  y += 16;
  y += bubble(ctx, '¿Cómo viene el envío gratis desde $50.000?', mx + pad, y, bw, false, 'Lucía') + 30;
  y += bubble(ctx, 'Si sale hoy, lo anunciamos a la tarde.', mx + pad, y, bw, false, 'Martín') + 16;
  if (st.sent) { const p = easeOut(seg(t, 31.15, 31.4)); ctx.save(); ctx.globalAlpha = p; ctx.translate(0, (1 - p) * 14); y += bubble(ctx, st.msg, mx + mw - pad, y, bw, true) + 30; ctx.restore(); }
  if (st.reply === 1) { fillRR(ctx, mx + pad, y, 62, 34, 17, '#e9e9ed'); for (let i = 0; i < 3; i++) { ctx.beginPath(); ctx.arc(mx + pad + 18 + i * 13, y + 17, 4, 0, 7); ctx.fillStyle = `rgba(90,90,100,${.35 + .5 * ((Math.floor(t * 6) + i) % 3 === 0)})`; ctx.fill(); } }
  if (st.reply === 2) bubble(ctx, '¡Genial, gracias! Lo anuncio a las 17.', mx + pad, y, bw, false, 'Lucía');
  // campo de texto
  const iy = r.y + r.h - 50; fillRR(ctx, mx + 16, iy, mw - 32, 34, 17, '#fff'); strokeRR(ctx, mx + 16, iy, mw - 32, 34, 17, 'rgba(0,0,0,.16)');
  if (st.typing) { const w = txt(ctx, st.typing, mx + 32, iy + 22, { size: 14.5, color: '#1d1d1f', max: mw - 70 }); if (Math.floor(t * 3) % 2 === 0) { ctx.fillStyle = '#0a84ff'; ctx.fillRect(mx + 33 + w, iy + 8, 2, 19); } }
  else txt(ctx, 'Mensaje', mx + 32, iy + 22, { size: 14.5, color: '#a0a0a8' });
}
// --- Correo
function appMail(ctx, r, focused) {
  ctx.fillStyle = '#fff'; ctx.fillRect(r.x, r.y, r.w, r.h);
  const side = r.w > 700 ? 170 : 0, list = Math.min(300, r.w * .45);
  if (side) { ctx.fillStyle = '#f1f0f5'; ctx.fillRect(r.x, r.y, side, r.h); ['Entrada  3', 'Destacados', 'Enviados', 'Archivo'].forEach((s, i) => { if (!i) fillRR(ctx, r.x + 8, r.y + 60 + i * 30 - 19, side - 16, 27, 6, '#dcdbe3'); txt(ctx, s, r.x + 20, r.y + 60 + i * 30, { size: 13, color: '#2c2c33', weight: i ? 400 : 600 }); }); }
  lights(ctx, r.x + 20, r.y + 23, focused);
  const lx = r.x + side; ctx.fillStyle = 'rgba(0,0,0,.08)'; ctx.fillRect(lx + list, r.y, 1, r.h);
  txt(ctx, 'Entrada', lx + 18, r.y + 72, { size: 20, weight: 700, color: '#1d1d1f' });
  const mails = [['Logística Sur', 'Nuevas tarifas de envío', 'Desde noviembre cambian…', '10:12'], ['Lucía Paz', 'Banner de octubre', 'Te dejo las dos versiones…', '9:40'], ['Martín Gómez', 'Reunión del lunes', '¿Movemos la daily a las…', 'Ayer'], ['Tienda · Ventas', 'Resumen semanal', 'Las ventas subieron 12%…', 'Ayer']];
  mails.forEach(([f, s, p, h], i) => {
    const y = r.y + 96 + i * 78;
    if (!i) fillRR(ctx, lx + 8, y, list - 16, 72, 8, '#0a84ff');
    const c = i ? '#1d1d1f' : '#fff', c2 = i ? '#86868e' : 'rgba(255,255,255,.85)';
    txt(ctx, f, lx + 20, y + 22, { size: 13.5, weight: 700, color: c, max: list - 90 }); txt(ctx, h, lx + list - 20, y + 22, { size: 11.5, color: c2, align: 'right' });
    txt(ctx, s, lx + 20, y + 42, { size: 13, color: c, max: list - 40 }); txt(ctx, p, lx + 20, y + 60, { size: 12.5, color: c2, max: list - 40 });
  });
  const mx = lx + list + 28, mw = r.x + r.w - mx - 28;
  if (mw > 120) {
    txt(ctx, 'Nuevas tarifas de envío', mx, r.y + 78, { size: 19, weight: 700, color: '#1d1d1f', max: mw });
    txt(ctx, 'Logística Sur · para vos', mx, r.y + 102, { size: 12.5, color: '#86868e', max: mw });
    for (let i = 0; i < 9; i++) { ctx.fillStyle = '#ececf1'; ctx.fillRect(mx, r.y + 134 + i * 22, mw * (i % 4 === 3 ? .5 : .95), 9); }
  }
}
// --- Calendario
function appCalendar(ctx, r, focused) {
  ctx.fillStyle = '#fff'; ctx.fillRect(r.x, r.y, r.w, r.h);
  lights(ctx, r.x + 20, r.y + 23, focused);
  txt(ctx, 'Octubre 2026', r.x + 22, r.y + 72, { size: 21, weight: 700, color: '#1d1d1f' });
  const gx = r.x + 52, gy = r.y + 120, gw = r.w - 70, days = ['Lun 12', 'Mar 13', 'Mié 14', 'Jue 15', 'Vie 16'], cw = gw / 5, hh = Math.max(34, (r.h - 140) / 9);
  days.forEach((d, i) => {
    const today = i === 4;
    if (today) fillRR(ctx, gx + i * cw + cw / 2 - 34, gy - 32, 68, 24, 12, '#ff3b30');
    txt(ctx, d, gx + i * cw + cw / 2, gy - 15, { size: 12.5, weight: 600, color: today ? '#fff' : '#55555f', align: 'center' });
  });
  for (let h = 0; h < 9; h++) { ctx.fillStyle = 'rgba(0,0,0,.07)'; ctx.fillRect(gx, gy + h * hh, gw, 1); txt(ctx, `${9 + h}`, gx - 10, gy + h * hh + 4, { size: 10.5, color: '#9a9aa2', align: 'right' }); }
  const ev = [[0, .5, 1, 'Daily', '#5e8cff'], [1, 2, 1.5, 'Revisión de diseño', '#f0559c'], [2, .5, 1, 'Daily', '#5e8cff'], [3, 4, 2, 'Pruebas tienda', '#20a37c'], [4, .5, 1, 'Daily', '#5e8cff'], [4, 3, 1.2, 'Publicar envío gratis', '#f59e0b'], [0, 4.5, 1, 'Almuerzo', '#a78bfa']];
  for (const [d, s, len, n, c] of ev) {
    const x = gx + d * cw + 4, y = gy + s * hh + 2, w = cw - 8, h = len * hh - 4;
    fillRR(ctx, x, y, w, h, 6, c + '33'); ctx.fillStyle = c; ctx.fillRect(x, y + 3, 3, h - 6);
    txt(ctx, n, x + 10, y + 17, { size: 11.5, weight: 600, color: '#2c2c33', max: w - 14 });
  }
}
// --- Notas
function appNotes(ctx, r, focused) {
  ctx.fillStyle = '#fffdf6'; ctx.fillRect(r.x, r.y, r.w, r.h);
  const side = r.w > 600 ? 260 : 0;
  if (side) {
    ctx.fillStyle = '#f5f2ea'; ctx.fillRect(r.x, r.y, side, r.h);
    [['Ideas para la home', '10:20 · Banner envío gratis'], ['Lanzamiento', 'Ayer · Checklist'], ['Lista de compras', 'Ayer · Café, yerba'], ['Reunión lunes', '12/10 · Temas']].forEach(([a, b], i) => {
      const y = r.y + 70 + i * 62; if (!i) fillRR(ctx, r.x + 10, y - 22, side - 20, 54, 8, '#f9df6f');
      txt(ctx, a, r.x + 24, y, { size: 14, weight: 700, color: '#1d1d1f', max: side - 40 }); txt(ctx, b, r.x + 24, y + 20, { size: 12, color: '#77736a', max: side - 40 });
    });
  }
  lights(ctx, r.x + 20, r.y + 23, focused);
  const x = r.x + side + 40;
  txt(ctx, 'Ideas para la home', x, r.y + 92, { size: 26, weight: 700, color: '#1d1d1f' });
  ['Banner «envío gratis desde $50.000»', 'Sección de ofertas de la semana', 'Reseñas de clientes', 'Mejorar fotos de producto'].forEach((s, i) => {
    txt(ctx, '•  ' + s, x, r.y + 136 + i * 30, { size: 15, color: '#3a3a40', max: r.x + r.w - x - 20 });
  });
}
// --- Música
function appMusic(ctx, r, focused) {
  ctx.fillStyle = '#1c1c21'; ctx.fillRect(r.x, r.y, r.w, r.h);
  const side = r.w > 600 ? 210 : 0;
  if (side) { ctx.fillStyle = '#232329'; ctx.fillRect(r.x, r.y, side, r.h); ['Escuchar ahora', 'Explorar', 'Radio', 'Biblioteca', 'Listas'].forEach((s, i) => txt(ctx, s, r.x + 22, r.y + 74 + i * 30, { size: 13.5, color: i ? '#c5c5cf' : '#ff4f6d', weight: i ? 400 : 600 })); }
  lights(ctx, r.x + 20, r.y + 23, focused);
  const x = r.x + side + 34;
  txt(ctx, 'Para concentrarte', x, r.y + 84, { size: 24, weight: 700, color: '#fff' });
  const cols = [['#ff7a59', '#b4235a'], ['#5b8cff', '#2a1b8f'], ['#20c997', '#0b5a6b'], ['#f6c94b', '#e05b2d']], names = ['Lo-fi tranquilo', 'Piano y lluvia', 'Ambient', 'Foco total'];
  const size = Math.min(170, (r.x + r.w - x - 30) / 4 - 18);
  cols.forEach(([a, b], i) => {
    const cx = x + i * (size + 18), cy = r.y + 110; const g = ctx.createLinearGradient(cx, cy, cx + size, cy + size); g.addColorStop(0, a); g.addColorStop(1, b);
    fillRR(ctx, cx, cy, size, size, 10, g); txt(ctx, names[i], cx, cy + size + 22, { size: 13, weight: 600, color: '#eee', max: size });
  });
  const py = r.y + r.h - 64; ctx.fillStyle = '#26262d'; ctx.fillRect(r.x + side, py, r.w - side, 64);
  txt(ctx, 'Lo-fi tranquilo — Varios artistas', r.x + side + 24, py + 38, { size: 13.5, color: '#eee', max: r.w - side - 60 });
}
// --- Planilla
function appSheet(ctx, r, focused) {
  ctx.fillStyle = '#fff'; ctx.fillRect(r.x, r.y, r.w, r.h);
  titleBar(ctx, r, focused, 'Ventas octubre', '#f3f3f6', '#33333a');
  const x0 = r.x + 30, y0 = r.y + 70, cw = [210, 120, 130, 150], rows = [['Producto', 'Unidades', 'Precio', 'Total'], ['Yerba 1 kg', '212', '$4.900', '$1.038.800'], ['Mate de calabaza', '64', '$12.500', '$800.000'], ['Bombilla acero', '131', '$3.200', '$419.200'], ['Termo 1 l', '38', '$29.900', '$1.136.200'], ['Alfajores x12', '95', '$8.400', '$798.000'], ['Total', '', '', '$4.192.200']];
  rows.forEach((row, i) => {
    let x = x0; const y = y0 + i * 36;
    if (i === 0) { ctx.fillStyle = '#eef3ee'; ctx.fillRect(x0, y, cw.reduce((a, b) => a + b), 36); }
    row.forEach((c, j) => { txt(ctx, c, j ? x + cw[j] - 14 : x + 12, y + 23, { size: 13.5, weight: i === 0 || i === rows.length - 1 ? 700 : 400, color: '#2c2c33', align: j ? 'right' : 'left' }); x += cw[j]; });
    ctx.fillStyle = 'rgba(0,0,0,.09)'; ctx.fillRect(x0, y + 36, cw.reduce((a, b) => a + b), 1);
  });
  const bx = x0 + 660, by = y0 + 240, vals = [.55, .42, .22, .6, .41];
  if (r.x + r.w - bx > 300) vals.forEach((v, i) => { fillRR(ctx, bx + i * 58, by - v * 220, 38, v * 220, 5, i === 3 ? PINK : '#4cc38a'); });
}
// --- Navegador (panel de ventas)
function appDash(ctx, r, focused) {
  ctx.fillStyle = '#f7f7fa'; ctx.fillRect(r.x, r.y, r.w, r.h);
  browserChrome(ctx, r, focused, 'panel.ejemplo.dev/ventas');
  const x = r.x + 40; txt(ctx, 'Ventas · octubre', x, r.y + 100, { size: 26, weight: 700, color: '#1d1d1f' });
  [['Ventas hoy', '$ 1.284.300'], ['Pedidos', '312'], ['Ticket medio', '$ 4.116'], ['Envíos gratis', '41%']].forEach(([a, b], i) => {
    const cx = x + i * 290; fillRR(ctx, cx, r.y + 128, 270, 110, 12, '#fff'); strokeRR(ctx, cx, r.y + 128, 270, 110, 12, 'rgba(0,0,0,.08)');
    txt(ctx, a, cx + 20, r.y + 162, { size: 14, color: '#86868e' }); txt(ctx, b, cx + 20, r.y + 206, { size: 30, weight: 700, color: '#1d1d1f' });
  });
  const gx = x, gy = r.y + 270, gw = Math.min(r.w - 80, 1600), gh = r.h - 330;
  fillRR(ctx, gx, gy, gw, gh, 12, '#fff');
  ctx.beginPath(); for (let i = 0; i <= 30; i++) { const px = gx + 20 + i * (gw - 40) / 30, py = gy + gh - 30 - (Math.sin(i * .5) * .18 + i / 30 * .55 + .1) * (gh - 60); i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
  ctx.strokeStyle = PINK; ctx.lineWidth = 4; ctx.stroke();
}
const APPDRAW = { editor: appEditor, terminal: appTerminal, browser: appBrowser, chat: appChat, mail: appMail, calendar: appCalendar, notes: appNotes, music: appMusic, sheet: appSheet, dash: appDash };

// ------------------------------------------------------------------ pantallas
function menuBar(ctx, w, appName, notch) {
  ctx.fillStyle = 'rgba(16,14,30,.42)'; ctx.fillRect(0, 0, w, MENU);
  let x = 22; x += txt(ctx, appName, x, 22, { size: 14, weight: 700, color: '#fff' }) + 22;
  for (const m of ['Archivo', 'Edición', 'Ver', 'Ventana', 'Ayuda']) x += txt(ctx, m, x, 22, { size: 14, color: 'rgba(255,255,255,.92)' }) + 20;
  let rx = w - 18;
  rx -= txt(ctx, 'Vie 16 oct  10:42', rx, 22, { size: 14, color: '#fff', align: 'right' }) + 22;
  strokeRR(ctx, rx - 26, 11, 24, 12, 3, 'rgba(255,255,255,.9)', 1.3); fillRR(ctx, rx - 24, 13, 15, 8, 1.5, '#fff'); rx -= 46;
  ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.8; for (let i = 0; i < 3; i++) { ctx.beginPath(); ctx.arc(rx, 24, 4 + i * 4.5, -Math.PI * .78, -Math.PI * .22); ctx.stroke(); } rx -= 34;
  // ícono de AeroGrid
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) fillRR(ctx, rx - 14 + j * 5.5, 10 + i * 5.5, 4, 4, 1, '#fff');
  if (notch) { fillRR(ctx, w / 2 - 98, -12, 196, 12 + MENU, 12, '#000'); }
}
function drawDesk(ctx, d, t, opts = {}) {
  const sw = opts.uw ? UW : SW, sh = opts.uw ? UH : SH;
  ctx.drawImage(opts.uw ? WPUW : WP, 0, 0, sw, sh);
  if (d.tree) {
    const wins = tileTree(d.tree, { x: 10, y: MENU + 10, w: sw - 20, h: sh - MENU - 20 }, 10, []);
    for (const w of wins) drawWindow(ctx, w.app, w.r, w.app === d.focus, t);
  }
  menuBar(ctx, sw, APP[d.focus] || 'Finder', !opts.uw);
}
function drawDeskBlend(ctx, list, t, opts) {
  const st = deskAt(list, t);
  if (st.prev) { drawDesk(ctx, st.prev, t, opts); ctx.save(); ctx.globalAlpha = st.p; drawDesk(ctx, st.cur, t, opts); ctx.restore(); }
  else drawDesk(ctx, st.cur, t, opts);
}

// ------------------------------------------------------------------ panel de AeroGrid (mismo dibujo para el mapa del gesto y el organizador)
const UNIT = { w: 230, h: 152 }, TW = 220, TH = 142;
function drawMini(ctx, tree, r, o = {}) {
  if (!tree) { txt(ctx, 'Arrastrá una app acá', r.x + r.w / 2, r.y + r.h / 2 + 4, { size: 10.5, color: 'rgba(235,235,245,.55)', align: 'center' }); return; }
  if (typeof tree === 'string') {
    const dim = o.dim === tree;
    ctx.save(); if (dim) ctx.globalAlpha *= .45;
    fillRR(ctx, r.x, r.y, r.w, r.h, 5, o.hot === tree ? PINKA(.32) : PINKA(.11));
    if (o.hot === tree) strokeRR(ctx, r.x + .5, r.y + .5, r.w - 1, r.h - 1, 5, PINKA(.9), 1.5);
    const s = Math.min(28, Math.max(12, r.w - 8), Math.max(12, r.h - 8)), label = r.w > 62 && r.h > 53;
    const cy = label ? r.y + r.h / 2 - 7 : r.y + r.h / 2;
    icon(ctx, tree, r.x + r.w / 2, cy, s);
    if (label) txt(ctx, APP[tree], r.x + r.w / 2, cy + s / 2 + 13, { size: 10, color: 'rgba(245,245,250,.92)', align: 'center', max: r.w - 6 });
    ctx.restore(); return;
  }
  if (tree.d === 'stack') {
    fillRR(ctx, r.x, r.y, r.w, r.h, 5, 'rgba(255,255,255,.07)');
    const n = tree.c.length; strokeRR(ctx, r.x + r.w / 2 - 15, r.y + 5, 9, 7, 1.5, 'rgba(235,235,245,.6)', 1); strokeRR(ctx, r.x + r.w / 2 - 12, r.y + 3, 9, 7, 1.5, 'rgba(235,235,245,.6)', 1);
    txt(ctx, String(n), r.x + r.w / 2 + 2, r.y + 13, { size: 10, color: 'rgba(235,235,245,.7)' });
    const mw = Math.max(30, Math.min(55, r.w / 2)), mh = Math.max(24, r.h - 27);
    tree.c.forEach((ch, i) => drawMini(ctx, ch, { x: r.x + 3 + i * (mw + 4), y: r.y + 20, w: mw, h: mh }, o));
    return;
  }
  const v = tree.d === 'v', n = tree.c.length, w = tree.w || tree.c.map(() => 1), tot = w.reduce((a, b) => a + b, 0);
  const len = (v ? r.h : r.w) - 3 * (n - 1); let p = v ? r.y : r.x;
  tree.c.forEach((ch, i) => { const e = len * w[i] / tot; drawMini(ctx, ch, v ? { x: r.x, y: p, w: r.w, h: e } : { x: p, y: r.y, w: e, h: r.h }, o); p += e + 3; });
}
function grip(ctx, x, y) { for (let i = 0; i < 3; i++) for (let j = 0; j < 2; j++) { ctx.beginPath(); ctx.arc(x + j * 5, y + i * 5, 1.5, 0, 7); ctx.fillStyle = 'rgba(235,235,245,.55)'; ctx.fill(); } }
function brackets(ctx, x, y, w, h) {
  ctx.strokeStyle = 'rgba(200,200,215,.45)'; ctx.lineWidth = 2; const L = 9, o = 2;
  for (const [cx, cy, sx, sy] of [[x - o, y - o, 1, 1], [x + w + o, y - o, -1, 1], [x - o, y + h + o, 1, -1], [x + w + o, y + h + o, -1, -1]]) {
    ctx.beginPath(); ctx.moveTo(cx + sx * L, cy); ctx.lineTo(cx, cy); ctx.lineTo(cx, cy + sy * L); ctx.stroke();
  }
}
function capsule(ctx, s, cx, cy, size = 11) {
  const w = measure(ctx, s, size, 500) + 18, h = size + 13;
  fillRR(ctx, cx - w / 2, cy - h / 2, w, h, h / 2, 'rgba(72,68,86,.96)'); strokeRR(ctx, cx - w / 2, cy - h / 2, w, h, h / 2, 'rgba(255,255,255,.12)');
  txt(ctx, s, cx, cy + size * .36, { size, weight: 500, color: '#fff', align: 'center' });
}
function drawTile(ctx, x, y, sp, o = {}) {
  ctx.save(); if (o.alpha != null) ctx.globalAlpha *= o.alpha;
  if (o.opaque) fillRR(ctx, x, y, TW, TH, 10, '#2c2a37');
  fillRR(ctx, x, y, TW, TH, 10, o.chosen ? PINKA(.16) : 'rgba(44,42,56,.62)');
  strokeRR(ctx, x + .5, y + .5, TW - 1, TH - 1, 10, o.chosen ? PINK : o.origin ? 'rgba(200,200,215,.7)' : 'rgba(200,200,215,.2)', o.chosen ? 2 : 1);
  let hx = x + 8; const hy = y + 8 + 19;
  if (o.editable) { grip(ctx, hx + 2, hy - 5); hx += 18; }
  if (o.origin) { ctx.beginPath(); ctx.arc(hx + 4, hy, 4.5, 0, 7); ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.3; ctx.stroke(); ctx.beginPath(); ctx.arc(hx + 4, hy, 2.4, 0, 7); ctx.fillStyle = '#fff'; ctx.fill(); hx += 13; }
  if (o.badge) hx += txt(ctx, o.badge, hx, hy + 4.5, { size: 12, weight: 700, color: PINK }) + 4;
  txt(ctx, title(sp.tree), hx, hy + 4.5, { size: 13, weight: 500, color: 'rgba(250,250,252,.95)', max: x + TW - hx - (o.editable ? 34 : 10) });
  if (o.editable) for (let i = 0; i < 3; i++) { ctx.beginPath(); ctx.arc(x + TW - 26 + i * 5, hy, 1.6, 0, 7); ctx.fillStyle = 'rgba(235,235,245,.8)'; ctx.fill(); }
  const mr = { x: x + 8, y: y + 51, w: TW - 16, h: TH - 59 };
  drawMini(ctx, sp.tree, mr, { dim: o.dimApp, hot: o.hotApp });
  if (o.preview) {
    fillRR(ctx, mr.x, mr.y, mr.w, mr.h, 5, 'rgba(58,55,70,.97)');
    drawMini(ctx, o.preview.tree, mr, { hot: o.preview.hot });
    capsule(ctx, o.preview.label, mr.x + mr.w / 2, mr.y + mr.h - 11, 10);
  }
  if (o.windowTarget) strokeRR(ctx, x + .5, y + .5, TW - 1, TH - 1, 10, PINK, 2);
  if (o.swapTarget) {
    fillRR(ctx, x, y, TW, TH, 10, PINKA(.14)); strokeRR(ctx, x + 1, y + 1, TW - 2, TH - 2, 10, PINK, 2);
    capsule(ctx, 'Intercambiar espacios', x + TW / 2, y + TH / 2, 11);
  }
  if (o.editable && !o.noBrackets) brackets(ctx, x, y, TW, TH);
  if (o.pulse) { ctx.globalAlpha = (1 - o.pulse) * .9; strokeRR(ctx, x - 4 * o.pulse - 1, y - 4 * o.pulse - 1, TW + 8 * o.pulse + 2, TH + 8 * o.pulse + 2, 12, PINK, 2); }
  ctx.restore();
}
function tileXY(board0, pos) { return [board0[0] + pos[1] * UNIT.w, board0[1] + pos[0] * UNIT.h]; }

// vidrio con desenfoque real de lo que hay detrás
let LAYER = null, CAMNOW = null;
function glass(ctx, x, y, w, h, r, alpha = 1) {
  ctx.save(); ctx.globalAlpha *= alpha;
  ctx.save(); rr(ctx, x, y, w, h, r); ctx.clip();
  if (LAYER && CAMNOW) {
    const m = ctx.getTransform(); ctx.setTransform(1, 0, 0, 1, 0, 0);
    const X = m.a * x + m.e, Y = m.d * y + m.f, Wd = w * m.a, Hd = h * m.d, pad = 40;
    const sx = clamp(X - pad, 0, W), sy = clamp(Y - pad, 0, H), ex = clamp(X + Wd + pad, 0, W), ey = clamp(Y + Hd + pad, 0, H);
    if (ex > sx && ey > sy) { ctx.filter = `blur(${Math.max(6, 22 * m.a)}px) saturate(1.3)`; ctx.drawImage(LAYER, sx, sy, ex - sx, ey - sy, sx, sy, ex - sx, ey - sy); ctx.filter = 'none'; }
    ctx.setTransform(m);
  }
  ctx.fillStyle = 'rgba(30,28,40,.74)'; ctx.fillRect(x, y, w, h);
  ctx.restore();
  ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.4)'; ctx.shadowBlur = 30 * SHADOW_SCALE; ctx.shadowOffsetY = 10 * SHADOW_SCALE;
  rr(ctx, x, y, w, h, r); ctx.strokeStyle = 'rgba(255,255,255,.14)'; ctx.lineWidth = 1; ctx.stroke(); ctx.restore();
  ctx.restore();
}

// Mapa durante el gesto (HUD no editable)
function drawHUD(ctx, hud, board, keys, displayName, sw, t) {
  const cols = Math.max(...keys.map(k => board[k].pos[1])) + 1, rows = Math.max(...keys.map(k => board[k].pos[0])) + 1;
  const bw = cols * UNIT.w - 10, bh = rows * UNIT.h - 10, pw = bw + 20, ph = bh + 54;
  const px = (sw - pw) / 2, py = MENU + 12, a = easeOut(hud.alpha);
  ctx.save(); ctx.globalAlpha = hud.alpha; ctx.translate(sw / 2, py); ctx.scale(lerp(.97, 1, a), lerp(.97, 1, a)); ctx.translate(-sw / 2, -py);
  glass(ctx, px, py, pw, ph, 16);
  txt(ctx, displayName, px + 12, py + 24, { size: 12, weight: 500, color: 'rgba(245,245,250,.95)' });
  txt(ctx, 'Soltá para abrir', px + pw - 12, py + 24, { size: 12, color: 'rgba(235,235,245,.6)', align: 'right' });
  const b0 = [px + 10, py + 42];
  for (const k of keys) {
    const [x, y] = tileXY(b0, board[k].pos), chosen = k === hud.selKey;
    drawTile(ctx, x, y, board[k], { chosen, origin: k === hud.origin, pulse: chosen && hud.since < .35 ? hud.since / .35 : 0 });
  }
  ctx.restore();
}

// Organizador (panel editable)
const PANEL = { w: 748, h: 432, x: (SW - 748) / 2, y: MENU + 12 };
const B0 = [PANEL.x + 10 + 24, PANEL.y + 44 + 24];
function organizerState(t) {
  const st = { windowDrag: null, spaceDrag: null };
  if (t >= K.wDragStart && t < K.wDrop) {
    const hover = t >= 39.3 ? (t >= K.wEdge ? 'top' : 'stack') : null;
    st.windowDrag = { hover };
  }
  if (t >= K.sGrab + .15 && t < K.sDrop) st.spaceDrag = { over: t >= 49.05 };
  return st;
}
function drawOrganizer(ctx, t, alpha) {
  const board = boardAt(t), keys = Object.keys(board), st = organizerState(t);
  const a = easeOut(alpha);
  ctx.save(); ctx.globalAlpha = alpha; ctx.translate(SW / 2, PANEL.y); ctx.scale(lerp(.96, 1, a), lerp(.96, 1, a)); ctx.translate(-SW / 2, -PANEL.y);
  const { x, y, w, h } = PANEL;
  glass(ctx, x, y, w, h, 16);
  // encabezado
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) strokeRR(ctx, x + 14 + j * 5, y + 15 + i * 5, 3.4, 3.4, .8, 'rgba(235,235,245,.6)', 1);
  txt(ctx, 'Tus espacios', x + 40, y + 27, { size: 13, weight: 500, color: '#fff' });
  const undoHot = t > 52.1 && t < 53.7;
  if (undoHot) fillRR(ctx, x + w - 72, y + 9, 28, 26, 6, 'rgba(255,255,255,.12)');
  ctx.strokeStyle = t > K.sDrop || t > K.wDrop ? 'rgba(245,245,250,.9)' : 'rgba(235,235,245,.35)'; ctx.lineWidth = 1.6;
  ctx.beginPath(); ctx.arc(x + w - 56, y + 23, 6, -Math.PI * .5, Math.PI * .6); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(x + w - 56, y + 17); ctx.lineTo(x + w - 63, y + 17); ctx.moveTo(x + w - 60, y + 13.5); ctx.lineTo(x + w - 63.5, y + 17); ctx.lineTo(x + w - 60, y + 20.5); ctx.stroke();
  ctx.strokeStyle = 'rgba(235,235,245,.75)'; ctx.beginPath(); ctx.moveTo(x + w - 30, y + 17); ctx.lineTo(x + w - 18, y + 29); ctx.moveTo(x + w - 18, y + 17); ctx.lineTo(x + w - 30, y + 29); ctx.stroke();
  // rieles con "+"
  for (let c = 0; c < 3; c++) for (const yy of [B0[1] - 12, B0[1] + 2 * UNIT.h + 2]) plus(ctx, B0[0] + c * UNIT.w + TW / 2, yy);
  for (let r = 0; r < 2; r++) for (const xx of [B0[0] - 12, B0[0] + 3 * UNIT.w + 2]) plus(ctx, xx, B0[1] + r * UNIT.h + TH / 2);
  // casilleros (el que se mueve se dibuja último)
  const cur = 'C', order = keys.filter(k => k !== 'D' && k !== 'F').concat('F', 'D');
  for (const k of order) {
    const sp = board[k], o = { editable: true, chosen: k === cur };
    const swapping = t >= K.sDrop && t < K.swapEnd;
    let [tx, ty] = tileXY(B0, sp.pos);
    if (swapping && k === 'D') ty += Math.sin(Math.PI * ease(seg(t, K.sDrop, K.swapEnd))) * 56;
    if (swapping && (k === 'D' || k === 'F')) o.opaque = true;
    if (!swapping) o.badge = neighborBadge(board, cur, k);
    if (st.windowDrag) {
      if (k === 'E') o.dimApp = 'browser';
      if (k === 'D' && st.windowDrag.hover) {
        o.windowTarget = true;
        o.preview = st.windowDrag.hover === 'stack' ? { tree: T_DSTACK, label: 'Apilar', hot: 'browser' } : { tree: T_D1, label: 'Arriba', hot: 'browser' };
      }
    }
    if (st.spaceDrag) { if (k === 'D') o.alpha = .55; if (k === 'F' && st.spaceDrag.over) o.swapTarget = true; }
    if (k === 'D' && t >= K.wDrop && t < K.wDrop + .5) o.pulse = (t - K.wDrop) / .5;
    if (k === 'D' && t >= K.swapEnd && t < K.swapEnd + .5) o.pulse = (t - K.swapEnd) / .5;
    if (swapping && (k === 'D' || k === 'F')) { o.noBrackets = true; ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.5)'; ctx.shadowBlur = 24 * SHADOW_SCALE; }
    if (k === 'D' && t > K.click - .12 && t < K.click + .12) { ctx.save(); const p = 1 - Math.abs(t - K.click) / .12; ctx.translate(tx + TW / 2, ty + TH / 2); ctx.scale(1 - .02 * p, 1 - .02 * p); ctx.translate(-tx - TW / 2, -ty - TH / 2); drawTile(ctx, tx, ty, sp, o); ctx.restore(); }
    else drawTile(ctx, tx, ty, sp, o);
    if (swapping && (k === 'D' || k === 'F')) ctx.restore();
  }
  // pie
  txt(ctx, 'Agarrá ⠿ para mover un espacio · Soltá en un borde para insertarlo', x + 12, y + h - 16, { size: 10.5, color: 'rgba(235,235,245,.55)' });
  fillRR(ctx, x + w - 44, y + h - 32, 32, 22, 6, 'rgba(255,255,255,.08)'); plus(ctx, x + w - 28, y + h - 21, 'rgba(245,245,250,.85)', 5);
  if (undoHot) { const ta = win(t, 52.3, 53.6, .15, .15); ctx.save(); ctx.globalAlpha *= ta; fillRR(ctx, x + w - 64, y + 52, 136, 24, 5, 'rgba(236,236,240,.97)'); txt(ctx, 'Deshacer organización', x + w + 4, y + 68, { size: 11.5, color: '#222', align: 'center' }); ctx.restore(); }
  ctx.restore();
  return st;
}
function plus(ctx, cx, cy, col = 'rgba(235,235,245,.38)', s = 4.5) { ctx.strokeStyle = col; ctx.lineWidth = 1.3; ctx.beginPath(); ctx.moveTo(cx - s, cy); ctx.lineTo(cx + s, cy); ctx.moveTo(cx, cy - s); ctx.lineTo(cx, cy + s); ctx.stroke(); }
function neighborBadge(board, cur, k) {
  const [r0, c0] = board[cur].pos, [r, c] = board[k].pos;
  if (r === r0 && Math.round(c) === c0 - 1) return '←'; if (r === r0 && Math.round(c) === c0 + 1) return '→';
  if (Math.round(c) === c0 && r === r0 + 1) return '↓'; if (Math.round(c) === c0 && r === r0 - 1) return '↑'; return '';
}
// fantasmas de arrastre (sobre el panel, siguen al puntero)
function drawDragGhosts(ctx, t, st, p) {
  if (st.windowDrag) {
    ctx.save(); ctx.globalAlpha = .88; ctx.shadowColor = 'rgba(0,0,0,.45)'; ctx.shadowBlur = 18 * SHADOW_SCALE;
    fillRR(ctx, p[0] + 12, p[1] + 14, 74, 58, 6, 'rgba(92,52,82,.95)'); ctx.restore();
    ctx.save(); ctx.globalAlpha = .95; icon(ctx, 'browser', p[0] + 49, p[1] + 36, 26); txt(ctx, 'Navegador', p[0] + 49, p[1] + 62, { size: 10, color: '#fff', align: 'center' }); ctx.restore();
  }
  if (st.spaceDrag) {
    const s = 'Editor · Navegador · Terminal', w = measure(ctx, s, 11.5, 500) + 22;
    ctx.save(); ctx.globalAlpha = .93; ctx.shadowColor = 'rgba(0,0,0,.45)'; ctx.shadowBlur = 18 * SHADOW_SCALE;
    fillRR(ctx, p[0] + 10, p[1] + 16, w, 30, 9, 'rgba(66,62,80,.97)'); ctx.restore();
    txt(ctx, s, p[0] + 21, p[1] + 35, { size: 11.5, weight: 500, color: '#fff' });
  }
}
function drawPointer(ctx, p, pressed, s = 1) {
  ctx.save(); ctx.translate(p[0], p[1]); const k = (pressed ? .9 : 1) * s; ctx.scale(k, k);
  ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(0, 22); ctx.lineTo(5.2, 17); ctx.lineTo(8.8, 25.3); ctx.lineTo(12.3, 23.8); ctx.lineTo(8.8, 15.8); ctx.lineTo(15.8, 15.8); ctx.closePath();
  ctx.shadowColor = 'rgba(0,0,0,.35)'; ctx.shadowBlur = 4 * SHADOW_SCALE; ctx.shadowOffsetY = 1.5 * SHADOW_SCALE;
  ctx.fillStyle = '#111'; ctx.fill(); ctx.shadowColor = 'transparent'; ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.6; ctx.stroke();
  ctx.restore();
}

// ------------------------------------------------------------------ capa explicativa (fuera de la UI)
const CAPTIONS = [
  [4.7, 7.9, 'Un espacio por tarea', 'Acá: el editor y la terminal del proyecto.'],
  [8.5, 12.3, 'Un mapa fijo', 'Cada espacio tiene su lugar: arriba, abajo, a los costados.'],
  [12.9, 16.4, 'Gesto corto · 3 dedos', 'Deslizá y pasás al espacio de al lado.'],
  [16.5, 19.6, 'Gesto corto · 3 dedos', 'La documentación, donde la dejaste.'],
  [19.9, 23.4, 'Mantené y explorá', 'Dedos apoyados: el mapa marca cada destino.'],
  [23.5, 26.7, 'Mantené y explorá', 'Tu escritorio no cambia mientras elegís.'],
  [26.9, 28.95, 'Soltá', 'Al levantar los dedos, abrís el último destino.'],
  [33.1, 37.0, 'Ordenar', 'Llevá el puntero al centro del borde superior.'],
  [37.2, 41.1, 'Ordenar · apps', 'Soltá una app en el centro de otra: se apilan…'],
  [41.2, 45.8, 'Ordenar · apps', '…o en un borde: se reparten el lugar.'],
  [46.0, 50.9, 'Mover un espacio', 'Arrastrá el encabezado: viaja entero, con su distribución.'],
  [51.0, 54.4, 'Mover un espacio', 'Ahora queda justo debajo del chat. Y se puede deshacer.'],
  [54.6, 59.0, 'Abrir', 'Un clic y estás ahí, tal como lo dibuja el mapa.'],
  [59.2, 64.8, 'A un gesto', 'El chat quedó arriba: 3 dedos hacia arriba y listo.'],
  [65.2, 68.0, 'Dos pantallas', 'Cada pantalla tiene su propio tablero.'],
  [68.1, 73.6, 'Dos pantallas · 4 dedos', '3 dedos mueven la pantalla bajo el puntero; 4, las dos.'],
];
function drawCaption(ctx, t) {
  for (const [a, b, kicker, line] of CAPTIONS) {
    if (t < a || t > b) continue;
    const al = win(t, a, b, .28, .22), rise = (1 - easeOut(seg(t, a, a + .35))) * 12;
    const kw = measure(ctx, kicker.toUpperCase(), 15, 700) + kicker.length * 2.2, lw = measure(ctx, line, 31, 600);
    const w = Math.max(kw, lw) + 64, h = 96, x = 960 - w / 2, y = H - 40 - h + rise;
    ctx.save(); ctx.globalAlpha = al;
    ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.45)'; ctx.shadowBlur = 30; fillRR(ctx, x, y, w, h, 20, 'rgba(14,12,24,.84)'); ctx.restore();
    strokeRR(ctx, x + .5, y + .5, w - 1, h - 1, 20, 'rgba(255,255,255,.1)');
    txt(ctx, kicker.toUpperCase(), 960, y + 34, { size: 15, weight: 700, color: PINK, align: 'center', ls: 2.2 });
    txt(ctx, line, 960, y + 74, { size: 31, weight: 600, color: '#fff', align: 'center' });
    ctx.restore();
  }
}
function drawLabel(ctx, t) {
  const a = 1 - seg(t, K.end - .2, K.end + .4);
  if (a <= 0) return;
  const s = 'Recreación animada de AeroGrid', w = measure(ctx, s, 15, 500) + 30;
  ctx.save(); ctx.globalAlpha = a * .92; fillRR(ctx, 36, H - 40 - 34, w, 34, 17, 'rgba(14,12,24,.72)'); strokeRR(ctx, 36.5, H - 40 - 33.5, w - 1, 33, 17, 'rgba(255,255,255,.12)');
  txt(ctx, s, 51, H - 40 - 12, { size: 15, weight: 500, color: 'rgba(255,255,255,.85)' }); ctx.restore();
}
function gestureAt(t) { for (const g of GESTURES) if (t > g.down - .7 && t < g.lift + 1.0) return g; return null; }
function drawTrackpad(ctx, t) {
  const g = gestureAt(t); if (!g) return;
  const a = Math.min(seg(t, g.down - .7, g.down - .35), 1 - seg(t, g.lift + .6, g.lift + 1.0));
  const cw = 300, ch = 200, cx = W - 40 - cw, cy = H - 40 - ch, rise = (1 - easeOut(a)) * 16;
  ctx.save(); ctx.globalAlpha = a; ctx.translate(0, rise);
  ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.5)'; ctx.shadowBlur = 30; fillRR(ctx, cx, cy, cw, ch, 20, 'rgba(14,12,24,.86)'); ctx.restore();
  strokeRR(ctx, cx + .5, cy + .5, cw - 1, ch - 1, 20, 'rgba(255,255,255,.1)');
  txt(ctx, `${g.n} dedos`, cx + 20, cy + 34, { size: 19, weight: 700, color: PINK });
  let label = g.label[0][0]; for (const [s, tt] of g.label) if (tt === 0 ? true : t >= tt) label = s;
  if (t > g.lift) label = g === GESTURES[1] ? 'soltaste: se abre' : 'listo';
  txt(ctx, label, cx + cw - 20, cy + 34, { size: 15, weight: 500, color: 'rgba(255,255,255,.78)', align: 'right' });
  const px = cx + 18, py = cy + 50, pw = cw - 36, ph = ch - 66;
  fillRR(ctx, px, py, pw, ph, 12, 'rgba(255,255,255,.055)'); strokeRR(ctx, px + .5, py + .5, pw - 1, ph - 1, 12, 'rgba(255,255,255,.16)');
  const pos = tt => { const pth = g.path; if (tt <= pth[0][0]) return [pth[0][1], pth[0][2]]; for (let i = 0; i < pth.length - 1; i++) { const [t0, x0, y0] = pth[i], [t1, x1, y1] = pth[i + 1]; if (tt <= t1) { const q = ease(clamp((tt - t0) / (t1 - t0))); return [lerp(x0, x1, q), lerp(y0, y1, q)]; } } const l = pth[pth.length - 1]; return [l[1], l[2]]; };
  const toPx = ([u, v]) => [px + pw / 2 + u * pw * .8, py + ph / 2 + v * ph * .8];
  // estela
  if (t > g.down) {
    ctx.save(); ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    const end = Math.min(t, g.lift), steps = 40; let prev = null;
    for (let i = 0; i <= steps; i++) {
      const tt = g.down + (end - g.down) * i / steps, q = toPx(pos(tt));
      if (prev) { ctx.strokeStyle = PINKA(.15 + .55 * i / steps); ctx.lineWidth = 3; ctx.beginPath(); ctx.moveTo(prev[0], prev[1]); ctx.lineTo(q[0], q[1]); ctx.stroke(); }
      prev = q;
    }
    ctx.restore();
  }
  // dedos
  const center = toPx(pos(Math.min(t, g.lift)));
  const down = seg(t, g.down - .12, g.down), up = seg(t, g.lift, g.lift + .25);
  const hovering = t < g.down - .12;
  for (let i = 0; i < g.n; i++) {
    const off = (i - (g.n - 1) / 2) * 26, fx = center[0] + off, fy = center[1] + (Math.abs(i - (g.n - 1) / 2) < 1 ? -4 : 3);
    if (hovering || up > 0) {
      const r = hovering ? 12 : 12 + up * 16;
      ctx.beginPath(); ctx.arc(fx, fy, r, 0, 7); ctx.strokeStyle = `rgba(255,255,255,${hovering ? .35 : .6 * (1 - up)})`; ctx.lineWidth = 2; ctx.stroke();
      continue;
    }
    ctx.save(); ctx.shadowColor = PINKA(.8); ctx.shadowBlur = 16;
    ctx.beginPath(); ctx.arc(fx, fy, 11 + (1 - down) * 3, 0, 7); ctx.fillStyle = `rgba(255,255,255,${.6 + .35 * down})`; ctx.fill(); ctx.restore();
  }
  ctx.restore();
}
function drawDwell(ctx, t, p) {
  const a = win(t, K.dwell - .05, K.panelIn + .15, .1, .15); if (a <= 0) return;
  const q = seg(t, K.dwell, K.panelIn);
  ctx.save(); ctx.globalAlpha = a; ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(255,255,255,.2)'; ctx.beginPath(); ctx.arc(p[0] + 6, p[1] + 10, 20, 0, 7); ctx.stroke();
  ctx.strokeStyle = PINK; ctx.lineCap = 'round'; ctx.beginPath(); ctx.arc(p[0] + 6, p[1] + 10, 20, -Math.PI / 2, -Math.PI / 2 + q * Math.PI * 2); ctx.stroke(); ctx.restore();
}

// ------------------------------------------------------------------ marcos de dispositivos
function macBezel(ctx, a) {
  if (a <= 0) return;
  ctx.save(); ctx.globalAlpha = a;
  fillRR(ctx, -22, -22, SW + 44, SH + 44, 30, '#0d0d12'); strokeRR(ctx, -22, -22, SW + 44, SH + 44, 30, 'rgba(255,255,255,.14)', 2);
  const g = ctx.createLinearGradient(0, SH + 22, 0, SH + 52); g.addColorStop(0, '#8b8b95'); g.addColorStop(1, '#3c3c44');
  rr(ctx, -150, SH + 22, SW + 300, 26, [0, 0, 22, 22]); ctx.fillStyle = g; ctx.fill();
  fillRR(ctx, SW / 2 - 110, SH + 22, 220, 9, [0, 0, 8, 8], 'rgba(0,0,0,.35)');
  ctx.restore();
}
function uwBezel(ctx, a) {
  ctx.save(); ctx.globalAlpha = a;
  fillRR(ctx, -26, -26, UW + 52, UH + 52, 26, '#0d0d12'); strokeRR(ctx, -26, -26, UW + 52, UH + 52, 26, 'rgba(255,255,255,.14)', 2.5);
  const g = ctx.createLinearGradient(0, UH + 26, 0, UH + 190); g.addColorStop(0, '#5a5a63'); g.addColorStop(1, '#2a2a31');
  ctx.fillStyle = g; ctx.fillRect(UW / 2 - 90, UH + 26, 180, 150); fillRR(ctx, UW / 2 - 330, UH + 170, 660, 28, 10, '#45454e');
  ctx.restore();
}

// ------------------------------------------------------------------ escenas
function drawTitle(ctx, t) {
  const out = seg(t, K.titleOut - .5, K.titleOut + .3), a = 1 - out;
  if (a <= 0) return;
  ctx.save(); ctx.globalAlpha = a; ctx.translate(0, -out * 40);
  const cx = 960, cy = 450;
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) {
    const p = backOut(seg(t, .15 + (i + j) * .07, .55 + (i + j) * .07)), s = 30 * p;
    fillRR(ctx, cx - 58 + j * 42 + (30 - s) / 2, cy - 190 + i * 42 + (30 - s) / 2, s, s, 7 * p, (i === 1 && j === 2) ? '#fff' : PINK);
  }
  const ta = easeOut(seg(t, .6, 1.2));
  ctx.globalAlpha = a * ta; txt(ctx, 'AeroGrid', cx, cy + 70 + (1 - ta) * 20, { size: 104, weight: 700, color: '#fff', align: 'center', ls: -1 });
  const sa = easeOut(seg(t, 1.1, 1.7));
  ctx.globalAlpha = a * sa; txt(ctx, 'Tus espacios de trabajo, ordenados como un mapa.', cx, cy + 150 + (1 - sa) * 16, { size: 38, weight: 500, color: 'rgba(255,255,255,.78)', align: 'center' });
  ctx.restore();
}
function drawEnd(ctx, t) {
  const a = seg(t, K.end - .3, K.end + .4); if (a <= 0) return;
  ctx.save(); ctx.globalAlpha = a; ctx.drawImage(BG, 0, 0); ctx.restore();
  const cx = 960;
  ctx.save(); ctx.globalAlpha = a;
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) fillRR(ctx, cx - 37 + j * 26, 150 + i * 26, 20, 20, 5, (i === 1 && j === 2) ? '#fff' : PINK);
  txt(ctx, 'AeroGrid', cx, 330, { size: 78, weight: 700, color: '#fff', align: 'center', ls: -.5 });
  const items = [['Deslizá', 'vas al espacio vecino'], ['Mantené', 'explorás el mapa'], ['Soltá', 'abrís el destino']];
  items.forEach(([k, d], i) => {
    const p = easeOut(seg(t, K.end + .35 + i * .3, K.end + .95 + i * .3)), x = cx + (i - 1) * 440;
    ctx.save(); ctx.globalAlpha = a * p; ctx.translate(0, (1 - p) * 18);
    txt(ctx, k, x, 520, { size: 56, weight: 700, color: PINK, align: 'center' });
    txt(ctx, d, x, 572, { size: 28, weight: 500, color: 'rgba(255,255,255,.82)', align: 'center' });
    ctx.restore();
    if (i < 2) { ctx.save(); ctx.globalAlpha = a * p * .5; txt(ctx, '→', x + 220, 532, { size: 40, color: '#fff', align: 'center' }); ctx.restore(); }
  });
  const q = easeOut(seg(t, K.end + 1.6, K.end + 2.3));
  ctx.globalAlpha = a * q; txt(ctx, 'Y ordenás tus apps y espacios arrastrando, con Deshacer siempre a mano.', cx, 700, { size: 30, weight: 500, color: 'rgba(255,255,255,.75)', align: 'center' });
  ctx.globalAlpha = a * q * .7; txt(ctx, 'Recreación animada · apps y contenido de ejemplo · sin capturas reales', cx, 1000, { size: 19, weight: 500, color: 'rgba(255,255,255,.8)', align: 'center' });
  ctx.restore();
  // fundido final
  const f = seg(t, DURATION - .6, DURATION); if (f > 0) { ctx.fillStyle = `rgba(0,0,0,${f})`; ctx.fillRect(0, 0, W, H); }
}

// Mapa conceptual (S1): las pantallas de cada espacio ubicadas en su lugar
const MAP_G = 150;
const MAP_SPACES = { A: [0, 0, T_A, 'mail'], B: [0, 1, 'notes', 'notes'], C: [0, 2, 'chat', 'chat'], D: [1, 0, T_D0, 'terminal'], E: [1, 1, 'browser', 'browser'], F: [1, 2, 'music', 'music'] };
function mapOffset(k) { const [r, c] = MAP_SPACES[k]; return [c * (SW + MAP_G), (r - 1) * (SH + MAP_G)]; }

// ------------------------------------------------------------------ cuadro principal
let CTX, LCTX;
function frame(t) {
  const ctx = CTX, lctx = LCTX;
  ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1; ctx.filter = 'none';
  ctx.drawImage(BG, 0, 0);
  const cam = track(camKeys, t); CAMNOW = cam; SHADOW_SCALE = cam.s;
  const bezel = track(bezelKeys, t, ease);
  const mapA = Math.min(seg(t, K.mapIn + .2, K.mapIn + 1.2), 1 - seg(t, K.mapOut, K.mapOut + .8));
  const dualA = seg(t, K.dual + .1, K.dual + 1.2);

  // 1) capa de escritorio (sin paneles) para usarla también como fondo del vidrio
  lctx.setTransform(1, 0, 0, 1, 0, 0); lctx.clearRect(0, 0, W, H);
  // monitor externo
  if (dualA > 0 && t < K.end + .5) {
    const uc = { s: UWCAM.s, x: lerp(-1150, UWCAM.x, easeOut(dualA)), y: UWCAM.y };
    lctx.save(); lctx.globalAlpha = dualA; lctx.setTransform(uc.s, 0, 0, uc.s, uc.x, uc.y); SHADOW_SCALE = uc.s;
    uwBezel(lctx, 1); clip(lctx, 0, 0, UW, UH, 8); drawDeskBlend(lctx, UWDESK, t, { uw: true }); lctx.restore(); lctx.restore();
    SHADOW_SCALE = cam.s;
  }
  lctx.setTransform(cam.s, 0, 0, cam.s, cam.x, cam.y);
  if (t < K.end + .5) {
    // pantallas vecinas del mapa conceptual
    if (mapA > 0) {
      for (const k of Object.keys(MAP_SPACES)) {
        if (k === 'D') continue;
        const [ox, oy] = mapOffset(k), [, , tree, focus] = MAP_SPACES[k];
        const p = easeOut(seg(t, K.mapIn + .3 + 'ABCEF'.indexOf(k) * .08, K.mapIn + 1.1 + 'ABCEF'.indexOf(k) * .08));
        lctx.save(); lctx.globalAlpha = mapA * p; lctx.translate(ox + SW / 2, oy + SH / 2); lctx.scale(lerp(.9, 1, p), lerp(.9, 1, p)); lctx.translate(-SW / 2, -SH / 2);
        lctx.save(); lctx.shadowColor = 'rgba(0,0,0,.5)'; lctx.shadowBlur = 40 * cam.s; fillRR(lctx, 0, 0, SW, SH, 18, '#000'); lctx.restore();
        clip(lctx, 0, 0, SW, SH, 18); drawDesk(lctx, { key: k, tree, focus }, t); lctx.restore();
        lctx.restore();
      }
    }
    macBezel(lctx, bezel);
    if (mapA > 0) { lctx.save(); lctx.shadowColor = 'rgba(0,0,0,.5)'; lctx.shadowBlur = 40 * cam.s; fillRR(lctx, 0, 0, SW, SH, 18, '#000'); lctx.restore(); }
    clip(lctx, 0, 0, SW, SH, mapA > 0 ? 18 : 12);
    drawDeskBlend(lctx, DESK, t, {});
    lctx.restore();
    if (mapA > 0) { strokeRR(lctx, -6, -6, SW + 12, SH + 12, 22, PINKA(mapA * .95), 6 / Math.max(.3, cam.s) * .5); }
  }
  ctx.drawImage(LAYER, 0, 0);
  LAYER_READY = true;

  // 2) UI de AeroGrid sobre la pantalla del MacBook
  ctx.save(); ctx.setTransform(cam.s, 0, 0, cam.s, cam.x, cam.y);
  clip(ctx, 0, 0, SW, SH, 12);
  const board = boardAt(t);
  const hud = hudAt(t);
  if (hud) drawHUD(ctx, hud, board, Object.keys(board), 'MacBook', SW, t);
  const orgA = Math.min(seg(t, K.panelIn, K.panelIn + .22), 1 - seg(t, K.panelOut, K.panelOut + .16));
  let st = { windowDrag: null, spaceDrag: null };
  if (orgA > 0) st = drawOrganizer(ctx, t, orgA);
  const p = pointerAt(t);
  const pressed = (t > K.wGrab && t < K.wDrop) || (t > K.sGrab && t < K.sDrop) || Math.abs(t - K.click) < .1;
  drawDragGhosts(ctx, t, st, p);
  if (t > K.screenIn - .6 && t < K.dual + .6) drawPointer(ctx, p, pressed);
  drawDwell(ctx, t, p);
  ctx.restore(); ctx.restore();
  // HUD en el monitor externo (4 dedos)
  if (hud && hud.uw && dualA > 0) {
    ctx.save(); ctx.setTransform(UWCAM.s, 0, 0, UWCAM.s, UWCAM.x, UWCAM.y); clip(ctx, 0, 0, UW, UH, 8);
    const ub = UWBOARD; drawHUD(ctx, { ...hud, origin: hud.uw.origin, selKey: hud.uw.sel }, ub, Object.keys(ub), 'Monitor externo', UW, t);
    ctx.restore(); ctx.restore();
  }

  // 3) capa explicativa
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  if (mapA > 0) drawMapLabels(ctx, t, cam, mapA);
  if (dualA > 0 && t < K.end + .5) drawDualLabels(ctx, dualA);
  drawTitle(ctx, t);
  drawCaption(ctx, t);
  drawTrackpad(ctx, t);
  drawLabel(ctx, t);
  drawEnd(ctx, t);
}
let LAYER_READY = false;
function drawMapLabels(ctx, t, cam, a) {
  for (const k of Object.keys(MAP_SPACES)) {
    const [ox, oy] = k === 'D' ? [0, 0] : mapOffset(k), [, , tree] = MAP_SPACES[k];
    const p = k === 'D' ? 1 : easeOut(seg(t, K.mapIn + .5 + 'ABCEF'.indexOf(k) * .08, K.mapIn + 1.3 + 'ABCEF'.indexOf(k) * .08));
    const x = cam.x + (ox + SW / 2) * cam.s, y = cam.y + (oy + SH) * cam.s + 34;
    ctx.save(); ctx.globalAlpha = a * p;
    if (k === 'D') {
      const s = 'Estás acá', w = measure(ctx, s, 15, 700) + 24; fillRR(ctx, x - w / 2, y - 22, w, 30, 15, PINK); txt(ctx, s, x, y - 1, { size: 15, weight: 700, color: '#fff', align: 'center' });
      txt(ctx, title(tree), x, y + 30, { size: 19, weight: 600, color: '#fff', align: 'center' });
    } else txt(ctx, title(tree), x, y, { size: 21, weight: 600, color: 'rgba(255,255,255,.9)', align: 'center' });
    ctx.restore();
  }
}
function drawDualLabels(ctx, a) {
  ctx.save(); ctx.globalAlpha = a;
  txt(ctx, 'Monitor externo', UWCAM.x + UW * UWCAM.s / 2, 770, { size: 21, weight: 600, color: 'rgba(255,255,255,.85)', align: 'center' });
  txt(ctx, 'MacBook', CAM.DUAL.x + SW * CAM.DUAL.s / 2, 770, { size: 21, weight: 600, color: 'rgba(255,255,255,.85)', align: 'center' });
  ctx.restore();
}

// ------------------------------------------------------------------ arranque
async function init() {
  const c = document.getElementById('c'); CTX = c.getContext('2d');
  LAYER = document.createElement('canvas'); LAYER.width = W; LAYER.height = H; LCTX = LAYER.getContext('2d');
  await loadImages(); if (document.fonts) await document.fonts.ready;
  BG = makeBG(); WP = makeWallpaper(SW, SH); WPUW = makeWallpaper(UW, UH);
  window.DURATION = DURATION; window.FPS = FPS;
  window.__frame = (t, type = 'image/png', q) => { frame(t); return c.toDataURL(type, q); };
  window.__draw = t => frame(t);
  const params = new URLSearchParams(location.search);
  if (params.has('render')) document.body.classList.add('render');
  const t0 = parseFloat(params.get('t') || '0'); frame(t0);
  const scrub = document.getElementById('scrub'), timeEl = document.getElementById('time'), play = document.getElementById('play');
  scrub.max = DURATION; scrub.value = t0; let playing = false, start = 0, base = t0;
  const show = t => { frame(t); scrub.value = t; timeEl.textContent = t.toFixed(2) + ' s'; };
  scrub.oninput = () => { base = parseFloat(scrub.value); show(base); if (playing) start = performance.now(); };
  play.onclick = () => { playing = !playing; play.textContent = playing ? '❚❚' : '▶︎'; start = performance.now(); base = parseFloat(scrub.value); if (playing) loop(); };
  function loop() { if (!playing) return; let t = base + (performance.now() - start) / 1000; if (t > DURATION) { base = 0; start = performance.now(); t = 0; } show(t); requestAnimationFrame(loop); }
  if (params.has('autoplay')) play.onclick();
  window.__ready = true;
}
init();
