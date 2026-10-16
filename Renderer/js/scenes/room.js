// "Listening Room" (afternoon sun through a window) and "After Hours"
// (lamp-lit, late night): a front-on desk scene with the turntable, the
// current album on a stand and a stack of recently played sleeves.
import * as THREE from 'three';
import { BaseScene, setShiftedFrustum } from './base.js';
import { createTurntable } from '../models/turntable.js';
import { createAlbumStand, createRecordStack, createLamp, createFrame, contactPlane } from '../models/props.js';
import { windowGobo, haloTexture } from '../textures.js';
import { texture } from '../assets.js';

const FRAMINGS = {
  // focus point, horizontal span at focus depth (m), elevation (deg), focus
  // height on screen (0 = top), distance factor
  wide: { focus: [0.04, 0.06, -0.08], span: 1.5, elevation: 27, screenY: 0.6, k: 1.3 },
  mid: { focus: [0.0, 0.07, -0.07], span: 1.02, elevation: 27, screenY: 0.58, k: 1.3 },
  close: { focus: [-0.03, 0.08, -0.06], span: 0.64, elevation: 30, screenY: 0.55, k: 1.35 },
};

// Blend the presets: size 0 = wide, 0.5 = mid, 1 = close.
function framingAt(size) {
  const [a, b, t] = size <= 0.5 ? [FRAMINGS.wide, FRAMINGS.mid, size / 0.5] : [FRAMINGS.mid, FRAMINGS.close, (size - 0.5) / 0.5];
  const mix = (x, y) => x + (y - x) * t;
  return {
    focus: a.focus.map((v, i) => mix(v, b.focus[i])),
    span: Math.exp(mix(Math.log(a.span), Math.log(b.span))), // zoom feels linear in log space
    elevation: mix(a.elevation, b.elevation),
    screenY: mix(a.screenY, b.screenY),
    k: mix(a.k, b.k),
  };
}

const VARIANTS = {
  'listening-room': {
    wall: 0xf0e2cc,
    desk: 0xf4e4d4,
    art: 'art/hiroshige_ryogoku.jpg',
    artAspect: 1400 / 891,
    lampLit: false,
    exposure: 1.0,
    env: 0.35,
  },
  'after-hours': {
    wall: 0xe7cbb0,
    desk: 0xd2b49c,
    art: 'art/roesen_still_life.jpg',
    artAspect: 1400 / 1122,
    lampLit: true,
    exposure: 1.0,
    env: 0.06,
  },
};

