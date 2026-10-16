// Procedural textures. Everything here is generated at runtime so the renderer
// ships with almost no binary assets and stays crisp at any display size.
import * as THREE from 'three';
import { makeCanvas, rng, clamp, smoothstep, TAU } from './util.js';

const cache = new Map();
const memo = (key, fn) => {
  if (!cache.has(key)) cache.set(key, fn());
  return cache.get(key);
};

export const RECORD_RADIUS = 0.15; // 12" LP, metres
export const LABEL_RADIUS = 0.05;

// ---------------------------------------------------------------------------
// Blur helper (ctx.filter is not available in every WebKit we support).
function boxBlur(imageData, radius, passes = 3) {
  const { width: w, height: h, data } = imageData;
  const tmp = new Float32Array(w * h * 4);
  const src = new Float32Array(data);
  for (let p = 0; p < passes; p++) {
    for (let pass = 0; pass < 2; pass++) {
      const horizontal = pass === 0;
      const len = horizontal ? w : h;
      const lines = horizontal ? h : w;
      for (let line = 0; line < lines; line++) {
        for (let c = 0; c < 4; c++) {
          let acc = 0;
          const idx = (i) => {
            const ii = clamp(i, 0, len - 1);
            return (horizontal ? line * w + ii : ii * w + line) * 4 + c;
          };
          for (let i = -radius; i <= radius; i++) acc += src[idx(i)];
          for (let i = 0; i < len; i++) {
            tmp[(horizontal ? line * w + i : i * w + line) * 4 + c] = acc / (2 * radius + 1);
            acc += src[idx(i + radius + 1)] - src[idx(i - radius)];
          }
        }
      }
      src.set(tmp);
    }
  }
  for (let i = 0; i < data.length; i++) data[i] = src[i];
  return imageData;
}

function canvasTexture(canvas, { srgb = true, repeat = false, aniso = 8 } = {}) {
  const t = new THREE.CanvasTexture(canvas);
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  if (repeat) t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.anisotropy = aniso;
  t.needsUpdate = true;
  return t;
}

// ---------------------------------------------------------------------------
// Vinyl record surface: colour, roughness and an anisotropy map whose
// direction is radial, so highlights stretch across the grooves like real vinyl.
export function recordTextures(size = 2048) {
  return memo(`record-${size}`, () => {
    const color = makeCanvas(size);
    const rough = makeCanvas(size);
    const aniso = makeCanvas(size);
    const cc = color.getContext('2d');
    const rc = rough.getContext('2d');
    const ac = aniso.getContext('2d');
    const cd = cc.createImageData(size, size);
    const rd = rc.createImageData(size, size);
    const ad = ac.createImageData(size, size);
    const rand = rng(7);

    // Per-ring brightness table: each groove ring gets its own tiny offset.
    const RINGS = 4096;
    const ring = new Float32Array(RINGS);
    let drift = 0;
    for (let i = 0; i < RINGS; i++) {
      drift = drift * 0.92 + (rand() - 0.5) * 0.6;
      ring[i] = drift * 0.5 + (rand() - 0.5) * 0.7;
    }
    const gaps = [0.47, 0.56, 0.645, 0.73, 0.82, 0.9];
    const half = size / 2;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const dx = (x + 0.5 - half) / half;
        const dy = (y + 0.5 - half) / half;
        const r = Math.sqrt(dx * dx + dy * dy);
        const i = (y * size + x) * 4;
        if (r > 1.0) {
          cd.data[i + 3] = 0;
          rd.data[i + 3] = 255;
          ad.data[i + 3] = 255;
          continue;
        }
        let lum = 0.032;
        let roughness = 0.38;
        let strength = 1.0;
        const ringIdx = Math.floor(r * (RINGS - 1));
        const groove = ring[ringIdx];
        if (r < 0.345) {
          // under the label – mostly hidden
          lum = 0.03;
          roughness = 0.3;
          strength = 0.0;
        } else if (r < 0.4) {
          // run-out: glossy with a couple of wide locked grooves
          lum = 0.026 + 0.004 * Math.sin(r * 900);
          roughness = 0.16;
          strength = 0.35;
        } else if (r < 0.975) {
          lum = 0.034 + groove * 0.012;
          roughness = 0.34 + groove * 0.05;
          for (const g of gaps) {
            const d = Math.abs(r - g);
            if (d < 0.006) {
              const k = 1 - smoothstep(0.003, 0.006, d);
              lum = lum * (1 - k) + 0.022 * k;
              roughness = roughness * (1 - k) + 0.14 * k;
              strength = 1 - 0.6 * k;
            }
          }
        } else if (r < 0.992) {
          lum = 0.03;
          roughness = 0.2;
          strength = 0.4;
        } else {
          // rolled edge catches a little light
          lum = 0.05;
          roughness = 0.3;
          strength = 0.2;
        }
        const v = Math.round(clamp(lum, 0, 1) * 255);
        cd.data[i] = v;
        cd.data[i + 1] = v;
        cd.data[i + 2] = Math.round(v * 1.04);
        cd.data[i + 3] = 255;
        const rv = Math.round(clamp(roughness, 0.05, 1) * 255);
        rd.data[i] = rv;
        rd.data[i + 1] = rv;
        rd.data[i + 2] = rv;
        rd.data[i + 3] = 255;
        // Direction in UV space (canvas y is flipped relative to v).
        const ux = dx / (r || 1);
        const vy = -dy / (r || 1);
        ad.data[i] = Math.round((ux * 0.5 + 0.5) * 255);
        ad.data[i + 1] = Math.round((vy * 0.5 + 0.5) * 255);
        ad.data[i + 2] = Math.round(strength * 255);
        ad.data[i + 3] = 255;
      }
    }
    cc.putImageData(cd, 0, 0);
    rc.putImageData(rd, 0, 0);
    ac.putImageData(ad, 0, 0);
    return {
      map: canvasTexture(color),
      roughnessMap: canvasTexture(rough, { srgb: false }),
      anisotropyMap: canvasTexture(aniso, { srgb: false, aniso: 4 }),
    };
  });
}

