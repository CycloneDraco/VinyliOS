// A parametric turntable: plinth, platter, record, label art, and a tonearm
// that cues onto the record and tracks inward with song progress.
import * as THREE from 'three';
import { clamp, lerp, TAU } from '../util.js';
import {
  recordTextures,
  pictureDiscOverlay,
  grainTexture,
  brushedMetal,
  nameplateTexture,
  RECORD_RADIUS,
  LABEL_RADIUS,
} from '../textures.js';
import { texture } from '../assets.js';

const RPM = 100 / 3;
const OMEGA = (RPM / 60) * TAU;

// Flat discs lying in XZ: u runs along +X, v along -Z. Explicit tangents keep
// the anisotropic groove sheen stable; deriving them from screen-space
// derivatives loses precision on some GPUs when the camera is far away.
function withFlatTangents(geo) {
  const count = geo.attributes.position.count;
  const tangents = new Float32Array(count * 4);
  for (let i = 0; i < count; i++) {
    tangents[i * 4] = 1;
    tangents[i * 4 + 3] = 1;
  }
  geo.setAttribute('tangent', new THREE.BufferAttribute(tangents, 4));
  return geo;
}

export function roundedRectShape(w, d, r) {
  const s = new THREE.Shape();
  const x = -w / 2;
  const y = -d / 2;
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y);
  s.quadraticCurveTo(x + w, y, x + w, y + r);
  s.lineTo(x + w, y + d - r);
  s.quadraticCurveTo(x + w, y + d, x + w - r, y + d);
  s.lineTo(x + r, y + d);
  s.quadraticCurveTo(x, y + d, x, y + d - r);
  s.lineTo(x, y + r);
  s.quadraticCurveTo(x, y, x + r, y);
  return s;
}

// Rounded box sitting on y=0, with soft bevelled edges.
export function roundedBox(w, h, d, r, bevel = 0.003, curveSegments = 10) {
  const shape = roundedRectShape(w - bevel * 2, d - bevel * 2, Math.max(0.0005, r - bevel));
  const geo = new THREE.ExtrudeGeometry(shape, {
    depth: Math.max(0.0001, h - bevel * 2),
    bevelEnabled: bevel > 0,
    bevelThickness: bevel,
    bevelSize: bevel,
    bevelSegments: 4,
    curveSegments,
  });
  geo.rotateX(-Math.PI / 2);
  geo.translate(0, bevel, 0);
  // Planar UVs from the top so textures map like a sheet of material.
  const pos = geo.attributes.position;
  const uv = geo.attributes.uv;
  for (let i = 0; i < pos.count; i++) {
    uv.setXY(i, pos.getX(i) / w + 0.5, -pos.getZ(i) / d + 0.5);
  }
  geo.computeVertexNormals();
  return geo;
}

function shadowed(mesh, cast = true, receive = true) {
  mesh.castShadow = cast;
  mesh.receiveShadow = receive;
  return mesh;
}

