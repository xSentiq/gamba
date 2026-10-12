// Background music: an original, mellow "elevator" bossa loop, synthesized live with the Web Audio API (no audio files).
// Electric piano comping, vibraphone melody, soft bass, shaker and rim clicks, with a little reverb. 8 bars, played
// twice (the second time the melody is harmonized), then it loops forever.
// It starts after the first click or key press (browsers do not allow audio before that) and has its own on/off
// button (#music-toggle). The choice is remembered in localStorage ("goog-music").
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const BPM = 96, BEAT = 60 / BPM;
  const LEVEL = 0.45;                                        // overall music volume (the sound effects are louder on purpose)
  const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);

  // ---------------------------------------------------------------------------------------------- the song
  // chords: rootless voicings for the piano, a bass root and fifth (MIDI note numbers)
  const CH = {
    Fmaj9: { v: [64, 67, 69, 72], r: 41, f: 48 },
    Dm9:   { v: [60, 64, 65, 69], r: 38, f: 45 },
    Gm9:   { v: [58, 62, 65, 69], r: 43, f: 50 },
    C13:   { v: [58, 62, 64, 69], r: 48, f: 43 },
    Am7:   { v: [60, 64, 67, 69], r: 45, f: 40 },
    D7:    { v: [60, 62, 66, 69], r: 38, f: 45 },
    C7:    { v: [58, 64, 67, 72], r: 48, f: 43 },
  };
  // each bar: [beat in bar, chord]
  const BARS = [
    [[0, "Fmaj9"]], [[0, "Dm9"]], [[0, "Gm9"]], [[0, "C13"]],
    [[0, "Fmaj9"]], [[0, "Am7"], [2, "D7"]], [[0, "Gm9"]], [[0, "C7"]],
  ];
  // melody (vibraphone): [beat in bar, MIDI note, length in beats]
  const MEL = [
    [[0, 76, 1.5], [1.5, 74, 0.5], [2, 72, 1], [3, 69, 1]],
    [[0, 74, 1], [1, 72, 0.5], [1.5, 69, 1.5], [3, 72, 1]],
    [[0, 70, 1.5], [1.5, 72, 0.5], [2, 74, 1], [3, 77, 1]],
    [[0, 76, 2], [2, 72, 1], [3, 70, 1]],
    [[0, 77, 1.5], [1.5, 76, 0.5], [2, 72, 1], [3, 76, 1]],
    [[0, 72, 1], [1, 69, 1], [2, 74, 1], [3, 78, 1]],
    [[0, 79, 1], [1, 77, 0.5], [1.5, 74, 1.5], [3, 70, 1]],
    [[0, 72, 1.5], [1.5, 70, 0.5], [2, 67, 2]],
  ];
  const SCALE = [0, 2, 4, 5, 7, 9, 10];                      // F major
  const harmony = (m) => { for (const d of [3, 4, 5, 7]) if (SCALE.includes(((m - d) % 12 + 12) % 12)) return m - d; return m - 4; };

  const PASSES = 2, LOOP_BEATS = PASSES * BARS.length * 4;
  const EVENTS = [];                                         // { b: beat, k: kind, ... } sorted by b
  (function build() {
    for (let p = 0; p < PASSES; p++) {
      BARS.forEach((segs, bar) => {
        const base = (p * BARS.length + bar) * 4;
        segs.forEach(([at, name], si) => {
          const len = (segs[si + 1] ? segs[si + 1][0] : 4) - at, c = CH[name], b0 = base + at;
          (len >= 4 ? [0, 1.5, 3] : [0, 1.5]).forEach((h, i) => EVENTS.push({ b: b0 + h, k: "keys", n: c.v, d: h === 0 ? 0.9 : 1.1, v: i === 0 ? 1 : 0.8 }));
          EVENTS.push({ b: b0, k: "bass", m: c.r, d: 1.5 });
          EVENTS.push({ b: b0 + 1.5, k: "bass", m: c.f, d: len >= 4 ? 1.1 : 0.5 });
          if (len >= 4) EVENTS.push({ b: b0 + 3, k: "bass", m: c.r, d: 0.9, v: 0.7 });
        });
        MEL[bar].forEach(([at, m, d]) => {
          EVENTS.push({ b: base + at, k: "vibes", m, d: d * 1.15, v: 1 });
          if (p === 1) EVENTS.push({ b: base + at, k: "vibes", m: harmony(m), d: d * 1.15, v: 0.55 });
        });
        for (let e = 0; e < 8; e++) EVENTS.push({ b: base + e * 0.5, k: "shake", a: e % 2 === 0 ? 1 : 0.55 });
        (bar % 2 === 0 ? [0, 1.5, 3] : [1, 2]).forEach((h) => EVENTS.push({ b: base + h, k: "rim" }));
      });
    }
    EVENTS.sort((a, b) => a.b - b.b);
  })();

  // ---------------------------------------------------------------------------------------------- sound engine
  function impulse(c) {                                      // a small, soft room
    const len = Math.floor(c.sampleRate * 1.7), buf = c.createBuffer(2, len, c.sampleRate);
    for (let ch = 0; ch < 2; ch++) { const d = buf.getChannelData(ch); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3); }
    return buf;
  }

  function makeGraph(c) {
    const out = c.createGain(); out.gain.value = 0;
    const lp = c.createBiquadFilter(); lp.type = "lowpass"; lp.frequency.value = 6500;   // keeps everything smooth
    const comp = c.createDynamicsCompressor();
    out.connect(lp); lp.connect(comp); comp.connect(c.destination);
    const dry = c.createGain(); dry.connect(out);
    const rev = c.createConvolver(); rev.buffer = impulse(c);
    const wet = c.createGain(); wet.gain.value = 0.45; rev.connect(wet); wet.connect(out);
    const send = c.createGain(); send.connect(rev);
    const bus = (toSend, gain) => { const g = c.createGain(); g.gain.value = gain; g.connect(dry); if (toSend) g.connect(send); return g; };
    const vibes = bus(true, 0.9);
    const lfo = c.createOscillator(), lg = c.createGain();   // vibraphone tremolo
    lfo.frequency.value = 4.8; lg.gain.value = 0.2; lfo.connect(lg); lg.connect(vibes.gain); lfo.start();
    const nb = c.createBuffer(1, c.sampleRate, c.sampleRate), nd = nb.getChannelData(0);
    for (let i = 0; i < nd.length; i++) nd[i] = Math.random() * 2 - 1;
    return { c, out, keys: bus(true, 1), vibes, bass: bus(false, 1), perc: bus(true, 0.8), noise: nb };
  }

  function env(g, t, peak, attack, dur) {
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(peak, t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  }
  function osc(G, type, freq, t, dur, peak, attack, dest) {
    const o = G.c.createOscillator(), g = G.c.createGain();
    o.type = type; o.frequency.value = freq;
    env(g, t, peak, attack, dur);
    o.connect(g); g.connect(dest);
    o.start(t); o.stop(t + dur + 0.05);
  }

  const VOICES = {
    // electric piano: soft body plus a short bell on top
    keys(G, e, t) {
      const dur = e.d * BEAT + 0.9;
      e.n.forEach((m, i) => {
        const tt = t + i * 0.012, f = mtof(m), v = 0.05 * e.v;       // tiny strum
        osc(G, "triangle", f, tt, dur, v, 0.008, G.keys);
        osc(G, "sine", f * 2, tt, 0.35, v * 0.45, 0.004, G.keys);
        osc(G, "sine", f * 5.02, tt, 0.12, v * 0.12, 0.002, G.keys);
      });
    },
    vibes(G, e, t) {
      const dur = e.d * BEAT + 0.8, f = mtof(e.m), v = 0.075 * e.v;
      osc(G, "sine", f, t, dur, v, 0.006, G.vibes);
      osc(G, "sine", f * 4, t, 0.45, v * 0.22, 0.003, G.vibes);
      osc(G, "sine", f * 10, t, 0.12, v * 0.05, 0.002, G.vibes);
    },
    bass(G, e, t) {
      const f = mtof(e.m), dur = e.d * BEAT, v = 0.2 * (e.v || 1);
      osc(G, "sine", f, t, dur, v, 0.012, G.bass);
      osc(G, "triangle", f * 2, t, dur * 0.6, v * 0.35, 0.008, G.bass);
    },
    shake(G, e, t) {
      const s = G.c.createBufferSource(), f = G.c.createBiquadFilter(), g = G.c.createGain();
      s.buffer = G.noise; f.type = "highpass"; f.frequency.value = 6000;
      env(g, t, 0.03 * e.a, 0.004, 0.07);
      s.connect(f); f.connect(g); g.connect(G.perc);
      s.start(t, Math.random() * 0.5, 0.09);
    },
    rim(G, e, t) {
      osc(G, "sine", 1650, t, 0.05, 0.035, 0.001, G.perc);
      osc(G, "triangle", 880, t, 0.04, 0.02, 0.001, G.perc);
    },
  };
  const play = (G, e, t) => { const f = VOICES[e.k]; if (f) f(G, e, t); };

  // ---------------------------------------------------------------------------------------------- playback
  const S = { c: null, G: null, on: false, timer: 0, idx: 0, t0: 0, duckTimer: 0 };
  let pref = null;                                           // null = not chosen yet (on after the first click), "0" = off, "1" = on
  try { pref = localStorage.getItem("goog-music"); } catch (e) {}

  function tick() {
    const c = S.c; if (!c) return;
    const horizon = c.currentTime + 0.9;
    for (let guard = 0; guard < 400; guard++) {
      const e = EVENTS[S.idx], t = S.t0 + e.b * BEAT;
      if (t > horizon) break;
      if (t >= c.currentTime - 0.02) play(S.G, e, Math.max(t, c.currentTime));
      if (++S.idx >= EVENTS.length) { S.idx = 0; S.t0 += LOOP_BEATS * BEAT; }
    }
  }

  function start() {
    if (S.on) return true;
    try {
      if (!S.c) {
        const AC = window.AudioContext || window.webkitAudioContext;
        if (!AC) return false;
        S.c = new AC(); S.G = makeGraph(S.c);
      }
      if (S.c.state === "suspended") S.c.resume().catch(() => {});
      const now = S.c.currentTime;
      S.G.out.gain.cancelScheduledValues(now);
      S.G.out.gain.setValueAtTime(S.G.out.gain.value, now);
      S.G.out.gain.setTargetAtTime(LEVEL, now, 0.9);         // slow fade in
      S.idx = 0; S.t0 = now + 0.15;
      S.on = true;
      tick(); S.timer = setInterval(tick, 150);
      return true;
    } catch (e) { S.on = false; return false; }
  }

  function stop() {
    if (!S.on) return;
    S.on = false; clearInterval(S.timer);
    try { const now = S.c.currentTime; S.G.out.gain.cancelScheduledValues(now); S.G.out.gain.setTargetAtTime(0, now, 0.15); } catch (e) {}
  }

  // the music steps back for a moment while a big win is celebrated
  function duck(ms) {
    if (!S.on || !S.G) return;
    const now = S.c.currentTime;
    S.G.out.gain.cancelScheduledValues(now);
    S.G.out.gain.setTargetAtTime(LEVEL * 0.3, now, 0.12);
    clearTimeout(S.duckTimer);
    S.duckTimer = setTimeout(() => {
      if (!S.on || !S.c) return;
      const t = S.c.currentTime;
      S.G.out.gain.cancelScheduledValues(t);
      S.G.out.gain.setTargetAtTime(LEVEL, t, 0.8);
    }, ms || 3000);
  }

  function paint() {
    const b = $("music-toggle");
    if (!b) return;
    b.textContent = S.on ? "🎶" : "🎵";
    b.classList.toggle("off", !S.on);
    b.setAttribute("aria-pressed", String(S.on));
    b.title = S.on ? "Music is on" : "Music is off";
  }

  function toggle() {
    if (S.on) { stop(); pref = "0"; } else { start(); pref = "1"; }
    try { localStorage.setItem("goog-music", pref); } catch (e) {}
    paint();
  }

  document.addEventListener("DOMContentLoaded", () => {
    paint();
    const b = $("music-toggle");
    if (b) b.addEventListener("click", toggle);
  });

  // Browsers only allow sound after a click or key press. Unless the player switched the music off, start with the first one.
  const first = (ev) => {
    if (ev.target && ev.target.closest && ev.target.closest("#music-toggle")) return;       // that click is the toggle itself
    window.removeEventListener("pointerdown", first, true); window.removeEventListener("keydown", first, true);
    if (pref !== "0") { start(); paint(); }
  };
  window.addEventListener("pointerdown", first, true);
  window.addEventListener("keydown", first, true);

  // pause while the tab is in the background
  let wasOn = false;
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { wasOn = S.on; if (S.on) { stop(); paint(); } }
    else if (wasOn && pref !== "0") { start(); paint(); wasOn = false; }
  });

  window.Music = {
    on: () => S.on, toggle, duck,
    // renders the loop to an audio buffer without playing it (used for testing and previews)
    async renderOffline(seconds) {
      const sr = 44100, c = new OfflineAudioContext(2, Math.floor(sr * seconds), sr), G = makeGraph(c);
      G.out.gain.value = LEVEL;
      const t0 = 0.05;
      for (let loop = 0; t0 + loop * LOOP_BEATS * BEAT < seconds; loop++)
        EVENTS.forEach((e) => { const t = t0 + (loop * LOOP_BEATS + e.b) * BEAT; if (t < seconds) play(G, e, t); });
      return c.startRendering();
    },
  };
})();
