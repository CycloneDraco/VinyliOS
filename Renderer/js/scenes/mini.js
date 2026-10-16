// Mini player, seen from directly above, floating on the desktop:
//   'turntable' — a small deck with platter, record and tonearm (default)
//   'record'    — just the spinning record
// The window around it is transparent; the native app sizes it to the
// aspect ratio in MINI_BOUNDS.
import * as THREE from 'three';
import { BaseScene } from './base.js';
import { createTurntable } from '../models/turntable.js';
import { contactPlane } from '../models/props.js';
import { RECORD_RADIUS } from '../textures.js';

// Content bounds in metres (top-down), including room for the drop shadow.
// Mirrored by MiniPlayerController.aspect(style:) in the Swift app.
const DECK_W = 0.46;
const DECK_D = 0.4;
const DECK_MARGIN = 0.025;
const RECORD_MARGIN = RECORD_RADIUS * 0.08;
export const MINI_BOUNDS = {
  turntable: { hw: DECK_W / 2 + DECK_MARGIN, hh: DECK_D / 2 + DECK_MARGIN },
  record: { hw: RECORD_RADIUS + RECORD_MARGIN, hh: RECORD_RADIUS + RECORD_MARGIN },
};

export function miniStyle(options) {
  if (options.miniStyle === 'record' || options.miniStyle === 'turntable') return options.miniStyle;
  return options.tonearm === false ? 'record' : 'turntable';
}

export class MiniScene extends BaseScene {
  constructor(ctx, options) {
    super(ctx, options);
    this.scene.environmentIntensity = 0.7;
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.01, 5);
    const key = (this.key = new THREE.DirectionalLight(0xffffff, 1.7));
    key.position.set(-0.45, 1.1, -0.4);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    Object.assign(key.shadow.camera, { left: -0.35, right: 0.35, top: 0.35, bottom: -0.35 });
    key.shadow.bias = -0.0005;
    key.shadow.normalBias = 0.004;
    this.scene.add(key, new THREE.HemisphereLight(0xffffff, 0x8a8a8a, 1.0));
    this.#build();
  }

  #build() {
    if (this.root) {
      this.scene.remove(this.root);
      // Materials don't own their maps, so artwork textures survive this.
      this.root.traverse((o) => {
        o.geometry?.dispose();
        o.material?.dispose();
      });
    }
    const style = (this.style = miniStyle(this.options));
    const root = (this.root = new THREE.Group());
    this.scene.add(root);

    const tt = (this.turntable = createTurntable({
      style: style === 'turntable' ? 'silver' : 'none',
      labelStyle: this.options.labelStyle || 'label',
      envMap: this.ctx.envMap,
      recordReflections: 0.12,
      recordRoughness: style === 'turntable' ? 0.9 : 1,
      recordAnisotropy: style === 'turntable' ? 0.45 : 0.9,
      recordSpecular: style === 'turntable' ? 0.3 : 1,
      liftScale: 0.05,
    }));
    root.add(tt.group);
    if (style === 'turntable') {
      // Centre the deck itself in the window.
      tt.group.position.set(0, 0, 0);
      const shadow = contactPlane('rect', DECK_W + 0.07, DECK_D + 0.07, 0.6);
      shadow.position.set(0.006, -0.001, 0.01);
      root.add(shadow);
    } else {
      // Record only: no arm, no deck.
      tt.group.traverse((o) => {
        if (o.parent === tt.group && o !== tt.spin) o.visible = false;
      });
      const shadow = contactPlane('round', RECORD_RADIUS * 2.5, RECORD_RADIUS * 2.5, 0.55);
      shadow.position.set(0.006, -0.002, 0.012);
      root.add(shadow);
    }
    this.shadowCatcher = new THREE.Mesh(
      new THREE.PlaneGeometry(1.2, 1.2).rotateX(-Math.PI / 2),
      new THREE.ShadowMaterial({ opacity: 0.25 })
    );
    this.shadowCatcher.position.y = -0.0015;
    this.shadowCatcher.receiveShadow = true;
    root.add(this.shadowCatcher);
    this.layout();
    this.shadowsDirty = true;
  }

  setOption(key, value) {
    const before = miniStyle(this.options);
    const changed = this.options[key] !== value;
    super.setOption(key, value);
    const rebuild = key === 'labelStyle' ? changed : miniStyle(this.options) !== before;
    if (rebuild) {
      const art = this.currentArt;
      this.#build();
      if (art) this.turntable.setArt(art, true);
      if (this.lastPlayer) this.turntable.snapArm(this.lastPlayer);
      if (this.nowPlaying) this.turntable.setNameplate(...this.nowPlaying);
    }
  }

  setTrackArt(tex, immediate) {
    this.currentArt = tex;
    super.setTrackArt(tex, immediate);
  }

  setNowPlaying(title, artist) {
    this.nowPlaying = [title, artist];
    super.setNowPlaying(title, artist);
  }

  layout() {
    if (!this.style) return;
    const aspect = this.width / this.height || 1;
    let { hw, hh } = MINI_BOUNDS[this.style];
    if (hw / hh > aspect) hh = hw / aspect;
    else hw = hh * aspect;
    Object.assign(this.camera, { left: -hw, right: hw, top: hh, bottom: -hh });
    this.camera.position.set(0, 1, 0);
    this.camera.up.set(0, 0, -1);
    this.camera.lookAt(0, 0, 0);
    this.camera.updateProjectionMatrix();
  }

  update(dt, time, player) {
    this.lastPlayer = player;
    super.update(dt, time, player);
  }
}
