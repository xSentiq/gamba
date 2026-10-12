// Sound effects and win animations. All sounds are synthesized with the Web Audio API (no audio files).
// Window.Fx is used by the games: Fx.sound(name, arg), Fx.win({ win, bet }), Fx.announce(title, sub), Fx.shake().
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const reduced = () => window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fmt = new Intl.NumberFormat("en-US");

  // =====================================================================
  // Audio
  // =====================================================================
  let ctx = null, master = null;
  let muted = false;
  try { muted = localStorage.getItem("goog-mute") === "1"; } catch (e) {}

  function ensure() {
    if (muted) return false;
    if (!ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return false;
      try {
        ctx = new AC();
        master = ctx.createGain(); master.gain.value = 0.55;
        const comp = ctx.createDynamicsCompressor();                 // keeps stacked sounds from clipping
        master.connect(comp); comp.connect(ctx.destination);
      } catch (e) { ctx = null; return false; }
    }
    if (ctx.state === "suspended") ctx.resume().catch(() => {});
    return ctx.state !== "closed";
  }
  // browsers only allow audio after a tap or click, so wake the audio engine on the first one
  ["pointerdown", "keydown"].forEach((ev) => window.addEventListener(ev, () => { if (!muted) ensure(); }, { passive: true }));

  function tone(freq, t0, dur, o = {}) {
    const t = ctx.currentTime + t0;
    const osc = ctx.createOscillator(), g = ctx.createGain();
    osc.type = o.type || "sine";
    osc.frequency.setValueAtTime(freq, t);
    if (o.slide) osc.frequency.exponentialRampToValueAtTime(Math.max(20, o.slide), t + dur);
    const v = o.vol === undefined ? 0.2 : o.vol;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(v, t + (o.attack || 0.006));
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    osc.connect(g); g.connect(o.dest || master);
    osc.start(t); osc.stop(t + dur + 0.05);
  }
  let noiseBuf = null;
  function noise(t0, dur, o = {}) {
    if (!noiseBuf) {
      noiseBuf = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
      const d = noiseBuf.getChannelData(0);
      for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    }
    const t = ctx.currentTime + t0;
    const src = ctx.createBufferSource(); src.buffer = noiseBuf; src.loop = true;
    const f = ctx.createBiquadFilter(); f.type = o.filter || "lowpass";
    f.frequency.setValueAtTime(o.freq || 1000, t);
    if (o.sweep) f.frequency.exponentialRampToValueAtTime(Math.max(30, o.sweep), t + dur);
    const g = ctx.createGain();
    g.gain.setValueAtTime(o.vol === undefined ? 0.2 : o.vol, t);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    src.connect(f); f.connect(g); g.connect(master);
    src.start(t); src.stop(t + dur + 0.05);
  }
  const note = (semi) => 440 * Math.pow(2, semi / 12);               // semitones from A4
  const PENT = [0, 2, 4, 7, 9];                                        // pleasant pentatonic steps
  const climb = (n) => note(-3 + PENT[n % 5] + 12 * Math.floor(n / 5));

  let lastTick = 0;
  const throttle = (ms) => { const n = performance.now(); if (n - lastTick < ms) return true; lastTick = n; return false; };

  const SOUNDS = {
    click() { tone(660, 0, 0.045, { type: "square", vol: 0.05 }); },
    pop(n) { tone(climb(n || 0), 0, 0.12, { type: "triangle", vol: 0.22 }); tone(climb(n || 0) * 2, 0, 0.06, { type: "sine", vol: 0.07 }); },
    tick() { tone(1700, 0, 0.02, { type: "square", vol: 0.04 }); },
    thump() { tone(150, 0, 0.14, { type: "sine", vol: 0.35, slide: 55 }); noise(0, 0.07, { freq: 400, vol: 0.12 }); },
    ping(i) { tone(520 + ((i || 0) % 9) * 55, 0, 0.09, { type: "sine", vol: 0.1 }); },
    coin() { tone(1319, 0, 0.07, { type: "square", vol: 0.08 }); tone(1760, 0.06, 0.28, { type: "triangle", vol: 0.14 }); },
    start() { tone(330, 0, 0.08, { type: "triangle", vol: 0.15 }); tone(495, 0.07, 0.12, { type: "triangle", vol: 0.15 }); },
    lose() { tone(330, 0, 0.28, { type: "sine", vol: 0.11, slide: 200 }); },
    explode() { noise(0, 0.5, { freq: 2200, sweep: 80, vol: 0.4 }); tone(110, 0, 0.45, { type: "sine", vol: 0.3, slide: 40 }); },
    launch() { tone(110, 0, 0.5, { type: "sawtooth", vol: 0.07, slide: 420 }); noise(0, 0.4, { filter: "bandpass", freq: 500, sweep: 2500, vol: 0.06 }); },
    rise(m) { tone(180 + Math.min(m || 1, 30) * 28, 0, 0.06, { type: "sawtooth", vol: 0.035 }); },
    scratch() { noise(0, 0.045, { filter: "highpass", freq: 2600, vol: 0.05 }); },
    step(n) { tone(climb(n || 0), 0, 0.14, { type: "triangle", vol: 0.2 }); tone(climb(n || 0) * 1.5, 0.06, 0.12, { type: "sine", vol: 0.08 }); },
    splash() { noise(0, 0.35, { filter: "bandpass", freq: 900, sweep: 300, vol: 0.25 }); tone(260, 0, 0.3, { type: "sine", vol: 0.1, slide: 120 }); },
    buy() { [0, 4, 7, 12].forEach((s, i) => tone(note(s + 3), i * 0.07, 0.2, { type: "triangle", vol: 0.16 })); },
    deny() { tone(200, 0, 0.12, { type: "square", vol: 0.07 }); tone(160, 0.1, 0.16, { type: "square", vol: 0.07 }); },
    tap(g) { tone(480 + Math.random() * 380, 0, 0.07, { type: "sine", vol: 0.16 }); if (g) SOUNDS.coin(); },
    count() { tone(1500, 0, 0.018, { type: "square", vol: 0.035 }); },
    daily() { [0, 4, 7, 12, 16].forEach((s, i) => tone(note(s), i * 0.08, 0.26, { type: "triangle", vol: 0.17 })); },
    win(tier) {
      const sets = {
        1: [0, 4, 7],
        2: [0, 4, 7, 12],
        3: [-5, 0, 4, 7, 12, 16],
        4: [-12, -5, 0, 4, 7, 12, 16, 19, 24],
      };
      const s = sets[tier] || sets[1];
      const gap = tier >= 3 ? 0.085 : 0.075;
      s.forEach((semi, i) => {
        tone(note(semi), i * gap, 0.3 + (tier >= 3 ? 0.15 : 0), { type: "triangle", vol: 0.17 });
        tone(note(semi + 12), i * gap, 0.2, { type: "sine", vol: 0.06 });
      });
      if (tier >= 2) for (let i = 0; i < 6 + tier * 3; i++) tone(1800 + Math.random() * 2200, 0.1 + i * 0.06, 0.07, { type: "sine", vol: 0.05 });   // sparkle
      if (tier >= 3) { tone(note(-24), 0, 0.5, { type: "sine", vol: 0.3 }); noise(0, 0.25, { freq: 4000, sweep: 800, vol: 0.12 }); }
      if (tier >= 4) { [0, 0.18, 0.36].forEach((d) => tone(note(12 + d * 20), d + 0.45, 0.4, { type: "square", vol: 0.06 })); }
    },
    bigAnnounce() { tone(note(-12), 0, 0.5, { type: "sawtooth", vol: 0.1, slide: note(0) }); },
  };

  function sound(name, arg) {
    const f = SOUNDS[name];
    if (!f || !ensure()) return;
    if ((name === "tick" || name === "scratch" || name === "ping" || name === "rise" || name === "count") && throttle(28)) return;
    try { f(arg); } catch (e) { /* audio problems must never break a game */ }
  }

  // =====================================================================
  // Visual effects
  // =====================================================================
  let canvas = null, c2 = null, parts = [], raf = 0, sprite = null;
  const COLORS = ["#FFC83D", "#FF6B6B", "#4ECDC4", "#B66BFF", "#6BCB77", "#FF9F43", "#54A0FF"];

  function ensureCanvas() {
    if (canvas) return true;
    canvas = document.createElement("canvas");
    canvas.id = "fx-canvas";
    canvas.setAttribute("aria-hidden", "true");
    document.body.appendChild(canvas);
    c2 = canvas.getContext("2d");
    const fit = () => { canvas.width = innerWidth; canvas.height = innerHeight; };
    fit(); window.addEventListener("resize", fit);
    const img = new Image();                                           // the goog coin, as a round sprite
    img.onload = () => {
      const s = document.createElement("canvas"); s.width = s.height = 40;
      const x = s.getContext("2d");
      x.beginPath(); x.arc(20, 20, 18, 0, Math.PI * 2); x.clip();
      x.drawImage(img, 0, 0, 40, 40);
      x.restore && x.restore();
      x.setTransform(1, 0, 0, 1, 0, 0);
      sprite = s;
    };
    img.src = "assets/goog.jpg";
    return true;
  }

  function emit(n, x, y, o = {}) {
    if (reduced() || !ensureCanvas()) return;
    for (let i = 0; i < n; i++) {
      const a = (o.angle !== undefined ? o.angle : -Math.PI / 2) + (Math.random() - 0.5) * (o.spread || Math.PI * 1.2);
      const sp = (o.speed || 9) * (0.4 + Math.random() * 0.8);
      const coin = Math.random() < (o.coins === undefined ? 0.3 : o.coins);
      parts.push({
        x: x + (Math.random() - 0.5) * (o.jitter || 0), y,
        vx: Math.cos(a) * sp, vy: Math.sin(a) * sp, g: 0.32 + Math.random() * 0.1,
        life: 0, max: (o.life || 85) + Math.random() * 40,
        rot: Math.random() * 6, vr: (Math.random() - 0.5) * 0.4,
        size: coin ? 20 + Math.random() * 8 : 6 + Math.random() * 7,
        coin, color: COLORS[(Math.random() * COLORS.length) | 0],
      });
    }
    if (!raf) raf = requestAnimationFrame(loop);
  }
  function loop() {
    c2.clearRect(0, 0, canvas.width, canvas.height);
    parts = parts.filter((p) => p.life < p.max && p.y < canvas.height + 60);
    for (const p of parts) {
      p.life++; p.vy += p.g; p.vx *= 0.992; p.x += p.vx; p.y += p.vy; p.rot += p.vr;
      c2.globalAlpha = Math.min(1, (p.max - p.life) / 25);
      c2.save(); c2.translate(p.x, p.y); c2.rotate(p.rot);
      if (p.coin && sprite) { const s = p.size; c2.scale(Math.abs(Math.cos(p.life * 0.15)) * 0.8 + 0.2, 1); c2.drawImage(sprite, -s / 2, -s / 2, s, s); }
      else { c2.fillStyle = p.color; c2.fillRect(-p.size / 2, -p.size / 4, p.size, p.size / 2); }
      c2.restore();
    }
    c2.globalAlpha = 1;
    raf = parts.length ? requestAnimationFrame(loop) : 0;
    if (!parts.length) c2.clearRect(0, 0, canvas.width, canvas.height);
  }

  function chipPos() {
    const el = $("balance");
    if (el && !el.hidden) { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
    return { x: innerWidth - 80, y: 40 };
  }
  function floatText(text, x, y, cls) {
    const el = document.createElement("div");
    el.className = "fx-float " + (cls || "");
    el.textContent = text;
    el.style.left = x + "px"; el.style.top = y + "px";
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 1500);
  }
  function pulseBalance() {
    const el = $("balance");
    if (!el || reduced()) return;
    el.classList.remove("pulse"); void el.offsetWidth; el.classList.add("pulse");
  }
  function shake(strong) {
    if (reduced()) return;
    document.body.classList.remove("fx-shake", "fx-shake-strong"); void document.body.offsetWidth;
    document.body.classList.add(strong ? "fx-shake-strong" : "fx-shake");
    setTimeout(() => document.body.classList.remove("fx-shake", "fx-shake-strong"), 600);
  }

  let bannerTimer = 0, countRaf = 0;
  function banner(title, amount, tier) {
    let el = $("fx-banner");
    if (!el) {
      el = document.createElement("div"); el.id = "fx-banner"; el.setAttribute("role", "status");
      el.innerHTML = '<div class="fx-title"></div><div class="fx-amount"></div>';
      el.addEventListener("click", () => hideBanner());
      document.body.appendChild(el);
    }
    clearTimeout(bannerTimer); cancelAnimationFrame(countRaf);
    el.className = "show tier" + tier;
    el.querySelector(".fx-title").textContent = title;
    const amt = el.querySelector(".fx-amount");
    if (amount === null || amount === undefined) { amt.textContent = ""; }
    else if (reduced()) { amt.textContent = "+" + fmt.format(amount) + " goog"; }
    else {                                                              // count up to the win
      const t0 = performance.now(), dur = Math.min(1600, 700 + tier * 250);
      const step = (now) => {
        const k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3);
        amt.textContent = "+" + fmt.format(Math.round(amount * e)) + " goog";
        if (k < 1) { if (Math.random() < 0.5) sound("count"); countRaf = requestAnimationFrame(step); }
      };
      countRaf = requestAnimationFrame(step);
    }
    bannerTimer = setTimeout(hideBanner, tier >= 4 ? 3800 : 2800);
  }
  function hideBanner() { const el = $("fx-banner"); if (el) el.classList.remove("show"); }

  // tier by multiplier of the stake: 1 small, 2 nice, 3 big, 4 mega
  function tierOf(m) { return m >= 50 ? 4 : m >= 10 ? 3 : m >= 3 ? 2 : m > 1 ? 1 : 0; }

  // win: total paid out, bet: total staked. Nothing happens for a loss or a refund.
  function celebrate(o) {
    const win = Number(o.win) || 0, bet = Math.max(1, Number(o.bet) || 1);
    const tier = tierOf(win / bet);
    if (tier === 0 || win <= bet) return 0;
    const net = win;
    sound("win", tier);
    const cp = chipPos();
    pulseBalance();
    floatText("+" + fmt.format(net), cp.x, cp.y + 28, "t" + tier);
    const cx = innerWidth / 2, cy = innerHeight * 0.55;
    if (tier === 1) emit(10, cp.x, cp.y + 10, { angle: Math.PI / 2, spread: Math.PI * 0.9, speed: 4, coins: 0.7, life: 60 });
    if (tier === 2) { emit(40, cx, cy, { speed: 11, coins: 0.35 }); emit(12, cp.x, cp.y + 10, { angle: Math.PI / 2, spread: 1.2, speed: 4, coins: 1, life: 60 }); }
    if (tier >= 3) {
      sound("bigAnnounce");
      emit(90, cx * 0.6, cy, { angle: -Math.PI / 3, speed: 15, coins: 0.3 });
      emit(90, cx * 1.4, cy, { angle: -Math.PI * 2 / 3, speed: 15, coins: 0.3 });
      shake(tier >= 4);
      if (window.Music) window.Music.duck(3500);                         // the music steps back for the big win
      banner(tier >= 4 ? "MEGA WIN" : "BIG WIN", net, tier);
    }
    if (tier >= 4) {
      let n = 0;
      const rain = setInterval(() => { emit(14, Math.random() * innerWidth, -10, { angle: Math.PI / 2, spread: 0.6, speed: 3, coins: 0.4, life: 150 }); if (++n > 22) clearInterval(rain); }, 110);
    }
    return tier;
  }

  function announce(title, sub) {
    sound("win", 3);
    shake(false);
    banner(title, null, 3);
    if (sub) { const a = $("fx-banner").querySelector(".fx-amount"); a.textContent = sub; }
    emit(60, innerWidth / 2, innerHeight * 0.55, { speed: 13, coins: 0.2 });
  }

  // =====================================================================
  // mute button + generic click sound
  // =====================================================================
  function paintMute() {
    const b = $("sound-toggle");
    if (!b) return;
    b.textContent = muted ? "🔇" : "🔊";
    b.setAttribute("aria-pressed", String(!muted));
    b.title = muted ? "Sound is off" : "Sound is on";
  }
  document.addEventListener("DOMContentLoaded", () => {
    paintMute();
    const b = $("sound-toggle");
    if (b) b.addEventListener("click", () => {
      muted = !muted;
      try { localStorage.setItem("goog-mute", muted ? "1" : "0"); } catch (e) {}
      paintMute();
      if (!muted) { ensure(); sound("coin"); }
    });
    // every button gets a soft click, except ones that make their own sound
    document.addEventListener("click", (e) => {
      const t = e.target.closest && e.target.closest("button, .btn, a.hub-card, .seg button, .chip-btn");
      if (t && !t.disabled && !t.hasAttribute("data-nosound") && t.id !== "sound-toggle") sound("click");
    }, true);
  });

  window.Fx = { sound, win: celebrate, announce, shake, pulseBalance, emit, floatText, muted: () => muted };
})();