// Translucent groove overlay used for picture discs (art shows through).
export function pictureDiscOverlay(size = 1024) {
  return memo(`pd-${size}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    const d = ctx.createImageData(size, size);
    const rand = rng(11);
    const ring = new Float32Array(2048).map(() => rand());
    const half = size / 2;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const dx = (x + 0.5 - half) / half;
        const dy = (y + 0.5 - half) / half;
        const r = Math.sqrt(dx * dx + dy * dy);
        const i = (y * size + x) * 4;
        if (r > 1) continue;
        let a = 0.1 + ring[Math.floor(r * 2047)] * 0.08;
        if (r > 0.985) a = 0.85;
        else if (r < 0.06) a = 0.0;
        d.data[i] = d.data[i + 1] = d.data[i + 2] = 8;
        d.data[i + 3] = Math.round(a * 255);
      }
    }
    ctx.putImageData(d, 0, 0);
    return canvasTexture(c);
  });
}

// ---------------------------------------------------------------------------
// Light cookies (gobos)

// Window frame + a potted plant, as cast by low afternoon sun.
export function windowGobo(size = 1024) {
  return memo(`gobo-window-${size}`, () => {
    const s = 512;
    const c = makeCanvas(s);
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, s, s);
    // Panes (light passes)
    ctx.fillStyle = '#fff';
    const cols = 3;
    const rows = 2;
    const x0 = s * 0.12;
    const y0 = s * 0.1;
    const W = s * 0.8;
    const H = s * 0.82;
    const bar = s * 0.035;
    const pw = (W - bar * (cols - 1)) / cols;
    const ph = (H - bar * (rows - 1)) / rows;
    for (let r = 0; r < rows; r++) {
      for (let col = 0; col < cols; col++) {
        ctx.fillRect(x0 + col * (pw + bar), y0 + r * (ph + bar), pw, ph);
      }
    }
    // Plant silhouette (blocks light)
    const rand = rng(23);
    ctx.fillStyle = '#000';
    ctx.strokeStyle = '#000';
    const leaf = (x, y, len, ang, wid) => {
      ctx.save();
      ctx.translate(x, y);
      ctx.rotate(ang);
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.quadraticCurveTo(len * 0.5, -wid, len, 0);
      ctx.quadraticCurveTo(len * 0.5, wid, 0, 0);
      ctx.fill();
      ctx.restore();
    };
    const stems = 9;
    for (let i = 0; i < stems; i++) {
      const bx = s * (0.05 + rand() * 0.22);
      const by = s * 1.02;
      const ang = -Math.PI / 2 + (rand() - 0.6) * 1.1;
      const len = s * (0.35 + rand() * 0.35);
      ctx.lineWidth = 2.5;
      ctx.beginPath();
      ctx.moveTo(bx, by);
      const ex = bx + Math.cos(ang) * len;
      const ey = by + Math.sin(ang) * len;
      ctx.quadraticCurveTo(bx + Math.cos(ang + 0.3) * len * 0.5, by + Math.sin(ang + 0.3) * len * 0.5, ex, ey);
      ctx.stroke();
      const leaves = 4 + Math.floor(rand() * 4);
      for (let l = 0; l < leaves; l++) {
        const t = 0.35 + (l / leaves) * 0.65;
        const lx = bx + (ex - bx) * t;
        const ly = by + (ey - by) * t;
        const side = l % 2 ? 1 : -1;
        leaf(lx, ly, s * (0.06 + rand() * 0.07), ang + side * (0.5 + rand() * 0.6), s * (0.018 + rand() * 0.02));
      }
    }
    const img = boxBlur(ctx.getImageData(0, 0, s, s), 5, 3);
    ctx.putImageData(img, 0, 0);
    const big = makeCanvas(size);
    const bctx = big.getContext('2d');
    bctx.imageSmoothingQuality = 'high';
    bctx.drawImage(c, 0, 0, size, size);
    const t = canvasTexture(big);
    t.wrapS = t.wrapT = THREE.ClampToEdgeWrapping;
    return t;
  });
}

// Venetian blinds: long soft stripes, used by the top-down turntable.
export function blindsGobo(size = 512) {
  return memo(`gobo-blinds-${size}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, size, size);
    ctx.fillStyle = '#fff';
    const stripes = 5;
    for (let i = 0; i < stripes; i++) {
      const y = size * (0.08 + i * 0.19);
      ctx.fillRect(size * 0.04, y, size * 0.92, size * 0.12);
    }
    const img = boxBlur(ctx.getImageData(0, 0, size, size), 6, 3);
    ctx.putImageData(img, 0, 0);
    return canvasTexture(c);
  });
}

