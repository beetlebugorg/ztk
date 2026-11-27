// SPDX-License-Identifier: BSD-2-Clause
// The sound of the toys: effects and music made at run time with the
// Web Audio API, from oscillators, noise, and envelopes. No sample file
// and no third-party code. assets/toys.js makes one Sound for the page
// and calls it only after the reader turns the sound or the music on.

// The frequency of a note name such as "A4", "C#5", or "Eb3".
const SEMI = { C: -9, D: -7, E: -5, F: -4, G: -2, A: 0, B: 2 };
export function freq(note) {
  const m = /^([A-G])([#b]?)(-?\d)$/.exec(note);
  if (!m) return 0;
  const n = SEMI[m[1]] + (m[2] === "#" ? 1 : m[2] === "b" ? -1 : 0) + (Number(m[3]) - 4) * 12;
  return 440 * 2 ** (n / 12);
}

// Each effect: a list of voices. A voice has a wave ("sine", "square",
// "triangle", "sawtooth", or "noise"), a start and an end frequency, a
// length in seconds, a peak gain, an attack, a delay from the start,
// and for noise a filter frequency.
const FX = {
  jump: [{ wave: "square", f0: 260, f1: 620, len: 0.13, gain: 0.05 }],
  land: [{ wave: "noise", filter: 900, len: 0.06, gain: 0.08 }],
  step: [{ wave: "noise", filter: 2400, len: 0.025, gain: 0.025 }],
  light: [{ wave: "triangle", f0: 1319, f1: 1319, len: 0.12, gain: 0.07 }, { wave: "triangle", f0: 1976, f1: 1976, len: 0.3, gain: 0.07, at: 0.07 }],
  pickup: [{ wave: "triangle", f0: 784, f1: 784, len: 0.07, gain: 0.06 }, { wave: "triangle", f0: 988, f1: 988, len: 0.07, gain: 0.06, at: 0.06 }, { wave: "triangle", f0: 1175, f1: 1175, len: 0.16, gain: 0.06, at: 0.12 }],
  hurt: [{ wave: "sawtooth", f0: 420, f1: 70, len: 0.35, gain: 0.05 }, { wave: "noise", filter: 600, len: 0.2, gain: 0.06 }],
  win: [0, 0.09, 0.18, 0.3].map((at, i) => ({ wave: "triangle", f0: [523, 659, 784, 1047][i], f1: [523, 659, 784, 1047][i], len: i === 3 ? 0.6 : 0.12, gain: 0.07, at })),
  lose: [0, 0.14, 0.28].map((at, i) => ({ wave: "triangle", f0: [392, 330, 262][i], f1: [392, 330, 247][i], len: i === 2 ? 0.5 : 0.14, gain: 0.07, at })),
  select: [{ wave: "square", f0: 880, f1: 880, len: 0.045, gain: 0.035 }],
  move: [{ wave: "square", f0: 523, f1: 523, len: 0.03, gain: 0.025 }],
  slide: [{ wave: "noise", filter: 3200, len: 0.18, gain: 0.03, attack: 0.04 }],
  bump: [{ wave: "sine", f0: 150, f1: 55, len: 0.12, gain: 0.16 }, { wave: "noise", filter: 500, len: 0.05, gain: 0.05 }],
  burn: [{ wave: "noise", filter: 420, len: 0.14, gain: 0.05, attack: 0.03 }],
  pop: [{ wave: "sine", f0: 500, f1: 1400, len: 0.07, gain: 0.08 }],
  gust: [{ wave: "noise", filter: 700, len: 0.6, gain: 0.025, attack: 0.25 }],
  crash: [{ wave: "noise", filter: 1400, len: 0.45, gain: 0.12 }, { wave: "sine", f0: 120, f1: 40, len: 0.3, gain: 0.18 }],
  undo: [{ wave: "square", f0: 660, f1: 330, len: 0.06, gain: 0.03 }],
  start: [0, 0.07, 0.14].map((at, i) => ({ wave: "square", f0: [659, 784, 1319][i], f1: [659, 784, 1319][i], len: 0.08, gain: 0.03, at })),
};

// The songs: a tempo, the steps of one bar (16 sixteenths), and the
// tracks. A track has an instrument and a list of bars; each bar is 16
// cells of a note name, "." (rest), or "-" (hold). The song loops.
const INST = {
  lead: { wave: "square", gain: 0.022, attack: 0.005, release: 0.08 },
  soft: { wave: "triangle", gain: 0.05, attack: 0.01, release: 0.12 },
  bass: { wave: "triangle", gain: 0.07, attack: 0.005, release: 0.06 },
  pad: { wave: "sine", gain: 0.028, attack: 0.12, release: 0.4 },
  bell: { wave: "sine", gain: 0.04, attack: 0.002, release: 0.5 },
  hat: { wave: "noise", filter: 7000, gain: 0.012, attack: 0.001, release: 0.03 },
  kick: { wave: "kick", gain: 0.12 },
};
const bar = (s) => s.trim().split(/\s+/);
export const SONGS = {
  // Lamplighter: a dusk walk in A minor, with a bell melody.
  "lamplighter-title": { bpm: 84, tracks: [
    ["pad", [bar("A3 - - - - - - - E4 - - - - - - -"), bar("F3 - - - - - - - C4 - - - - - - -"), bar("C4 - - - - - - - G3 - - - - - - -"), bar("D4 - - - - - - - E4 - - - - - - -")]],
    ["bell", [bar("E5 . . . C5 . . . A4 . . . B4 . C5 ."), bar("A4 . . . . . F4 . A4 . C5 . . . . ."), bar("G4 . . . E5 . . . D5 . C5 . . . . ."), bar("B4 . . . . . . . . . . . . . . .")]],
  ] },
  "lamplighter-play": { bpm: 112, tracks: [
    ["bass", [bar("A2 . . A2 . . E3 . A2 . . A2 . . G2 ."), bar("F2 . . F2 . . C3 . F2 . . F2 . . E2 ."), bar("C3 . . C3 . . G3 . C3 . . C3 . . B2 ."), bar("D3 . . D3 . . A3 . E3 . . E3 . . E2 .")]],
    ["soft", [bar("A4 . C5 . E5 . . . D5 . C5 . B4 . . ."), bar("A4 . . . F4 . A4 . C5 . . . . . . ."), bar("G4 . C5 . E5 . G5 . F5 . E5 . D5 . . ."), bar("E5 . . . D5 . C5 . B4 . . . G#4 . . .")]],
    ["hat", [bar(". . A4 . . . A4 . . . A4 . . . A4 ."), bar(". . A4 . . . A4 . . . A4 . . . A4 ."), bar(". . A4 . . . A4 . . . A4 . . . A4 ."), bar(". . A4 . . . A4 . . . A4 . A4 . A4 .")]],
  ] },
  // Skate Pond: a light waltz feel in G major, slow and bright.
  "skatepond-title": { bpm: 96, tracks: [
    ["pad", [bar("G3 - - - - - - - D4 - - - - - - -"), bar("E3 - - - - - - - C4 - - - - - - -")]],
    ["bell", [bar("D5 . . . B4 . . . G4 . A4 . B4 . . ."), bar("C5 . . . A4 . . . E4 . F#4 . G4 . . .")]],
  ] },
  "skatepond-play": { bpm: 100, tracks: [
    ["bass", [bar("G2 . . . D3 . . . G2 . . . D3 . . ."), bar("E2 . . . B2 . . . E2 . . . B2 . . ."), bar("C3 . . . G3 . . . C3 . . . G3 . . ."), bar("D3 . . . A3 . . . D3 . . . F#3 . . .")]],
    ["bell", [bar("B4 . D5 . G5 . . . F#5 . E5 . D5 . . ."), bar("B4 . . . G4 . . . B4 . . . . . . ."), bar("C5 . E5 . G5 . . . A5 . G5 . E5 . . ."), bar("D5 . . . C5 . . . B4 . A4 . . . . .")]],
    ["hat", [bar(". . . . A4 . . . . . . . A4 . . ."), bar(". . . . A4 . . . . . . . A4 . . ."), bar(". . . . A4 . . . . . . . A4 . . ."), bar(". . . . A4 . . . . . . . A4 . A4 .")]],
  ] },
  // Tin Moon: a drifting synth line in D dorian over a soft pulse.
  "tinmoon-title": { bpm: 72, tracks: [
    ["pad", [bar("D3 - - - - - - - - - - - - - - -"), bar("C3 - - - - - - - - - - - - - - -")]],
    ["bell", [bar("A4 . . . . . D5 . . . . . F5 . . ."), bar("E5 . . . . . C5 . . . . . G4 . . .")]],
  ] },
  "tinmoon-play": { bpm: 90, tracks: [
    ["bass", [bar("D2 . . . . . D2 . . . A2 . . . . ."), bar("C2 . . . . . C2 . . . G2 . . . . ."), bar("Bb1 . . . . . Bb1 . . . F2 . . . . ."), bar("C2 . . . . . C2 . . . G2 . . . E2 .")]],
    ["soft", [bar("D4 . F4 . A4 . . . C5 . . . A4 . . ."), bar("E4 . G4 . C5 . . . B4 . . . G4 . . ."), bar("F4 . A4 . D5 . . . C5 . A4 . F4 . . ."), bar("E4 . . . G4 . . . E4 . . . . . . .")]],
    ["kick", [bar("C2 . . . . . . . C2 . . . . . . ."), bar("C2 . . . . . . . C2 . . . . . . ."), bar("C2 . . . . . . . C2 . . . . . . ."), bar("C2 . . . . . . . C2 . . . C2 . . .")]],
  ] },
};

export class Sound {
  constructor() {
    this.ctx = null;
    this.fx = false;
    this.music = false;
    this.song = "";
    this.timer = 0;
  }
  start() {
    if (this.ctx) return this.ctx;
    const ctx = (this.ctx = new AudioContext());
    // A compressor keeps a burst of effects below the clip level.
    this.out = ctx.createDynamicsCompressor();
    this.out.threshold.value = -18;
    this.out.connect(ctx.destination);
    this.fxBus = ctx.createGain();
    this.fxBus.connect(this.out);
    this.musicBus = ctx.createGain();
    this.musicBus.gain.value = 0.8;
    this.musicBus.connect(this.out);
    const n = ctx.sampleRate;
    this.noise = ctx.createBuffer(1, n, n);
    const d = this.noise.getChannelData(0);
    // A fixed seed, so the noise is the same on each load.
    let s = 7;
    for (let i = 0; i < n; i++) { s = (s * 1103515245 + 12345) >>> 0; d[i] = (s / 2 ** 31) - 1; }
    return ctx;
  }
  // One voice: an oscillator or noise through a gain envelope.
  voice(v, t, bus) {
    const ctx = this.ctx;
    const g = ctx.createGain();
    const attack = v.attack ?? 0.004;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(v.gain, t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + Math.max(attack + 0.01, v.len));
    g.connect(bus);
    let src;
    if (v.wave === "noise") {
      src = ctx.createBufferSource();
      src.buffer = this.noise;
      src.loop = true;
      const f = ctx.createBiquadFilter();
      f.type = "lowpass";
      f.frequency.value = v.filter ?? 2000;
      src.connect(f);
      f.connect(g);
    } else {
      src = ctx.createOscillator();
      src.type = v.wave;
      src.frequency.setValueAtTime(v.f0, t);
      if (v.f1 !== v.f0) src.frequency.exponentialRampToValueAtTime(Math.max(20, v.f1), t + v.len);
      src.connect(g);
    }
    src.start(t);
    src.stop(t + v.len + 0.05);
  }
  play(name) {
    if (!this.fx || !FX[name]) return;
    const ctx = this.start();
    const t = ctx.currentTime + 0.005;
    for (const v of FX[name]) this.voice(v, t + (v.at ?? 0), this.fxBus);
  }
  // The song of the game state. An empty name stops the music.
  setSong(name) {
    this.song = name;
    clearTimeout(this.timer);
    this.timer = 0;
    if (!this.music || !SONGS[name]) return;
    const ctx = this.start();
    const song = SONGS[name];
    const step = 60 / song.bpm / 4;
    const bars = Math.max(...song.tracks.map(([, b]) => b.length));
    let n = 0;
    let next = ctx.currentTime + 0.1;
    // A look-ahead scheduler: each call puts the notes of the next 200 ms
    // on the audio clock, so a slow frame does not delay a note.
    const pump = () => {
      if (this.song !== name || !this.music) return;
      while (next < ctx.currentTime + 0.2) {
        const b = Math.floor(n / 16) % bars, cell = n % 16;
        for (const [inst, pattern] of song.tracks) {
          const row = pattern[b % pattern.length];
          const note = row[cell];
          if (!note || note === "." || note === "-") continue;
          let len = 1;
          while (row[cell + len] === "-") len++;
          this.note(INST[inst], note, next, len * step);
        }
        n++;
        next += step;
      }
      this.timer = setTimeout(pump, 50);
    };
    pump();
  }
  note(inst, name, t, len) {
    if (inst.wave === "kick") {
      this.voice({ wave: "sine", f0: 140, f1: 45, len: 0.18, gain: inst.gain }, t, this.musicBus);
      return;
    }
    const f = freq(name);
    this.voice({ wave: inst.wave, f0: f, f1: f, len: len + inst.release, gain: inst.gain, attack: inst.attack, filter: inst.filter }, t, this.musicBus);
  }
  setFx(on) {
    this.fx = on;
    if (on) this.start().resume();
  }
  setMusic(on) {
    this.music = on;
    if (on) this.start().resume();
    this.setSong(this.song);
  }
  // Silence while the game is paused or off the screen.
  suspend(off) {
    if (!this.ctx) return;
    if (off) this.ctx.suspend(); else this.ctx.resume();
  }
}
