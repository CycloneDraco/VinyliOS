// Vinyl renderer entry point.
//
// The native app hosts this page in a transparent WKWebView and drives it via
// `window.vinyl.update({...})`. Opened in a browser with `?demo` it runs on
// its own with built-in artwork (see README → "Working on the renderer").
import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/RoomEnvironment.js';
import { ArtLibrary, defaultRecent } from './art.js';
import { texturesReady } from './assets.js';
import { RoomScene } from './scenes/room.js';
import { TopDownScene } from './scenes/topdown.js';
import { MiniScene } from './scenes/mini.js';
import { clamp, prefersReducedMotion } from './util.js';

const native = window.webkit?.messageHandlers?.vinyl;
const post = (msg) => {
  try {
    native?.postMessage(msg);
  } catch {
    /* not hosted */
  }
};
window.addEventListener('error', (e) => post({ type: 'error', message: `${e.message} @ ${e.filename}:${e.lineno}` }));
window.addEventListener('unhandledrejection', (e) => post({ type: 'error', message: String(e.reason) }));

// ---------------------------------------------------------------------------
// Configuration (initial values come from the query string)
const q = new URLSearchParams(location.search);
const config = {
  scene: q.get('scene') || 'listening-room',
  framing: q.get('framing') || 'wide',
  size: q.has('size') ? Number(q.get('size')) : null,
  miniStyle: q.get('miniStyle') || null,
  background: q.get('background') !== '0',
  labelStyle: q.get('label') || 'label',
  tonearm: q.get('tonearm') !== '0',
  motion: q.has('motion') ? q.get('motion') !== '0' : !prefersReducedMotion(),
  fps: Number(q.get('fps')) || 60,
  quality: q.get('quality') || 'high',
  idleSpin: q.get('idleSpin') !== '0',
  paused: false,
};
const demo = q.has('demo');
const snapshot = q.has('snapshot');

// ---------------------------------------------------------------------------
// Renderer
const renderer = new THREE.WebGLRenderer({
  antialias: true,
  alpha: true,
  premultipliedAlpha: true,
  preserveDrawingBuffer: snapshot || q.has('preserve'), // ?preserve: lets tools read frames
  powerPreference: 'default',
});
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.shadowMap.autoUpdate = false;
document.body.appendChild(renderer.domElement);

const pmrem = new THREE.PMREMGenerator(renderer);
const envMap = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
pmrem.dispose();

const art = new ArtLibrary(renderer);
const ctx = { renderer, envMap, art };

function pixelRatio() {
  const dpr = window.devicePixelRatio || 1;
  const cap = { high: 2, balanced: 1.5, low: 1 }[config.quality] ?? 2;
  let pr = Math.min(dpr, cap);
  // Keep the drawing buffer under ~8.3 MP (4K) no matter how big the display.
  const px = window.innerWidth * window.innerHeight;
  pr = Math.min(pr, Math.sqrt(8.3e6 / Math.max(1, px)));
  return Math.max(0.5, pr);
}

// ---------------------------------------------------------------------------
// Player state
const player = {
  track: null, // { id, title, artist, album, artwork, artworkPending, duration }
  art: { id: 'builtin-0' }, // what the label/sleeve currently shows
  playing: false,
  position: 0,
  stampedAt: performance.now(),
  recent: [],
};

function currentPosition() {
  const elapsed = player.playing ? (performance.now() - player.stampedAt) / 1000 : 0;
  return player.position + elapsed;
}

function playerSnapshot() {
  const hasTrack = !!player.track;
  const idle = !hasTrack && config.idleSpin;
  let progress = 0.18;
  if (hasTrack && player.track.duration > 0) {
    progress = clamp(currentPosition() / player.track.duration, 0, 1);
  } else if (idle) {
    // Standalone mode: slowly play through the built-in record.
    progress = ((performance.now() / 1000) % 1500) / 1500;
  }
  return {
    hasTrack: hasTrack || idle,
    playing: player.playing || idle,
    cued: hasTrack && !player.playing,
    progress,
  };
}

function artFor(track) {
  if (!track) return { id: 'builtin-0', key: 'builtin-0' };
  if (track.artwork) return { artwork: track.artwork, key: track.artwork };
  if (/^builtin-\d+$/.test(track.id || '')) return { id: track.id, key: track.id };
  // No artwork anywhere: print a plain sleeve with the album name.
  const text = { title: track.album || track.title || 'Untitled', artist: track.artist || '' };
  return { text, key: `text:${text.title}|${text.artist}` };
}

// ---------------------------------------------------------------------------
// Scenes
let current = null;
let artToken = 0;

function createScene() {
  const opts = { ...config };
  if (config.scene === 'turntable') return new TopDownScene(ctx, opts);
  if (config.scene === 'mini') return new MiniScene(ctx, opts);
  return new RoomScene(ctx, opts);
}

function rebuildScene() {
  current?.dispose();
  current = createScene();
  current.resize(window.innerWidth, window.innerHeight);
  applyArt(true);
  applyNowPlaying();
  current.snapToState(playerSnapshot());
}

function applyNowPlaying() {
  if (!current) return;
  const t = player.track;
  current.setNowPlaying(t ? t.title : 'Vinyl', t ? t.artist : '');
}