// ---------------------------------------------------------------------------
// Soft contact shadows (multiplied onto surfaces under objects).
export function contactShadow(kind = 'round', size = 256) {
  return memo(`contact-${kind}-${size}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    // Opaque greyscale: used as an alphaMap, which samples the green channel.
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, size, size);
    if (kind === 'round') {
      const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
      g.addColorStop(0, '#d9d9d9');
      g.addColorStop(0.55, '#737373');
      g.addColorStop(1, '#000');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, size, size);
    } else {
      ctx.fillStyle = '#fff';
      const m = size * 0.16;
      ctx.fillRect(m, m, size - 2 * m, size - 2 * m);
      const img = boxBlur(ctx.getImageData(0, 0, size, size), Math.round(size * 0.05), 3);
      ctx.putImageData(img, 0, 0);
    }
    const t = canvasTexture(c, { srgb: false });
    return t;
  });
}

// ---------------------------------------------------------------------------
// Materials detail

export function brushedMetal(size = 1024, base = [206, 201, 192]) {
  return memo(`brushed-${size}-${base.join(',')}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    const d = ctx.createImageData(size, size);
    const rand = rng(5);
    const rowNoise = new Float32Array(size).map(() => rand() - 0.5);
    for (let y = 0; y < size; y++) {
      let streak = 0;
      for (let x = 0; x < size; x++) {
        streak = streak * 0.985 + (rand() - 0.5) * 0.9;
        const n = rowNoise[y] * 10 + streak * 6 + (rand() - 0.5) * 6;
        const i = (y * size + x) * 4;
        d.data[i] = clamp(base[0] + n, 0, 255);
        d.data[i + 1] = clamp(base[1] + n, 0, 255);
        d.data[i + 2] = clamp(base[2] + n, 0, 255);
        d.data[i + 3] = 255;
      }
    }
    ctx.putImageData(d, 0, 0);
    return canvasTexture(c, { repeat: true });
  });
}