export class RoomScene extends BaseScene {
  constructor(ctx, options) {
    super(ctx, options);
    const variant = (this.variant = VARIANTS[options.scene] || VARIANTS['listening-room']);
    this.isNight = variant.lampLit;
    this.scene.environmentIntensity = variant.env;
    this.camera = new THREE.PerspectiveCamera();
    this.time = 0;

    // ---- Room shell --------------------------------------------------------
    const room = (this.room = new THREE.Group());
    this.scene.add(room);
    const deskMat = new THREE.MeshStandardMaterial({
      map: texture('textures/desk_wood.jpg', { repeat: [3, 0.9] }),
      roughnessMap: texture('textures/desk_wood_rough.jpg', { srgb: false, repeat: [3, 0.9] }),
      normalMap: texture('textures/desk_wood_normal.jpg', { srgb: false, repeat: [3, 0.9] }),
      normalScale: new THREE.Vector2(0.4, 0.4),
      color: variant.desk,
      roughness: 0.9,
    });
    const desk = new THREE.Mesh(new THREE.BoxGeometry(3.6, 0.04, 1.05), deskMat);
    desk.position.set(0, -0.02, -0.03);
    desk.receiveShadow = true;
    room.add(desk);
    const wallMat = new THREE.MeshStandardMaterial({
      map: texture('textures/wall_plaster.jpg', { repeat: [4, 2] }),
      color: variant.wall,
      roughness: 0.95,
    });
    const wall = new THREE.Mesh(new THREE.PlaneGeometry(7, 4), wallMat);
    wall.position.set(0, 1.5, -0.56);
    wall.receiveShadow = true;
    room.add(wall);
    // Floor far below the desk edge (only seen in tall framings)
    const frame = createFrame(variant.art, variant.artAspect, {
      width: variant.lampLit ? 0.5 : 0.56,
      frameColor: variant.lampLit ? 0x3a2414 : 0x6b4528,
    });
    frame.group.position.set(0.15, variant.lampLit ? 0.52 : 0.5, -0.555);
    room.add(frame.group);
    this.frame = frame;

    // Transparent mode: only shadows are drawn under the objects.
    this.shadowCatcher = new THREE.Mesh(
      new THREE.PlaneGeometry(4, 2).rotateX(-Math.PI / 2),
      new THREE.ShadowMaterial({ opacity: variant.lampLit ? 0.45 : 0.32 })
    );
    this.shadowCatcher.position.y = 0.0002;
    this.shadowCatcher.receiveShadow = true;
    this.scene.add(this.shadowCatcher);

    // ---- Objects -------------------------------------------------------------
    const tt = (this.turntable = createTurntable({ style: 'cream', envMap: ctx.envMap, recordReflections: variant.env }));
    tt.group.position.set(0, 0, -0.06);
    this.scene.add(tt.group);
    const ttShadow = contactPlane('rect', 0.6, 0.5, 0.55);
    ttShadow.position.set(0, 0.0003, -0.06);
    this.scene.add(ttShadow);

    const stand = (this.stand = createAlbumStand({ envMap: ctx.envMap }));
    stand.group.position.set(-0.445, 0, -0.17);
    stand.group.rotation.y = 0.1;
    this.scene.add(stand.group);

    const stack = (this.stack = createRecordStack(5, { envMap: ctx.envMap }));
    stack.group.position.set(0.48, 0, 0.0);
    stack.group.rotation.y = -0.04;
    this.scene.add(stack.group);

    const lamp = (this.lamp = createLamp({ lit: variant.lampLit }));
    lamp.group.position.set(0.66, 0, -0.37);
    this.scene.add(lamp.group);

    this.#buildLights();
    this.setBackground(options.background !== false);
    this.layout();
  }

