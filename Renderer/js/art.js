// Album artwork loading + caching. Artwork arrives either as a URL (https or
// data:) from the native app, or as a built-in cover id.
import * as THREE from 'three';
import { loadImage, makeCanvas } from './util.js';
import { builtInCoverCanvas, builtInCovers, textCoverCanvas } from './textures.js';

const MAX_CACHED = 12;

export class ArtLibrary {
  constructor(renderer) {
    this.maxAnisotropy = renderer.capabilities.getMaxAnisotropy();
    this.cache = new Map(); // key -> Promise<{texture, canvas}>
    this.texts = new Map(); // text-cover key -> { title, artist }
  }

  key(art) {
    if (art?.artwork) return art.artwork;
    if (art?.text) return `text:${art.text.title}|${art.text.artist}`;
    if (/^builtin-\d+$/.test(art?.id || '')) return art.id;
    return 'builtin-0';
  }

  // Returns a promise resolving to a square sRGB texture.
  load(art) {
    const key = this.key(art);
    if (art?.text) this.texts.set(key, art.text);
    if (this.cache.has(key)) {
      const p = this.cache.get(key);
      this.cache.delete(key);
      this.cache.set(key, p); // LRU bump
      return p;
    }
    const p = this.#create(key).catch((err) => {
      console.warn(err);
      this.cache.delete(key);
      return this.load({ id: 'builtin-0' });
    });
    this.cache.set(key, p);
    this.#evict();
    return p;
  }

  async #create(key) {
    let source;
    const builtIn = /^builtin-(\d+)$/.exec(key);
    if (builtIn) {
      source = builtInCoverCanvas(Number(builtIn[1]));
    } else if (key.startsWith('text:')) {
      const t = this.texts.get(key) || { title: key.slice(5), artist: '' };
      source = textCoverCanvas(t.title, t.artist);
    } else {
      const img = await loadImage(key);
      source = squareCanvas(img, 1024);
    }
    const texture = new THREE.CanvasTexture(source);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.anisotropy = this.maxAnisotropy;
    texture.generateMipmaps = true;
    texture.minFilter = THREE.LinearMipmapLinearFilter;
    texture.needsUpdate = true;
    return { texture, canvas: source, key };
  }

  // Built-ins are cheap and always reused, so only fetched artwork is evicted.
  #evict() {
    const removable = [...this.cache.keys()].filter((k) => !k.startsWith('builtin-'));
    for (const k of [...this.texts.keys()]) if (!this.cache.has(k)) this.texts.delete(k);
    while (this.cache.size > MAX_CACHED && removable.length) {
      const key = removable.shift();
      const p = this.cache.get(key);
      this.cache.delete(key);
      p.then((a) => a.texture.dispose()).catch(() => {});
    }
  }
}

// Centre-crop any artwork to a square, capped at `max` pixels.
function squareCanvas(img, max) {
  const w = img.naturalWidth || img.width;
  const h = img.naturalHeight || img.height;
  const side = Math.min(w, h);
  const out = Math.min(max, side);
  const c = makeCanvas(out);
  const ctx = c.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(img, (w - side) / 2, (h - side) / 2, side, side, 0, 0, out, out);
  return c;
}

export const defaultRecent = builtInCovers.map((c) => ({ id: c.id, title: c.title, artist: c.artist }));