// Fine linen/powder-coat grain for painted plinths.
export function grainTexture(size = 512, seed = 3) {
  return memo(`grain-${size}-${seed}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    const d = ctx.createImageData(size, size);
    const rand = rng(seed);
    for (let i = 0; i < size * size; i++) {
      const v = 128 + (rand() - 0.5) * 40;
      d.data[i * 4] = d.data[i * 4 + 1] = d.data[i * 4 + 2] = v;
      d.data[i * 4 + 3] = 255;
    }
    ctx.putImageData(d, 0, 0);
    return canvasTexture(c, { srgb: false, repeat: true });
  });
}

// Vertical ribs for the glass lamp shade (tangent-space normal map).
export function ribbedNormal(ribs = 28, size = 512) {
  return memo(`ribs-${ribs}-${size}`, () => {
    const c = makeCanvas(size, 8);
    const ctx = c.getContext('2d');
    const d = ctx.createImageData(size, 8);
    for (let x = 0; x < size; x++) {
      const phase = (x / size) * ribs * TAU;
      const nx = Math.sin(phase) * 0.75;
      const nz = Math.sqrt(1 - nx * nx);
      for (let y = 0; y < 8; y++) {
        const i = (y * size + x) * 4;
        d.data[i] = Math.round((nx * 0.5 + 0.5) * 255);
        d.data[i + 1] = 128;
        d.data[i + 2] = Math.round((nz * 0.5 + 0.5) * 255);
        d.data[i + 3] = 255;
      }
    }
    ctx.putImageData(d, 0, 0);
    const t = canvasTexture(c, { srgb: false, repeat: true });
    return t;
  });
}

// Soft additive glow sprite.
export function glowTexture(size = 256, color = '255,190,120') {
  return memo(`glow-${size}-${color}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    g.addColorStop(0, `rgba(${color},1)`);
    g.addColorStop(0.2, `rgba(${color},0.45)`);
    g.addColorStop(0.5, `rgba(${color},0.12)`);
    g.addColorStop(1, `rgba(${color},0)`);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, size, size);
    return canvasTexture(c);
  });
}

