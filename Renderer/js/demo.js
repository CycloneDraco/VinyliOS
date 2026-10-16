// Browser-only demo driver: fake "now playing" data plus keyboard shortcuts,
// so the renderer can be developed without the Mac app.
//
//   space  play / pause        n  next track
//   1-4    scenes              - / =  smaller / larger
//   b      toggle background   l  label / picture disc   a  mini: deck / record only
import { builtInCovers } from './textures.js';
import { miniStyle } from './scenes/mini.js';

const SCENES = ['listening-room', 'after-hours', 'turntable', 'mini'];

const tracks = builtInCovers.map((c, i) => ({
  id: c.id,
  title: c.title,
  artist: c.artist,
  album: c.title,
  artwork: null,
  duration: 180 + i * 17,
}));

function trackPatch(index) {
  const t = tracks[index % tracks.length];
  return { ...t, artwork: undefined, id: t.id };
}

function recentFor(index) {
  const list = [];
  for (let i = 1; i <= 4; i++) {
    const t = tracks[(index - i + tracks.length * 4) % tracks.length];
    list.push({ id: t.id, title: t.title, artist: t.artist });
  }
  return list;
}

export function startDemo(update, config, scene) {
  let index = 0;
  let playing = true;
  update({ track: trackPatch(index), recent: recentFor(index), playing, position: 20 });
  window.addEventListener('keydown', (e) => {
    const k = e.key.toLowerCase();
    if (k === ' ') {
      playing = !playing;
      update({ playing });
    } else if (k === 'n') {
      index++;
      update({ track: trackPatch(index), recent: recentFor(index), playing: true, position: 0 });
      playing = true;
    } else if (k >= '1' && k <= '4') {
      update({ scene: SCENES[Number(k) - 1] });
    } else if (k === '-' || k === '=' || k === '+') {
      const size = scene()?.size ?? 0;
      update({ size: Math.round(Math.min(1, Math.max(0, size + (k === '-' ? -0.1 : 0.1))) * 10) / 10 });
    } else if (k === 'b') {
      update({ background: !config.background });
    } else if (k === 'l') {
      update({ labelStyle: config.labelStyle === 'picture' ? 'label' : 'picture' });
    } else if (k === 'a') {
      update({ miniStyle: miniStyle(config) === 'record' ? 'turntable' : 'record' });
    } else if (k === 's') {
      update({ track: null, playing: false });
    }
  });
}

// Used by snapshot mode: ?demo&track=2&playing=1&progress=0.4&art=<url>
export function applyDemoState(update, q) {
  const index = Number(q.get('track') ?? 1);
  if (q.get('track') === 'none') {
    update({ track: null, playing: false });
    return;
  }
  const t = trackPatch(index);
  if (q.get('art')) t.artwork = q.get('art');
  const progress = Number(q.get('progress') ?? 0.25);
  update({
    track: t,
    recent: recentFor(index),
    playing: q.get('playing') !== '0',
    position: progress * t.duration,
  });
}