export function createTurntable(options = {}) {
  const style = options.style || 'cream'; // 'cream' | 'silver' | 'none'
  const labelStyle = options.labelStyle || 'label'; // 'label' | 'picture'
  const group = new THREE.Group();
  group.name = 'turntable';

  // ---- Materials -----------------------------------------------------------
  const grain = grainTexture();
  const mats = {
    cream: new THREE.MeshStandardMaterial({
      color: 0xe8e1d3,
      roughness: 0.62,
      bumpMap: grain,
      bumpScale: 0.15,
    }),
    silverTop: new THREE.MeshStandardMaterial({
      map: brushedMetal(1024, [200, 195, 184]),
      color: 0xe6e1d8,
      roughness: 0.45,
      metalness: 0.5,
    }),
    wood: new THREE.MeshStandardMaterial({
      map: texture('textures/walnut.jpg'),
      color: 0xd6a274,
      roughness: 0.48,
    }),
    platter: new THREE.MeshStandardMaterial({ color: 0xbfc0bf, metalness: 1, roughness: 0.32 }),
    platterDark: new THREE.MeshStandardMaterial({ color: 0x1a1a1a, roughness: 0.6 }),
    chrome: new THREE.MeshStandardMaterial({ color: 0xf0f0f0, metalness: 1, roughness: 0.14 }),
    satin: new THREE.MeshStandardMaterial({ color: 0xc8c8c6, metalness: 1, roughness: 0.28 }),
    black: new THREE.MeshStandardMaterial({ color: 0x151515, roughness: 0.42 }),
    rubber: new THREE.MeshStandardMaterial({ color: 0x0c0c0c, roughness: 0.85 }),
    brass: new THREE.MeshStandardMaterial({ color: 0xc19a55, metalness: 1, roughness: 0.32 }),
    bronze: new THREE.MeshStandardMaterial({ color: 0x6b4a2c, metalness: 0.85, roughness: 0.38 }),
    cartridge: new THREE.MeshStandardMaterial({ color: 0xd5832a, roughness: 0.45 }),
  };
  const rec = recordTextures();
  const recordMat = new THREE.MeshPhysicalMaterial({
    color: 0xffffff,
    map: rec.map,
    roughness: options.recordRoughness ?? 1,
    roughnessMap: rec.roughnessMap,
    metalness: 0,
    anisotropy: options.recordAnisotropy ?? 0.9,
    anisotropyMap: rec.anisotropyMap,
    clearcoat: 0.35,
    clearcoatRoughness: 0.28,
    specularIntensity: options.recordSpecular ?? 1,
    ior: 1.55,
    // An explicit envMap lets the record reflect less than the rest of the
    // scene (scene.environmentIntensity would otherwise override this).
    envMap: options.envMap || null,
    envMapIntensity: options.recordReflections ?? 0.35,
  });

  // ---- Plinth --------------------------------------------------------------
  let W = 0.46;
  let D = 0.36;
  let topY = 0;
  let platterCenter = new THREE.Vector3(-0.055, 0, 0.0);
  let pivot = new THREE.Vector3(0.165, 0, -0.1);
  const plinth = new THREE.Group();
  group.add(plinth);
  let nameplate = null;

  if (style === 'cream') {
    const feetH = 0.006;
    const woodH = 0.046;
    const creamH = 0.03;
    for (const [fx, fz] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) {
      const foot = new THREE.Mesh(new THREE.CylinderGeometry(0.016, 0.018, feetH, 20), mats.rubber);
      foot.position.set(fx * (W / 2 - 0.04), feetH / 2, fz * (D / 2 - 0.04));
      plinth.add(shadowed(foot));
    }
    const wood = new THREE.Mesh(roundedBox(W, woodH, D, 0.012, 0.004), mats.wood);
    wood.position.y = feetH;
    plinth.add(shadowed(wood));
    const cream = new THREE.Mesh(roundedBox(W - 0.004, creamH, D - 0.004, 0.012, 0.005), mats.cream);
    cream.position.y = feetH + woodH - 0.001;
    plinth.add(shadowed(cream));
    topY = feetH + woodH + creamH - 0.001;
    // Engraved name strip on the wooden front.
    nameplate = new THREE.Mesh(
      new THREE.PlaneGeometry(0.16, 0.025),
      new THREE.MeshStandardMaterial({ transparent: true, roughness: 0.6, color: 0xffffff, depthWrite: false })
    );
    nameplate.position.set(-0.07, feetH + woodH * 0.5, D / 2 + 0.0002);
    nameplate.userData.engraved = true;
    plinth.add(nameplate);
    // Knob + power light on the top plate
    const knob = new THREE.Mesh(new THREE.CylinderGeometry(0.011, 0.012, 0.012, 32), mats.brass);
    // Knob and power light sit left of the arm rest so the parked arm clears them.
    knob.position.set(0.105, topY + 0.006, 0.135);
    plinth.add(shadowed(knob));
    const led = new THREE.Mesh(new THREE.CylinderGeometry(0.0035, 0.0035, 0.002, 16), mats.black);
    led.position.set(0.075, topY + 0.001, 0.138);
    plinth.add(led);
  } else if (style === 'silver') {
    W = 0.46;
    D = 0.4;
    const h = 0.06;
    const body = new THREE.Mesh(roundedBox(W, h, D, 0.026, 0.006, 16), mats.silverTop);
    plinth.add(shadowed(body));
    topY = h;
    platterCenter = new THREE.Vector3(-0.04, 0, 0.0);
    pivot = new THREE.Vector3(0.175, 0, -0.125);
    // Recessed dark well around the platter
    const well = new THREE.Mesh(new THREE.RingGeometry(RECORD_RADIUS + 0.006, RECORD_RADIUS + 0.014, 96), mats.platterDark);
    well.rotation.x = -Math.PI / 2;
    well.position.set(platterCenter.x, topY + 0.0004, platterCenter.z);
    plinth.add(well);
    // Big bronze speed knob, bottom right
    const knob = new THREE.Mesh(new THREE.CylinderGeometry(0.026, 0.028, 0.018, 48), mats.bronze);
    knob.position.set(0.098, topY + 0.009, 0.15);
    plinth.add(shadowed(knob));
    const knobCap = new THREE.Mesh(new THREE.CylinderGeometry(0.02, 0.024, 0.006, 48), mats.bronze);
    knobCap.position.set(0.098, topY + 0.021, 0.15);
    plinth.add(shadowed(knobCap));
    // Badge, bottom left
    nameplate = new THREE.Mesh(
      new THREE.PlaneGeometry(0.085, 0.014),
      new THREE.MeshStandardMaterial({ roughness: 0.5, color: 0xffffff })
    );
    nameplate.rotation.x = -Math.PI / 2;
    nameplate.position.set(-W / 2 + 0.065, topY + 0.0006, D / 2 - 0.025);
    plinth.add(nameplate);
  } else {
    W = RECORD_RADIUS * 2;
    D = RECORD_RADIUS * 2;
    platterCenter = new THREE.Vector3(0, 0, 0);
    pivot = new THREE.Vector3(0.19, 0, -0.075);
    topY = 0;
  }

  // ---- Platter + record ----------------------------------------------------
  const platterH = style === 'none' ? 0.004 : 0.022;
  const platterY = topY + (style === 'none' ? 0 : 0.003);
  const spin = new THREE.Group();
  spin.position.set(platterCenter.x, platterY, platterCenter.z);
  group.add(spin);

  if (style !== 'none') {
    // Lathe profile: a slightly flared rim with strobe ridges.
    const pr = RECORD_RADIUS + 0.004;
    const pts = [
      [0, 0],
      [pr - 0.01, 0],
      [pr - 0.002, 0.002],
      [pr, 0.006],
      [pr - 0.0012, 0.008],
      [pr, 0.01],
      [pr - 0.0012, 0.012],
      [pr, 0.014],
      [pr - 0.0012, 0.016],
      [pr, 0.018],
      [pr - 0.002, platterH],
      [0, platterH],
    ].map(([x, y]) => new THREE.Vector2(x, y));
    const platter = new THREE.Mesh(new THREE.LatheGeometry(pts, 128), mats.platter);
    spin.add(shadowed(platter));
  }

  const recordThickness = 0.0018;
  const recordBaseY = style === 'none' ? 0 : platterH;
  const recordTop = recordBaseY + recordThickness;
  const recordEdge = new THREE.Mesh(
    new THREE.CylinderGeometry(RECORD_RADIUS, RECORD_RADIUS, recordThickness, 160, 1, true),
    new THREE.MeshStandardMaterial({ color: 0x0b0b0b, roughness: 0.3 })
  );
  recordEdge.position.y = recordBaseY + recordThickness / 2;
  spin.add(shadowed(recordEdge, true, false));

  const recordGeo = withFlatTangents(new THREE.CircleGeometry(RECORD_RADIUS, 160).rotateX(-Math.PI / 2));
  const recordTopMesh = new THREE.Mesh(recordGeo, recordMat);
  recordTopMesh.position.y = recordTop;
  spin.add(shadowed(recordTopMesh));
  const recordBottom = new THREE.Mesh(recordGeo, mats.black);
  recordBottom.rotation.x = Math.PI;
  recordBottom.position.y = recordBaseY + 0.0001;
  spin.add(recordBottom);

  // Label (or full picture disc) with two layers for cross-fades.
  const artRadius = labelStyle === 'picture' ? RECORD_RADIUS * 0.985 : LABEL_RADIUS;
  const labelGeo = new THREE.CircleGeometry(artRadius, 128);
  labelGeo.rotateX(-Math.PI / 2);
  const makeLabel = (offset) => {
    const m = new THREE.Mesh(
      labelGeo,
      new THREE.MeshStandardMaterial({
        roughness: labelStyle === 'picture' ? 0.32 : 0.7,
        envMap: options.envMap || null,
        envMapIntensity: 0.15,
        transparent: true,
        opacity: 0,
        polygonOffset: true,
        polygonOffsetFactor: -1 - offset,
        polygonOffsetUnits: -1 - offset,
      })
    );
    m.position.y = recordTop + 0.00015 + offset * 0.00005;
    m.receiveShadow = true;
    m.visible = false;
    spin.add(m);
    return m;
  };
  const labels = [makeLabel(0), makeLabel(1)];
  let front = 0; // index of the label currently fading in / shown

  if (labelStyle === 'picture') {
    const overlay = new THREE.Mesh(
      withFlatTangents(new THREE.CircleGeometry(RECORD_RADIUS, 160).rotateX(-Math.PI / 2)),
      new THREE.MeshPhysicalMaterial({
        map: pictureDiscOverlay(),
        envMap: options.envMap || null,
        envMapIntensity: options.recordReflections ?? 0.35,
        transparent: true,
        roughness: 1,
        roughnessMap: rec.roughnessMap,
        anisotropy: 0.9,
        anisotropyMap: rec.anisotropyMap,
        clearcoat: 0.5,
        clearcoatRoughness: 0.2,
        depthWrite: false,
        polygonOffset: true,
        polygonOffsetFactor: -4,
        polygonOffsetUnits: -4,
      })
    );
    overlay.position.y = recordTop + 0.0004;
    spin.add(overlay);
  } else {
    // Glossy ring at the label edge
    const ring = new THREE.Mesh(
      new THREE.RingGeometry(LABEL_RADIUS - 0.0004, LABEL_RADIUS + 0.0012, 128).rotateX(-Math.PI / 2),
      new THREE.MeshStandardMaterial({ color: 0x0a0a0a, roughness: 0.2 })
    );
    ring.position.y = recordTop + 0.0003;
    spin.add(ring);
  }

  // Spindle
  const spindle = new THREE.Mesh(new THREE.CylinderGeometry(0.0036, 0.0036, 0.014, 24), mats.chrome);
  spindle.position.y = recordTop + 0.007 - 0.002;
  const spindleCap = new THREE.Mesh(new THREE.SphereGeometry(0.0036, 16, 8, 0, TAU, 0, Math.PI / 2), mats.chrome);
  spindleCap.position.y = recordTop + 0.012;
  spin.add(shadowed(spindle), shadowed(spindleCap));

  // ---- Tonearm -------------------------------------------------------------
  const arm = buildTonearm(mats, style);
  const armHeight = recordTop + platterY + 0.0165;
  arm.base.position.set(pivot.x, topY, pivot.z);
  arm.yaw.position.set(pivot.x, armHeight, pivot.z);
  arm.setPostHeight(armHeight - topY);
  group.add(arm.base, arm.yaw);

  // Precompute yaw for a given stylus radius.
  const stylusLocal = arm.stylusLocal; // in yaw-group local space (x,z)
  const centerXZ = new THREE.Vector2(platterCenter.x, platterCenter.z);
  const yawToRadius = (yaw) => {
    const c = Math.cos(yaw);
    const s = Math.sin(yaw);
    const x = pivot.x + stylusLocal.x * c + stylusLocal.z * s;
    const z = pivot.z - stylusLocal.x * s + stylusLocal.z * c;
    return Math.hypot(x - centerXZ.x, z - centerXZ.y);
  };
  // Rest: arm parallel to the plinth's right edge, pointing to the front and
  // angled a touch inward so the headshell stays over the plinth.
  const restYaw = -Math.PI / 2 - 0.04;
  // The rest clip sits under the tube, 16.5 cm from the pivot.
  arm.rest.position.set(pivot.x + Math.cos(restYaw) * 0.165, topY, pivot.z - Math.sin(restYaw) * 0.165);
  arm.rest.scale.y = (armHeight - topY) / 0.04;
  if (style !== 'none') group.add(arm.rest);
  const table = [];
  {
    // Sweep toward the record and record the radius at each yaw.
    const dir = yawToRadius(restYaw + 0.01) < yawToRadius(restYaw) ? 1 : -1;
    for (let i = 0; i <= 900; i++) {
      const yaw = restYaw + dir * i * 0.002;
      table.push([yaw, yawToRadius(yaw)]);
    }
  }
  const yawForRadius = (r) => {
    for (let i = 1; i < table.length; i++) {
      if (table[i][1] <= r) {
        const [y0, r0] = table[i - 1];
        const [y1, r1] = table[i];
        return lerp(y0, y1, (r0 - r) / (r0 - r1 || 1));
      }
    }
    return table[table.length - 1][0];
  };
  const outerGroove = RECORD_RADIUS - 0.006;
  const innerGroove = LABEL_RADIUS + 0.012;
  const leadInYaw = yawForRadius(outerGroove);
  const grooveYaw = (s) => yawForRadius(lerp(outerGroove, innerGroove, clamp(s.progress || 0, 0, 1)));
  // Sign of yaw travel as the stylus moves inward through the grooves.
  const inward = Math.sign(yawForRadius(innerGroove) - leadInYaw) || -1;
  arm.yaw.rotation.y = restYaw;

  // Tonearm motion works like an automatic deck's cue mechanism: lift, swing
  // across, lower. Every phase can be interrupted and redirected, starting
  // from wherever the arm currently is.
  const LIFT_ANGLE = 0.11; // ~6°: the headshell rises a couple of centimetres
  const LIFT_TIME = 0.34;
  const LOWER_TIME = 0.55;
  const SWING_SPEED = 0.55; // rad/s, unhurried like a real auto-return
  const liftScale = options.liftScale ?? 0; // top-down views: lifting reads as "closer"
  const cue = {
    phase: 'down', // 'down' | 'lift' | 'swing' | 'lower'
    at: 'rest', // where the arm is (or is heading): 'rest' | 'record'
    yaw: restYaw,
    lift: 0, // 0 = resting on the record or the arm rest, 1 = fully raised
    from: restYaw,
    to: restYaw,
    t: 0,
    dur: 1,
  };
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

  function applyArm() {
    const shown = ease(cue.lift);
    arm.yaw.rotation.y = cue.yaw;
    arm.pitch.rotation.z = shown * LIFT_ANGLE;
    if (liftScale) arm.yaw.scale.setScalar(1 + shown * liftScale);
  }

  function startSwing(target) {
    cue.phase = 'swing';
    cue.from = cue.yaw;
    cue.to = target;
    cue.t = 0;
    cue.dur = Math.max(0.6, Math.abs(target - cue.yaw) / SWING_SPEED);
  }

  function updateArm(dt, s) {
    const dest = s.hasTrack && s.playing ? 'record' : 'rest';
    const target = dest === 'record' ? grooveYaw(s) : restYaw;
    // Redirect if the destination changed mid-move.
    if (dest !== cue.at) {
      cue.at = dest;
      if (cue.phase === 'down' || cue.phase === 'lower') cue.phase = 'lift';
      else if (cue.phase === 'swing') startSwing(target);
    }
    switch (cue.phase) {
      case 'down':
        if (dest === 'record') {
          const off = target - cue.yaw;
          // A new track or a seek: cue over to the new groove. A lowered
          // stylus only ever moves inward, so any step back re-cues too.
          if (Math.abs(off) > 0.05 || off * inward < -0.004) cue.phase = 'lift';
          else cue.yaw += off * (1 - Math.exp(-3 * dt)); // tracking inward
        }
        break;
      case 'lift':
        cue.lift = Math.min(1, cue.lift + dt / LIFT_TIME);
        if (cue.lift >= 1) {
          if (Math.abs(target - cue.yaw) < 0.002) cue.phase = 'lower';
          else startSwing(target);
        }
        break;
      case 'swing': {
        // The groove creeps inward while we swing; a seek or skip re-aims
        // from where the arm is instead of jumping.
        if (Math.abs(target - cue.to) > 0.005) startSwing(target);
        else cue.to = target;
        cue.t = Math.min(1, cue.t + dt / cue.dur);
        cue.yaw = lerp(cue.from, cue.to, ease(cue.t));
        if (cue.t >= 1) cue.phase = 'lower';
        break;
      }
      case 'lower':
        if (Math.abs(target - cue.yaw) > 0.005) {
          cue.phase = 'lift'; // the target moved: rise again and swing over
          break;
        }
        cue.yaw = target;
        cue.lift = Math.max(0, cue.lift - dt / LOWER_TIME);
        if (cue.lift <= 0) cue.phase = 'down';
        break;
    }
    applyArm(); // eased both ways, like a damped cue lever
  }

  // ---- State -------------------------------------------------------------
  let angularVelocity = 0;
  let shadowClock = 0;
  let shadowYaw = NaN; // arm pose at the last shadow refresh
  let shadowPitch = NaN;
  const state = { armMoved: true, busy: false };

  function setArt(tex, immediate = false) {
    const cur = labels[front];
    if (cur.material.map === tex && cur.visible) return;
    const next = labels[1 - front];
    next.material.map = tex;
    next.material.needsUpdate = true;
    next.visible = true;
    next.material.opacity = immediate ? 1 : 0;
    next.renderOrder = 2;
    cur.renderOrder = 1;
    front = 1 - front;
    if (immediate) {
      cur.visible = false;
    }
  }

  function setNameplate(title, artist) {
    if (!nameplate) return;
    const engraved = nameplate.userData.engraved;
    const old = nameplate.material.map;
    nameplate.material.map = nameplateTexture(
      title || 'Vinyl',
      artist || '',
      engraved
        ? { background: 'none', color: 'rgba(40,22,10,0.55)', subColor: 'rgba(40,22,10,0.4)' }
        : {}
    );
    nameplate.material.needsUpdate = true;
    if (old) old.dispose();
  }
  setNameplate('Vinyl', '');

  // `s` = { hasTrack, playing, progress (0..1) }
  function update(dt, s) {
    const target = s.playing ? OMEGA : 0;
    // Platters spin up quickly but coast down slowly.
    const rate = s.playing ? 2.4 : 0.9;
    angularVelocity += (target - angularVelocity) * (1 - Math.exp(-rate * dt));
    spin.rotation.y -= angularVelocity * dt;

    // Label cross-fade
    const cur = labels[front];
    const prev = labels[1 - front];
    if (cur.material.opacity < 1) {
      cur.material.opacity = Math.min(1, cur.material.opacity + dt / 0.6);
      if (cur.material.opacity >= 1) prev.visible = false;
    }

    // Tonearm. While it's cueing, refresh shadows at ~30 Hz; while tracking
    // a song it creeps so slowly that twice a second is plenty. Compare with
    // the pose at the last refresh so the slow creep still adds up.
    updateArm(dt, s);
    shadowClock += dt;
    const interval = cue.phase === 'down' ? 0.5 : 1 / 30;
    const moved = !(
      Math.abs(arm.yaw.rotation.y - shadowYaw) <= 0.0005 && Math.abs(arm.pitch.rotation.z - shadowPitch) <= 0.0005
    );
    state.armMoved = moved && shadowClock >= interval;
    if (state.armMoved) {
      shadowClock = 0;
      shadowYaw = arm.yaw.rotation.y;
      shadowPitch = arm.pitch.rotation.z;
    }
    // Still animating while paused: the arm returning, the platter coasting.
    state.busy = cue.phase !== 'down' || (!s.playing && angularVelocity > 0.05);
    return state;
  }

  // Jump straight to the resting pose for `s` (used when a scene is built).
  function snapArm(s) {
    const onRecord = s.hasTrack && s.playing;
    cue.at = onRecord ? 'record' : 'rest';
    cue.phase = 'down';
    cue.yaw = onRecord ? grooveYaw(s) : restYaw;
    cue.lift = 0;
    applyArm();
    if (s.playing) angularVelocity = OMEGA;
  }

  return {
    group,
    spin,
    labels,
    setArt,
    setNameplate,
    update,
    snapArm,
    arm, // .yaw / .pitch pivots (read by tests)
    dims: { width: W, depth: D, topY, recordTop: platterY + recordTop, platterCenter, pivot, leadInYaw },
    materials: mats,
  };
}