// Rectangular halo used for the LED wash behind the After Hours frame.
export function haloTexture(size = 512, color = '255,170,110') {
  return memo(`halo-${size}-${color}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    ctx.fillStyle = `rgba(${color},1)`;
    const m = size * 0.22;
    ctx.fillRect(m, m, size - 2 * m, size - 2 * m);
    const img = boxBlur(ctx.getImageData(0, 0, size, size), Math.round(size * 0.07), 3);
    ctx.putImageData(img, 0, 0);
    return canvasTexture(c);
  });
}

// ---------------------------------------------------------------------------
// Text plates

export function nameplateTexture(title, subtitle, opts = {}) {
  const w = 1024;
  const h = 160;
  const c = makeCanvas(w, h);
  const ctx = c.getContext('2d');
  if (opts.background !== 'none') {
    ctx.fillStyle = opts.background || '#1d1c1b';
    ctx.fillRect(0, 0, w, h);
    ctx.strokeStyle = 'rgba(255,255,255,0.08)';
    ctx.lineWidth = 4;
    ctx.strokeRect(6, 6, w - 12, h - 12);
  }
  ctx.fillStyle = opts.color || 'rgba(235,228,214,0.92)';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  const font = '-apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif';
  const fit = (text, weight, px, maxW) => {
    let size = px;
    do {
      ctx.font = `${weight} ${size}px ${font}`;
      size -= 2;
    } while (ctx.measureText(text).width > maxW && size > 18);
  };
  const t = (title || '').toUpperCase();
  if (subtitle) {
    fit(t, 600, 54, w - 80);
    ctx.fillText(t, w / 2, h * 0.38, w - 80);
    ctx.fillStyle = opts.subColor || 'rgba(235,228,214,0.6)';
    fit(subtitle, 500, 38, w - 80);
    ctx.fillText(subtitle, w / 2, h * 0.72, w - 80);
  } else {
    fit(t, 600, 64, w - 80);
    if (opts.tracking) ctx.letterSpacing = opts.tracking;
    ctx.fillText(t, w / 2, h / 2, w - 80);
  }
  const tex = canvasTexture(c);
  return tex;
}

// ---------------------------------------------------------------------------
// Built-in artwork: generative sleeves so the scene looks lived-in before any
// music plays. All original designs.
const COVER_DESIGNS = [
  { title: 'Afternoon Light', artist: 'The Listening Room', draw: coverBauhaus },
  { title: 'Golden Hour', artist: 'Sundial', draw: coverSunset },
  { title: 'After Hours', artist: 'Night Shift Trio', draw: coverNight },
  { title: 'Quiet Peaks', artist: 'Field Recordings', draw: coverPeaks },
  { title: 'Side B', artist: 'Studio 33', draw: coverSwiss },
];

export const builtInCovers = COVER_DESIGNS.map((d, i) => ({ id: `builtin-${i}`, title: d.title, artist: d.artist }));

export function builtInCoverCanvas(index, size = 1024) {
  return memo(`cover-${index}-${size}`, () => {
    const c = makeCanvas(size);
    const ctx = c.getContext('2d');
    const design = COVER_DESIGNS[index % COVER_DESIGNS.length];
    design.draw(ctx, size, rng(100 + index));
    paperGrain(ctx, size, rng(200 + index));
    return c;
  });
}

// A plain printed sleeve for music without artwork (local files, radio…).
export function textCoverCanvas(title, artist, size = 1024) {
  const c = makeCanvas(size);
  const ctx = c.getContext('2d');
  let h = 0;
  for (const ch of `${title}${artist}`) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const hue = h % 360;
  ctx.fillStyle = `hsl(${hue}, 32%, 34%)`;
  ctx.fillRect(0, 0, size, size);
  ctx.fillStyle = `hsl(${(hue + 30) % 360}, 40%, 82%)`;
  ctx.fillRect(size * 0.08, size * 0.08, size * 0.84, size * 0.004);
  ctx.textAlign = 'left';
  ctx.textBaseline = 'alphabetic';
  // Wrap the title onto up to three lines.
  let px = size * 0.1;
  const maxW = size * 0.84;
  const words = String(title).split(/\s+/);
  let lines;
  do {
    ctx.font = `600 ${px}px ${serif}`;
    lines = [];
    let line = '';
    for (const w of words) {
      const test = line ? `${line} ${w}` : w;
      if (ctx.measureText(test).width > maxW && line) {
        lines.push(line);
        line = w;
      } else line = test;
    }
    lines.push(line);
    px *= 0.9;
  } while ((lines.length > 3 || lines.some((l) => ctx.measureText(l).width > maxW)) && px > size * 0.03);
  const lh = px * 1.25;
  lines.forEach((l, i) => ctx.fillText(l, size * 0.08, size * 0.2 + lh * (i + 0.6)));
  ctx.font = `500 ${size * 0.045}px ${sans}`;
  ctx.fillStyle = `hsla(${(hue + 30) % 360}, 40%, 88%, 0.8)`;
  ctx.fillText(String(artist).toUpperCase(), size * 0.08, size * 0.9, maxW);
  paperGrain(ctx, size, rng(h));
  return c;
}

function paperGrain(ctx, size, rand) {
  const d = ctx.getImageData(0, 0, size, size);
  for (let i = 0; i < d.data.length; i += 4) {
    const n = (rand() - 0.5) * 14;
    d.data[i] = clamp(d.data[i] + n, 0, 255);
    d.data[i + 1] = clamp(d.data[i + 1] + n, 0, 255);
    d.data[i + 2] = clamp(d.data[i + 2] + n, 0, 255);
  }
  ctx.putImageData(d, 0, 0);
}

const serif = '"New York", "Iowan Old Style", Georgia, "Times New Roman", serif';
const sans = '-apple-system, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif';

function coverBauhaus(ctx, s) {
  ctx.fillStyle = '#b8343b';
  ctx.fillRect(0, 0, s, s);
  ctx.fillStyle = '#22285a';
  ctx.fillRect(s * 0.26, s * 0.3, s * 0.56, s * 0.42);
  ctx.strokeStyle = '#f1e9dc';
  ctx.lineWidth = s * 0.008;
  ctx.strokeRect(s * 0.42, s * 0.2, s * 0.3, s * 0.56);
  ctx.fillStyle = '#c9a646';
  ctx.fillRect(s * 0.55, s * 0.36, s * 0.34, s * 0.06);
  ctx.fillStyle = '#e9e2d6';
  ctx.fillRect(s * 0.14, s * 0.14, s * 0.12, s * 0.36);
  ctx.fillStyle = '#f1e9dc';
  ctx.font = `italic ${s * 0.042}px ${serif}`;
  ctx.textAlign = 'center';
  ctx.fillText('Afternoon Light', s * 0.5, s * 0.88);
}

function coverSunset(ctx, s) {
  const g = ctx.createLinearGradient(0, 0, 0, s);
  g.addColorStop(0, '#f6c66b');
  g.addColorStop(0.55, '#ec7a4b');
  g.addColorStop(1, '#5b2a4e');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, s, s);
  ctx.fillStyle = 'rgba(255,240,200,0.92)';
  ctx.beginPath();
  ctx.arc(s * 0.5, s * 0.56, s * 0.2, 0, TAU);
  ctx.fill();
  for (let i = 0; i < 7; i++) {
    ctx.fillStyle = `rgba(91,42,78,${0.35 + i * 0.09})`;
    ctx.fillRect(0, s * (0.6 + i * 0.06), s, s * 0.03 + i * 2);
  }
  ctx.fillStyle = '#3b1834';
  ctx.font = `700 ${s * 0.07}px ${sans}`;
  ctx.textAlign = 'left';
  ctx.fillText('GOLDEN', s * 0.07, s * 0.14);
  ctx.fillText('HOUR', s * 0.07, s * 0.21);
}

function coverNight(ctx, s, rand) {
  ctx.fillStyle = '#0e0f1c';
  ctx.fillRect(0, 0, s, s);
  for (let i = 0; i < 160; i++) {
    ctx.fillStyle = `rgba(255,255,255,${rand() * 0.7})`;
    ctx.fillRect(rand() * s, rand() * s * 0.6, 2, 2);
  }
  ctx.strokeStyle = 'rgba(255,92,170,0.85)';
  ctx.lineWidth = s * 0.004;
  for (let i = 0; i < 12; i++) {
    const y = s * 0.62 + i * i * s * 0.0028;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(s, y);
    ctx.stroke();
  }
  for (let i = -10; i <= 10; i++) {
    ctx.beginPath();
    ctx.moveTo(s / 2 + i * s * 0.02, s * 0.62);
    ctx.lineTo(s / 2 + i * s * 0.16, s);
    ctx.stroke();
  }
  const g = ctx.createLinearGradient(0, s * 0.3, 0, s * 0.6);
  g.addColorStop(0, '#ffcf6b');
  g.addColorStop(1, '#ff4f9a');
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.arc(s / 2, s * 0.6, s * 0.22, Math.PI, 0);
  ctx.fill();
  ctx.fillStyle = '#0e0f1c';
  for (let i = 0; i < 6; i++) ctx.fillRect(0, s * (0.47 + i * 0.022), s, s * 0.006 + i * 1.6);
  ctx.fillStyle = '#ffe6f2';
  ctx.font = `600 ${s * 0.05}px ${sans}`;
  ctx.textAlign = 'center';
  ctx.fillText('A F T E R   H O U R S', s / 2, s * 0.16);
}

function coverPeaks(ctx, s, rand) {
  const g = ctx.createLinearGradient(0, 0, 0, s);
  g.addColorStop(0, '#9fb6c4');
  g.addColorStop(1, '#e7e1d3');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, s, s);
  const layers = ['#6f8796', '#4f6674', '#33444f', '#1f2b33'];
  layers.forEach((col, li) => {
    ctx.fillStyle = col;
    ctx.beginPath();
    ctx.moveTo(0, s);
    let y = s * (0.5 + li * 0.1);
    for (let x = 0; x <= s; x += s / 24) {
      y += (rand() - 0.5) * s * 0.06;
      ctx.lineTo(x, y);
    }
    ctx.lineTo(s, s);
    ctx.fill();
  });
  ctx.fillStyle = '#f4efe4';
  ctx.font = `500 ${s * 0.045}px ${serif}`;
  ctx.textAlign = 'center';
  ctx.fillText('Quiet Peaks', s / 2, s * 0.2);
}

function coverSwiss(ctx, s) {
  ctx.fillStyle = '#ece6d9';
  ctx.fillRect(0, 0, s, s);
  ctx.fillStyle = '#121212';
  ctx.font = `800 ${s * 0.42}px ${sans}`;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'alphabetic';
  ctx.fillText('B', s * 0.06, s * 0.92);
  ctx.fillStyle = '#e2512b';
  ctx.beginPath();
  ctx.arc(s * 0.7, s * 0.34, s * 0.2, 0, TAU);
  ctx.fill();
  ctx.fillStyle = '#121212';
  ctx.font = `600 ${s * 0.035}px ${sans}`;
  ctx.fillText('STUDIO 33 — SIDE B', s * 0.06, s * 0.1);
  ctx.fillRect(s * 0.06, s * 0.13, s * 0.88, s * 0.006);
}
