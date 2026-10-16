// Desk props: album stand, sleeves, recently-played stack, lamp and wall frame.
import * as THREE from 'three';
import { roundedBox } from './turntable.js';
import { contactShadow, ribbedNormal, glowTexture, grainTexture } from '../textures.js';
import { texture } from '../assets.js';
import { rng, TAU } from '../util.js';

export const SLEEVE = 0.314;

const paper = () =>
  new THREE.MeshStandardMaterial({ color: 0xf2eee6, roughness: 0.85, bumpMap: grainTexture(), bumpScale: 0.3 });

// A record sleeve with artwork on the front face; two stacked front layers
// let new artwork cross-fade in.
export function createSleeve({ thickness = 0.0032, gloss = 0.55, envMap = null } = {}) {
  const group = new THREE.Group();
  const body = new THREE.Mesh(new THREE.BoxGeometry(SLEEVE, thickness, SLEEVE), paper());
  body.position.y = thickness / 2;
  body.castShadow = true;
  body.receiveShadow = true;
  group.add(body);
  const faceGeo = new THREE.PlaneGeometry(SLEEVE - 0.0006, SLEEVE - 0.0006);
  faceGeo.rotateX(-Math.PI / 2);
  const faces = [0, 1].map((i) => {
    const m = new THREE.Mesh(
      faceGeo,
      new THREE.MeshStandardMaterial({
        roughness: gloss,
        // Printed card barely reflects; keeps dark covers from washing out.
        envMap,
        envMapIntensity: 0.12,
        transparent: true,
        opacity: 0,
        polygonOffset: true,
        polygonOffsetFactor: -1 - i,
        polygonOffsetUnits: -1 - i,
      })
    );
    m.position.y = thickness + 0.0001;
    m.receiveShadow = true;
    m.visible = false;
    group.add(m);
    return m;
  });
  let front = 0;
  return {
    group,
    setArt(tex, immediate = false) {
      if (faces[front].material.map === tex && faces[front].visible) return;
      const next = faces[1 - front];
      next.material.map = tex;
      next.material.needsUpdate = true;
      next.material.opacity = immediate ? 1 : 0;
      next.visible = true;
      next.renderOrder = 2;
      faces[front].renderOrder = 1;
      if (immediate) faces[front].visible = false;
      front = 1 - front;
    },
    update(dt) {
      const cur = faces[front];
      if (cur.material.opacity < 1) {
        cur.material.opacity = Math.min(1, cur.material.opacity + dt / 0.6);
        if (cur.material.opacity >= 1) faces[1 - front].visible = false;
      }
    },
  };
}

// Wooden display ledge holding the current album upright.
export function createAlbumStand({ envMap = null } = {}) {
  const group = new THREE.Group();
  const wood = new THREE.MeshStandardMaterial({
    map: texture('textures/walnut.jpg'),
    color: 0xd9a676,
    roughness: 0.45,
  });
  const base = new THREE.Mesh(roundedBox(SLEEVE + 0.03, 0.026, 0.072, 0.004, 0.002), wood);
  base.castShadow = base.receiveShadow = true;
  group.add(base);
  const lip = new THREE.Mesh(roundedBox(SLEEVE + 0.03, 0.012, 0.012, 0.002, 0.0015), wood);
  lip.position.set(0, 0.026, 0.026);
  lip.castShadow = lip.receiveShadow = true;
  group.add(lip);
  const sleeve = createSleeve({ thickness: 0.003, gloss: 0.42, envMap });
  // Stand it up, leaning back slightly against the slot.
  sleeve.group.rotation.x = Math.PI / 2 - 0.1;
  // Art faces +Z (toward the camera); the bottom edge rests in the slot.
  sleeve.group.position.set(0, 0.022 + (SLEEVE / 2) * Math.cos(0.1), -0.002 - (SLEEVE / 2) * Math.sin(0.1));
  group.add(sleeve.group);
  const shadow = contactPlane('rect', SLEEVE + 0.08, 0.14, 0.55);
  shadow.position.set(0, 0.0004, 0.0);
  group.add(shadow);
  return { group, sleeve };
}