async function applyArt(immediate = false) {
  const token = ++artToken;
  const trackArt = player.art;
  // With no listening history yet, the stack shows the built-in sleeves.
  const recent = player.recent.length ? player.recent : defaultRecent.slice(1);
  const [cur, ...rest] = await Promise.all([art.load(trackArt), ...recent.slice(0, 5).map((r) => art.load(r))]);
  if (token !== artToken || !current) return; // superseded
  current.setTrackArt(cur.texture, immediate);
  current.setRecentArt(
    rest.map((r) => r.texture),
    immediate
  );
}

// ---------------------------------------------------------------------------
// Public bridge
const SCENE_KEYS = ['scene'];
const OPTION_KEYS = ['framing', 'size', 'background', 'labelStyle', 'tonearm', 'miniStyle', 'motion', 'idleSpin'];

function update(patch = {}) {
  let rebuild = false;
  for (const key of SCENE_KEYS) {
    if (key in patch && patch[key] !== config[key]) {
      config[key] = patch[key];
      rebuild = true;
    }
  }
  for (const key of OPTION_KEYS) {
    if (key in patch && patch[key] !== config[key]) {
      config[key] = patch[key];
      if (!rebuild && current) {
        if (key === 'framing') current.setFraming(patch[key]);
        else if (key === 'background') current.setBackground(patch[key]);
        else current.setOption(key, patch[key]);
      }
    }
  }
  if ('fps' in patch) config.fps = Number(patch.fps) || 60;
  if ('quality' in patch && patch.quality !== config.quality) {
    config.quality = patch.quality;
    resize();
  }
  if ('paused' in patch) setPaused(!!patch.paused);

  let artChanged = false;
  if ('track' in patch) {
    const next = patch.track || null;
    player.track = next;
    // While new artwork loads, keep showing the previous cover.
    if (!next?.artworkPending) {
      const art = artFor(next);
      if (art.key !== player.art.key) {
        player.art = art;
        artChanged = true;
      }
    }
    applyNowPlaying();
  }
  if ('recent' in patch) {
    const ids = (l) => l.map((r) => r.artwork || r.id).join('|');
    if (ids(patch.recent || []) !== ids(player.recent)) artChanged = true;
    player.recent = patch.recent || [];
  }
  if ('position' in patch || 'playing' in patch) {
    // Freeze the extrapolated position before the playing flag changes.
    const position = 'position' in patch ? Number(patch.position) || 0 : currentPosition();
    if ('playing' in patch) player.playing = !!patch.playing;
    player.position = position;
    player.stampedAt = performance.now();
  }

  if (rebuild) rebuildScene();
  else if (artChanged) applyArt(false);
  wake();
}

window.vinyl = {
  update,
  getConfig: () => ({ ...config }),
  snapshot: () => renderer.domElement.toDataURL('image/png'),
};

// ---------------------------------------------------------------------------
// Loop
let rafId = 0;
let last = performance.now();
let lastFrame = 0;
let frames = 0;

function setPaused(paused) {
  config.paused = paused;
  if (paused) {
    cancelAnimationFrame(rafId);
    rafId = 0;
  } else {
    wake();
  }
}

function wake() {
  if (snapshot) return;
  if (!rafId && !config.paused && !document.hidden) {
    last = performance.now();
    rafId = requestAnimationFrame(frame);
  }
}

function frame(now) {
  rafId = 0;
  if (config.paused || document.hidden) return;
  rafId = requestAnimationFrame(frame);
  const s = playerSnapshot();
  // Nothing spinning and the arm at rest → a low frame rate is enough for
  // fades and light sway.
  const fps = s.playing || current.animating ? config.fps : Math.min(config.fps, 20);
  if (now - lastFrame < 1000 / fps - 2) return;
  lastFrame = now;
  const dt = Math.min(0.1, (now - last) / 1000);
  last = now;
  current.update(dt, now / 1000, s);
  current.render(renderer);
  if (++frames === 2) post({ type: 'ready' });
}

function resize() {
  renderer.setPixelRatio(pixelRatio());
  renderer.setSize(window.innerWidth, window.innerHeight);
  current?.resize(window.innerWidth, window.innerHeight);
  wake();
}
window.addEventListener('resize', resize);
document.addEventListener('visibilitychange', wake);

// ---------------------------------------------------------------------------
// Boot
renderer.setPixelRatio(pixelRatio());
renderer.setSize(window.innerWidth, window.innerHeight);
player.art = artFor(null);
rebuildScene();
post({ type: 'hello' });

if (snapshot) {
  runSnapshot();
} else {
  wake();
  if (demo) import('./demo.js').then((m) => m.startDemo(update, config, () => current));
}

// Deterministic single frame for automated previews (tools/snapshot.mjs).
async function runSnapshot() {
  if (demo) {
    const m = await import('./demo.js');
    m.applyDemoState(update, q);
  }
  await texturesReady();
  await applyArt(true);
  await texturesReady();
  const s = playerSnapshot();
  current.snapToState(s);
  for (let i = 0; i < 90; i++) current.update(1 / 30, i / 30, s);
  current.shadowsDirty = true;
  current.render(renderer);
  window.__vinylReady = true;
}