  #buildLights() {
    const v = this.variant;
    const scene = this.scene;
    if (!v.lampLit) {
      // Low afternoon sun through a window on the left, casting the frame and
      // a plant onto the wall and desk.
      const sun = new THREE.SpotLight(0xffd7a3, 7.5, 0, 0.42, 0.35, 0);
      sun.position.set(-2.4, 1.85, 1.3);
      sun.target.position.set(0.1, 0.3, -0.56);
      sun.map = windowGobo();
      sun.castShadow = true;
      sun.shadow.mapSize.set(2048, 2048);
      sun.shadow.bias = -0.0004;
      sun.shadow.normalBias = 0.015;
      sun.shadow.camera.near = 1;
      sun.shadow.camera.far = 6;
      scene.add(sun, sun.target);
      this.sun = sun;
      this.sunBase = sun.position.clone();
      this.swayClock = 0;
      const hemi = new THREE.HemisphereLight(0xf7ead8, 0x6a4630, 0.85);
      scene.add(hemi);
      const fill = new THREE.DirectionalLight(0xfff0dd, 0.35);
      fill.position.set(1.5, 1.2, 2.0);
      scene.add(fill);
    } else {
      const lampPos = this.lamp.group.position.clone().add(this.lamp.bulbPosition);
      const bulb = new THREE.PointLight(0xff9b4f, 1.15, 0, 2);
      bulb.position.copy(lampPos).add(new THREE.Vector3(0, 0.02, 0));
      bulb.castShadow = true;
      bulb.shadow.mapSize.set(1024, 1024);
      bulb.shadow.bias = -0.002;
      bulb.shadow.normalBias = 0.02;
      bulb.shadow.camera.near = 0.03;
      scene.add(bulb);
      this.bulb = bulb;
      // Warm wash from a second lamp just off-screen to the left.
      const left = new THREE.SpotLight(0xff8a3c, 3.2, 0, 0.55, 1, 0);
      left.position.set(-1.7, 0.32, 0.25);
      left.target.position.set(-0.75, 0.22, -0.56);
      scene.add(left, left.target);
      // LED strip glow behind the frame
      const halo = new THREE.Mesh(
        new THREE.PlaneGeometry(this.frame.width * 1.9, this.frame.height * 2.1),
        new THREE.MeshBasicMaterial({
          map: haloTexture(),
          transparent: true,
          opacity: 0.55,
          blending: THREE.AdditiveBlending,
          depthWrite: false,
        })
      );
      halo.position.copy(this.frame.group.position).add(new THREE.Vector3(0, 0, 0.002));
      halo.renderOrder = -1;
      this.room.add(halo);
      this.halo = halo;
      const back = new THREE.PointLight(0xff9a5a, 0.06, 0, 2);
      back.position.copy(this.frame.group.position).add(new THREE.Vector3(0, 0.1, 0.01));
      this.room.add(back);
      const hemi = new THREE.HemisphereLight(0x5b5a78, 0x2a1a10, 0.22);
      scene.add(hemi);
      // A gentle cool key so the turntable reads in the dark
      const key = new THREE.DirectionalLight(0xffc9a0, 0.18);
      key.position.set(-0.5, 1.5, 2);
      scene.add(key);
    }
  }

  setBackground(on) {
    super.setBackground(on);
    this.room.visible = on;
    this.shadowCatcher.visible = !on;
    if (this.halo) this.halo.visible = on;
    this.shadowsDirty = true;
  }

  setTrackArt(tex, immediate) {
    super.setTrackArt(tex, immediate);
    this.stand.sleeve.setArt(tex, immediate);
  }

  setRecentArt(textures, immediate) {
    this.stack.setArt(textures, immediate);
    this.shadowsDirty = true;
  }

  layout() {
    const f = framingAt(this.size);
    const aspect = this.width / this.height || 16 / 10;
    let span = f.span;
    // On narrow/portrait screens make sure the turntable still fits.
    if (aspect < 1.2) span *= 1.2 / aspect;
    const dz = span * f.k;
    const tanA = Math.tan((f.elevation * Math.PI) / 180);
    const dy = dz * tanA;
    const [fx, fy, fz] = f.focus;
    this.camera.position.set(fx, fy + dy, fz + dz);
    this.camera.rotation.set(0, 0, 0);
    const tanHalfWidth = span / 2 / dz;
    const tanHalfHeight = tanHalfWidth / aspect;
    const shift = -tanA - (0.5 - f.screenY) * 2 * tanHalfHeight;
    setShiftedFrustum(this.camera, { tanHalfWidth, aspect, shift });
  }

  update(dt, time, player) {
    super.update(dt, time, player);
    this.stand.sleeve.update(dt);
    this.stack.update(dt);
    this.time += dt;
    if (this.sun && this.options.motion !== false) {
      // Leaves swaying in a breeze: nudge the sun a few millimetres. Shadow
      // maps are refreshed at ~12 Hz, which is plenty for motion this slow.
      this.swayClock += dt;
      if (this.swayClock > 1 / 12) {
        this.swayClock = 0;
        const t = this.time;
        const sway = Math.sin(t * 0.23) * 0.6 + Math.sin(t * 0.61 + 1.3) * 0.3 + Math.sin(t * 1.37) * 0.1;
        this.sun.position.set(this.sunBase.x, this.sunBase.y + sway * 0.012, this.sunBase.z + sway * 0.02);
        this.shadowsDirty = true;
      }
    }
    if (this.bulb) {
      // Faint filament breathing
      const flicker = 1 + Math.sin(this.time * 1.7) * 0.012 + Math.sin(this.time * 4.3) * 0.006;
      this.bulb.intensity = 1.15 * flicker;
    }
  }
}