// Recently played stack: up to five sleeves lying on the desk.
export function createRecordStack(count = 5, { seed = 9, envMap = null } = {}) {
  const group = new THREE.Group();
  const rand = rng(seed);
  const sleeves = [];
  for (let i = 0; i < count; i++) {
    const s = createSleeve({ thickness: 0.0036, gloss: 0.5, envMap });
    s.group.position.set((rand() - 0.5) * 0.02, i * 0.0042, (rand() - 0.5) * 0.02);
    s.group.rotation.y = (rand() - 0.5) * 0.16;
    s.group.visible = false;
    group.add(s.group);
    sleeves.push(s);
  }
  // Inner paper sleeves peeking out underneath
  const inner = new THREE.Mesh(new THREE.BoxGeometry(SLEEVE - 0.004, 0.002, SLEEVE - 0.004), paper());
  inner.position.set(-0.008, 0.001, 0.012);
  inner.rotation.y = 0.07;
  inner.castShadow = inner.receiveShadow = true;
  group.add(inner);
  const shadow = contactPlane('rect', SLEEVE + 0.1, SLEEVE + 0.1, 0.5);
  shadow.position.y = 0.0003;
  group.add(shadow);
  return {
    group,
    // textures[0] is the most recent and sits on top.
    setArt(textures, immediate = false) {
      const n = Math.min(textures.length, count);
      sleeves.forEach((s, i) => {
        const idx = n - 1 - i; // bottom sleeve = oldest
        if (i < n) {
          s.group.visible = true;
          s.setArt(textures[idx], immediate);
        } else {
          s.group.visible = false;
        }
      });
    },
    update(dt) {
      sleeves.forEach((s) => s.update(dt));
    },
  };
}

// Brass table lamp with a ribbed glass dome.
export function createLamp({ lit = false } = {}) {
  const group = new THREE.Group();
  const brass = new THREE.MeshStandardMaterial({ color: 0xb8925a, metalness: 1, roughness: 0.3 });
  const baseProfile = [
    [0, 0],
    [0.066, 0],
    [0.07, 0.004],
    [0.068, 0.012],
    [0.05, 0.022],
    [0.016, 0.03],
    [0.011, 0.04],
    [0.0, 0.04],
  ].map(([x, y]) => new THREE.Vector2(x, y));
  const base = new THREE.Mesh(new THREE.LatheGeometry(baseProfile, 64), brass);
  base.castShadow = base.receiveShadow = true;
  group.add(base);
  const stem = new THREE.Mesh(new THREE.CylinderGeometry(0.0085, 0.0085, 0.13, 24), brass);
  stem.position.y = 0.04 + 0.065;
  stem.castShadow = true;
  group.add(stem);
  const socket = new THREE.Mesh(new THREE.CylinderGeometry(0.016, 0.014, 0.03, 24), brass);
  socket.position.y = 0.17;
  socket.castShadow = true;
  group.add(socket);
  const bulb = new THREE.Mesh(
    new THREE.SphereGeometry(0.03, 32, 16),
    new THREE.MeshStandardMaterial({
      color: lit ? 0xfff3df : 0xf4efe6,
      emissive: lit ? 0xffc27a : 0x000000,
      emissiveIntensity: lit ? 6 : 0,
      roughness: 0.3,
    })
  );
  bulb.position.y = 0.215;
  group.add(bulb);

  // Dome: cylinder rising into a rounded cap, open at the bottom.
  const R = 0.088;
  const H = 0.25;
  const pts = [];
  pts.push(new THREE.Vector2(R * 0.96, 0.0));
  pts.push(new THREE.Vector2(R, 0.012));
  for (let i = 0; i <= 10; i++) pts.push(new THREE.Vector2(R, 0.012 + (H - R - 0.012) * (i / 10)));
  for (let i = 1; i <= 16; i++) {
    const a = (i / 16) * (Math.PI / 2);
    pts.push(new THREE.Vector2(Math.cos(a) * R, H - R + Math.sin(a) * R));
  }
  const shadeGeo = new THREE.LatheGeometry(pts, 96);
  const ribs = ribbedNormal(40);
  const shadeMat = new THREE.MeshPhysicalMaterial({
    color: lit ? 0xffe3bf : 0xd8cbb8,
    emissive: lit ? 0xff9a45 : 0x000000,
    emissiveIntensity: lit ? 1.6 : 0,
    roughness: 0.35,
    metalness: 0,
    transparent: true,
    opacity: lit ? 0.9 : 0.62,
    normalMap: ribs,
    normalScale: new THREE.Vector2(0.9, 0.9),
    clearcoat: 0.6,
    clearcoatRoughness: 0.2,
    side: THREE.DoubleSide,
    depthWrite: false,
  });
  const shade = new THREE.Mesh(shadeGeo, shadeMat);
  shade.position.y = 0.12;
  shade.renderOrder = 5;
  group.add(shade);
  // Cable trailing off to the right
  const cablePath = new THREE.CatmullRomCurve3([
    new THREE.Vector3(0.06, 0.006, 0.0),
    new THREE.Vector3(0.14, 0.004, 0.03),
    new THREE.Vector3(0.3, 0.004, 0.02),
    new THREE.Vector3(0.6, 0.004, -0.04),
  ]);
  const cable = new THREE.Mesh(
    new THREE.TubeGeometry(cablePath, 48, 0.0035, 8, false),
    new THREE.MeshStandardMaterial({ color: 0x151515, roughness: 0.6 })
  );
  cable.castShadow = true;
  group.add(cable);
  const shadow = contactPlane('round', 0.2, 0.2, 0.6);
  shadow.position.y = 0.0004;
  group.add(shadow);

  let glow = null;
  if (lit) {
    glow = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: glowTexture(256, '255,176,96'),
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        transparent: true,
        opacity: 0.55,
      })
    );
    glow.scale.set(0.75, 0.75, 1);
    glow.position.y = 0.22;
    glow.renderOrder = 6;
    group.add(glow);
  }
  return { group, bulbPosition: new THREE.Vector3(0, 0.215, 0), shade, glow };
}

