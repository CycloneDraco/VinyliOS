// Bundled image textures (CC0 photo textures + public-domain wall art).
import * as THREE from 'three';

const loader = new THREE.TextureLoader();
const cache = new Map();
const pending = new Set();

export function texture(path, { srgb = true, repeat = null, anisotropy = 8 } = {}) {
  const key = `${path}|${srgb}|${repeat}`;
  if (cache.has(key)) return cache.get(key);
  let done;
  const p = new Promise((r) => (done = r));
  pending.add(p);
  const t = loader.load(
    path,
    () => {
      pending.delete(p);
      done();
    },
    undefined,
    () => {
      console.warn(`texture failed: ${path}`);
      pending.delete(p);
      done();
    }
  );
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  if (repeat) {
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.repeat.set(repeat[0], repeat[1]);
  }
  t.anisotropy = anisotropy;
  cache.set(key, t);
  return t;
}

// Resolves once every texture requested so far has finished loading.
export async function texturesReady() {
  while (pending.size) await Promise.all([...pending]);
}