function buildTonearm(mats, style) {
  // Base (static) + yaw group (rotates around Y) + pitch group (lifts).
  const base = new THREE.Group();
  const plate = new THREE.Mesh(new THREE.CylinderGeometry(0.03, 0.031, 0.006, 48), mats.black);
  plate.position.y = 0.003;
  base.add(shadowed(plate));
  const post = new THREE.Mesh(new THREE.CylinderGeometry(0.012, 0.014, 1, 32), mats.satin);
  base.add(shadowed(post));

  const yaw = new THREE.Group();
  const pitch = new THREE.Group();
  yaw.add(pitch);
  const housing = new THREE.Mesh(new THREE.CylinderGeometry(0.014, 0.014, 0.022, 32), mats.black);
  housing.position.y = 0.0;
  yaw.add(shadowed(housing));
  const cap = new THREE.Mesh(new THREE.SphereGeometry(0.014, 24, 12, 0, TAU, 0, Math.PI / 2), mats.chrome);
  cap.position.y = 0.011;
  yaw.add(shadowed(cap));

  // Arm tube along +X with a gentle J bend toward the headshell.
  const L = 0.232;
  const path = new THREE.CatmullRomCurve3([
    new THREE.Vector3(-0.045, 0.004, 0),
    new THREE.Vector3(0.0, 0.004, 0),
    new THREE.Vector3(0.1, 0.004, 0),
    new THREE.Vector3(0.17, 0.003, -0.004),
    new THREE.Vector3(0.198, 0.002, -0.012),
  ]);
  const tube = new THREE.Mesh(new THREE.TubeGeometry(path, 64, 0.0038, 16, false), mats.chrome);
  pitch.add(shadowed(tube));
  // Counterweight
  const cw = new THREE.Mesh(new THREE.CylinderGeometry(0.015, 0.015, 0.028, 32), style === 'silver' ? mats.chrome : mats.black);
  cw.rotation.z = Math.PI / 2;
  cw.position.set(-0.06, 0.004, 0);
  pitch.add(shadowed(cw));
  const cwRing = new THREE.Mesh(new THREE.CylinderGeometry(0.0155, 0.0155, 0.004, 32), mats.chrome);
  cwRing.rotation.z = Math.PI / 2;
  cwRing.position.set(-0.044, 0.004, 0);
  pitch.add(cwRing);
  // Headshell, angled ~20°
  const head = new THREE.Group();
  head.position.set(0.198, 0.002, -0.012);
  head.rotation.y = 0.36;
  const shell = new THREE.Mesh(new THREE.BoxGeometry(0.042, 0.003, 0.019), mats.satin);
  shell.position.set(0.019, 0, 0);
  head.add(shadowed(shell));
  const lift = new THREE.Mesh(new THREE.BoxGeometry(0.018, 0.0016, 0.003), mats.satin);
  lift.position.set(0.026, 0.002, -0.014);
  lift.rotation.y = 0.2;
  head.add(shadowed(lift));
  const cart = new THREE.Mesh(new THREE.BoxGeometry(0.022, 0.012, 0.013), mats.cartridge);
  cart.position.set(0.022, -0.0075, 0);
  head.add(shadowed(cart));
  const stylus = new THREE.Mesh(new THREE.BoxGeometry(0.004, 0.006, 0.002), mats.black);
  stylus.position.set(0.03, -0.015, 0);
  head.add(stylus);
  pitch.add(head);

  // Stylus tip location in yaw-local XZ.
  const tip = new THREE.Vector3(0.03, -0.015, 0);
  head.updateMatrix();
  tip.applyMatrix4(head.matrix);

  // Arm rest post with a small clip
  const rest = new THREE.Group();
  const restPost = new THREE.Mesh(new THREE.CylinderGeometry(0.0025, 0.003, 0.04, 16), mats.satin);
  restPost.position.y = 0.02;
  rest.add(shadowed(restPost));
  const restCup = new THREE.Mesh(new THREE.BoxGeometry(0.012, 0.004, 0.006), mats.black);
  restCup.position.y = 0.038;
  rest.add(shadowed(restCup));

  return {
    base,
    yaw,
    pitch,
    rest,
    stylusLocal: tip,
    length: L,
    setPostHeight(h) {
      post.scale.y = h;
      post.position.y = h / 2;
    },
  };
}
