// "Turntable": the original top-down view. A brushed-silver deck and the
// current album's sleeve on a sunlit wooden desk, striped by window blinds.
import * as THREE from 'three';
import { BaseScene } from './base.js';
import { createTurntable } from '../models/turntable.js';
import { createSleeve, contactPlane, SLEEVE } from '../models/props.js';
import { blindsGobo } from '../textures.js';
import { texture } from '../assets.js';

// Fraction of the screen width the deck + sleeve occupy at size 0 … 1.
const MIN_FRACTION = 0.28;
const MAX_FRACTION = 0.88;
const CONTENT_W = 0.46 + SLEEVE - 0.03;
const CONTENT_D = 0.4;

export class TopDownScene extends BaseScene {
  constructor(ctx, options) {
    super(ctx, options);
    this.scene.environmentIntensity = 0.45;
    this.camera = new THREE.PerspectiveCamera(18, 1, 0.1, 20);
    this.time = 0;

    const room = (this.room = new THREE.Group());
    this.scene.add(room);
    const deskMat = new THREE.MeshStandardMaterial({
      map: texture('textures/desk_wood.jpg', { repeat: [2.2, 2.2] }),
      roughnessMap: texture('textures/desk_wood_rough.jpg', { srgb: false, repeat: [2.2, 2.2] }),
      normalMap: texture('textures/desk_wood_normal.jpg', { srgb: false, repeat: [2.2, 2.2] }),
      normalScale: new THREE.Vector2(0.35, 0.35),
      color: 0xffe2c4,
      roughness: 0.85,
    });
    const desk = new THREE.Mesh(new THREE.PlaneGeometry(5, 5).rotateX(-Math.PI / 2), deskMat);
    desk.rotation.y = 0.12; // grain runs slightly off-axis, like a real desk shot
    desk.receiveShadow = true;
    room.add(desk);

    this.shadowCatcher = new THREE.Mesh(
      new THREE.PlaneGeometry(5, 5).rotateX(-Math.PI / 2),
      new THREE.ShadowMaterial({ opacity: 0.38 })
    );
    this.shadowCatcher.position.y = 0.0002;
    this.shadowCatcher.receiveShadow = true;
    this.scene.add(this.shadowCatcher);

    const content = (this.content = new THREE.Group());
    this.scene.add(content);
    const tt = (this.turntable = createTurntable({
      style: 'silver',
      envMap: ctx.envMap,
      recordReflections: 0.12,
      recordRoughness: 0.9,
      recordAnisotropy: 0.45,
      recordSpecular: 0.25,
    }));
    tt.group.position.set(CONTENT_W / 2 - 0.23, 0, 0);
    content.add(tt.group);
    const ttShadow = contactPlane('rect', 0.6, 0.54, 0.5);
    ttShadow.position.copy(tt.group.position);
    ttShadow.position.y = 0.0003;
    content.add(ttShadow);

    const sleeve = (this.sleeve = createSleeve({ thickness: 0.004, gloss: 0.5, envMap: ctx.envMap }));
    sleeve.group.position.set(-CONTENT_W / 2 + SLEEVE / 2, 0, 0.012);
    sleeve.group.rotation.y = 0.035;
    content.add(sleeve.group);
    const sleeveShadow = contactPlane('rect', SLEEVE + 0.08, SLEEVE + 0.08, 0.35);
    sleeveShadow.position.copy(sleeve.group.position);
    sleeveShadow.position.y = 0.0003;
    content.add(sleeveShadow);

    // Sun through blinds: a distant spot so rays are nearly parallel.
    const sun = new THREE.SpotLight(0xffd9a8, 9, 0, 0.3, 0.5, 0);
    sun.position.set(-2.6, 6.5, -1.6);
    sun.target.position.set(0.1, 0, 0.15);
    sun.map = blindsGobo();
    sun.castShadow = true;
    sun.shadow.mapSize.set(2048, 2048);
    sun.shadow.bias = -0.0003;
    sun.shadow.normalBias = 0.01;
    sun.shadow.camera.near = 3;
    sun.shadow.camera.far = 10;
    this.scene.add(sun, sun.target);
    this.sun = sun;
    this.scene.add(new THREE.HemisphereLight(0xfff1de, 0x7a4a26, 0.9));
    const fill = new THREE.DirectionalLight(0xffffff, 0.25);
    fill.position.set(1, 3, 2);
    this.scene.add(fill);

    this.setBackground(options.background !== false);
    this.layout();
  }

  setBackground(on) {
    super.setBackground(on);
    this.room.visible = on;
    this.shadowCatcher.visible = !on;
    this.shadowsDirty = true;
  }

  setTrackArt(tex, immediate) {
    super.setTrackArt(tex, immediate);
    this.sleeve.setArt(tex, immediate);
  }

  // The 1.0 presets filled 50 / 66 / 84 % of the width.
  get framingSizes() {
    return { wide: 0.37, mid: 0.63, close: 0.93 };
  }

  layout() {
    const aspect = this.width / this.height || 16 / 10;
    const fraction = MIN_FRACTION + (MAX_FRACTION - MIN_FRACTION) * this.size;
    // Visible width at desk level so the content takes `fraction` of it,
    // but never let the content overflow vertically.
    let visibleW = CONTENT_W / fraction;
    const visibleH = visibleW / aspect;
    if (CONTENT_D / visibleH > 0.86) visibleW = (CONTENT_D / 0.86) * aspect;
    const vfov = this.camera.fov * (Math.PI / 180);
    const h = visibleW / aspect / 2 / Math.tan(vfov / 2);
    this.camera.aspect = aspect;
    this.camera.position.set(0, h, 0.0001);
    this.camera.up.set(0, 0, -1);
    this.camera.lookAt(0, 0, 0);
    this.camera.updateProjectionMatrix();
  }

  update(dt, time, player) {
    super.update(dt, time, player);
    this.sleeve.update(dt);
  }
}