// Framed print on the wall: frame, mat, art.
export function createFrame(artPath, artAspect, { width = 0.62, mat = 0.05, frame = 0.022, depth = 0.026, frameColor = 0x5a3b22 } = {}) {
  const group = new THREE.Group();
  const artW = width - 2 * mat - 2 * frame;
  const artH = artW / artAspect;
  const height = artH + 2 * mat + 2 * frame;
  const frameMat = new THREE.MeshStandardMaterial({
    map: texture('textures/walnut.jpg'),
    color: frameColor,
    roughness: 0.5,
  });
  const bars = [
    [width, frame, 0, height / 2 - frame / 2],
    [width, frame, 0, -height / 2 + frame / 2],
    [frame, height - 2 * frame, -width / 2 + frame / 2, 0],
    [frame, height - 2 * frame, width / 2 - frame / 2, 0],
  ];
  for (const [w, h, x, y] of bars) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, depth), frameMat);
    m.position.set(x, y, depth / 2);
    m.castShadow = true;
    m.receiveShadow = true;
    group.add(m);
  }
  const matBoard = new THREE.Mesh(
    new THREE.PlaneGeometry(width - 2 * frame, height - 2 * frame),
    new THREE.MeshStandardMaterial({ color: 0xf1ebe0, roughness: 0.95 })
  );
  matBoard.position.z = 0.006;
  matBoard.receiveShadow = true;
  group.add(matBoard);
  const art = new THREE.Mesh(
    new THREE.PlaneGeometry(artW, artH),
    new THREE.MeshStandardMaterial({ map: texture(artPath), roughness: 0.8 })
  );
  art.position.z = 0.0065;
  art.receiveShadow = true;
  group.add(art);
  // Glass glare
  const glass = new THREE.Mesh(
    new THREE.PlaneGeometry(width - 2 * frame, height - 2 * frame),
    new THREE.MeshPhysicalMaterial({
      color: 0xffffff,
      roughness: 0.05,
      metalness: 0,
      transparent: true,
      opacity: 0.06,
      depthWrite: false,
    })
  );
  glass.position.z = depth - 0.004;
  group.add(glass);
  return { group, width, height };
}

// Soft multiply-style contact shadow plane lying on y=0.
export function contactPlane(kind, w, d, opacity = 0.5) {
  const m = new THREE.Mesh(
    new THREE.PlaneGeometry(w, d).rotateX(-Math.PI / 2),
    new THREE.MeshBasicMaterial({
      color: 0x000000,
      alphaMap: contactShadow(kind),
      transparent: true,
      opacity,
      depthWrite: false,
      polygonOffset: true,
      polygonOffsetFactor: -1,
      polygonOffsetUnits: -1,
    })
  );
  m.renderOrder = 1;
  m.userData.contactShadow = true;
  return m;
}

export const TWO_PI = TAU;
