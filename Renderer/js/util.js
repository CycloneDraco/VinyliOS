// Small math + canvas helpers shared by every scene.

export const TAU = Math.PI * 2;

export const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
export const lerp = (a, b, t) => a + (b - a) * t;
export const smoothstep = (a, b, x) => {
  const t = clamp((x - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
};

// Frame-rate independent exponential approach (critically damped feel).
export const damp = (current, target, lambda, dt) =>
  lerp(current, target, 1 - Math.exp(-lambda * dt));

// Critically damped spring. `response` is roughly the settle time in seconds,
// the same mental model as SwiftUI's spring(response:dampingFraction: 1).
export class Spring {
  constructor(value = 0, response = 0.5) {
    this.value = value;
    this.target = value;
    this.velocity = 0;
    this.response = response;
  }
  update(dt) {
    const omega = (2 * Math.PI) / this.response;
    const x = this.value - this.target;
    // Analytic critically damped step: stable for any dt.
    const exp = Math.exp(-omega * dt);
    const c = this.velocity + omega * x;
    this.value = this.target + (x + c * dt) * exp;
    this.velocity = (this.velocity - omega * c * dt) * exp;
    return this.value;
  }
  get settled() {
    return Math.abs(this.value - this.target) < 1e-4 && Math.abs(this.velocity) < 1e-4;
  }
  snap(v) {
    this.value = this.target = v;
    this.velocity = 0;
  }
}

// Deterministic PRNG so procedural textures look the same on every launch.
export function rng(seed = 1) {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function makeCanvas(w, h = w) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

export function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.decoding = 'async';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`Failed to load image ${String(url).slice(0, 80)}`));
    img.src = url;
  });
}

export function hash32(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

export const prefersReducedMotion = () =>
  window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
