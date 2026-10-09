(() => {
  "use strict";
  const G = window.Goog;
  if (!G) return; // config missing; app.js already showed a message
  const $ = (id) => document.getElementById(id);
  const { db, fmt } = G;

  const PANELS = ["mines", "crash", "dice", "plinko", "tap"];
  const BET_PANELS = ["mines", "crash", "dice", "plinko"];
  const setMsg = (id, text, kind = "") => G.setStatus($(id), text, kind);

  // ---------- shared ----------
  async function rpc(name, args) {
    const { data, error } = await db.rpc(name, args || {});
    if (error) throw new Error(error.message);
    return data;
  }
  const applyBalance = (res) => { if (res && typeof res.balance === "number") G.setBalance(res.balance); };

  function readBet(id) {
    const n = Math.floor(Number($(id).value));
    if (!Number.isFinite(n) || n < 1) throw new Error("Enter a bet of at least 1 goog.");
    return n;
  }

  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-bet-act]");
    if (!b) return;
    const input = $(b.dataset.betFor);
    const cur = Math.max(1, Math.floor(Number(input.value)) || 1);
    const me = G.me();
    if (b.dataset.betAct === "half") input.value = Math.max(1, Math.floor(cur / 2));
    if (b.dataset.betAct === "double") input.value = cur * 2;
    if (b.dataset.betAct === "max") input.value = Math.max(1, me ? me.goog : 1);
    input.dispatchEvent(new Event("input"));
  });

  const catFace = () => { const img = new Image(); img.src = "assets/goog.jpg"; img.alt = "Cat"; return img; };
  const catImg = new Image();
  catImg.src = "assets/goog.jpg";

  const cssColors = () => {
    const cs = getComputedStyle(document.documentElement);
    const col = (n) => cs.getPropertyValue(n).trim();
    return { line: col("--line"), muted: col("--muted"), ink: col("--ink"), brass: col("--brass"), teal: col("--teal"), error: col("--error"), surface: col("--surface"), paper: col("--paper") };
  };

  function sizeCanvas(canvas) {
    const r = canvas.getBoundingClientRect();
    if (!r.width) return null;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { ctx, w: r.width, h: r.height };
  }

  // =====================================================================
  // Cucumber Boxes (mines)
  // =====================================================================
  const boxEls = [];
  const grid = $("mines-grid");
  for (let i = 0; i < 25; i++) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "box";
    b.disabled = true;
    b.dataset.i = i;
    b.setAttribute("aria-label", "Box " + (i + 1));
    grid.appendChild(b);
    boxEls.push(b);
  }
  // st = { active, bet, mines, revealed[], mult, next, cucumbers[] (only after the round) }
  let mSt = null;
  let mBusy = false;

  function renderMines(st, hit) {
    mSt = st;
    const active = !!st && st.active;
    const over = !!st && !st.active;
    const revealed = new Set(st ? st.revealed : []);
    const cucumbers = new Set(over && st.cucumbers ? st.cucumbers : []);

    boxEls.forEach((b, i) => {
      b.className = "box";
      b.replaceChildren();
      b.disabled = !active || revealed.has(i);
      if (revealed.has(i)) {
        b.classList.add("safe");
        b.appendChild(catFace());
      } else if (over) {
        if (cucumbers.has(i)) {
          b.classList.add("bomb");
          if (i === hit) b.classList.add("hit");
          b.textContent = "🥒";
        } else {
          b.classList.add("ghost");
          b.appendChild(catFace());
        }
      }
    });

    $("mines-start").disabled = active;
    $("mines-count").disabled = active;
    $("mines-bet").disabled = active;
    const k = revealed.size;
    $("mines-mult").textContent = "×" + (st ? Number(st.mult).toFixed(2) : "1.00");
    $("mines-next").textContent = active && st.next ? "×" + Number(st.next).toFixed(2) : "–";
    const cash = $("mines-cash");
    cash.disabled = !(active && k > 0);
    cash.textContent = active && k > 0 ? "Cash out " + fmt.format(Math.floor(st.bet * st.mult)) + " goog" : "Cash out";
  }

  $("mines-count").addEventListener("input", () => { $("mines-count-out").textContent = $("mines-count").value; });

  $("mines-start").onclick = async () => {
    if (mBusy) return;
    mBusy = true;
    try {
      const bet = readBet("mines-bet");
      const mines = Number($("mines-count").value);
      const r = await rpc("mines_start", { p_bet: bet, p_mines: mines });
      applyBalance(r);
      renderMines({ active: true, bet, mines, revealed: [], mult: 1, next: r.next_multiplier });
      setMsg("mines-msg", "Open a box. Find cats, avoid the cucumbers.");
    } catch (e) { setMsg("mines-msg", e.message, "error"); }
    finally { mBusy = false; }
  };

  grid.addEventListener("click", async (e) => {
    const b = e.target.closest(".box");
    if (!b || b.disabled || mBusy || !mSt) return;
    mBusy = true;
    const tile = Number(b.dataset.i);
    try {
      const r = await rpc("mines_reveal", { p_tile: tile });
      applyBalance(r);
      if (r.hit) {
        renderMines({ active: false, bet: mSt.bet, mines: mSt.mines, revealed: r.revealed, mult: 0, cucumbers: r.mine_tiles }, tile);
        setMsg("mines-msg", "🥒 A cucumber! The cat jumped away. You lost " + fmt.format(mSt.bet) + " goog.", "error");
      } else if (r.done) {
        renderMines({ active: false, bet: mSt.bet, mines: mSt.mines, revealed: r.revealed, mult: r.multiplier, cucumbers: r.mine_tiles });
        setMsg("mines-msg", "You found every cat! Cashed out ×" + Number(r.multiplier).toFixed(2) + " for " + fmt.format(r.payout) + " goog.", "ok");
      } else {
        renderMines({ ...mSt, revealed: r.revealed, mult: r.multiplier, next: r.next_multiplier });
        setMsg("mines-msg", "");
      }
    } catch (err) { setMsg("mines-msg", err.message, "error"); }
    finally { mBusy = false; }
  });

  $("mines-cash").onclick = async () => {
    if (mBusy || !mSt) return;
    mBusy = true;
    try {
      const r = await rpc("mines_cashout");
      applyBalance(r);
      renderMines({ active: false, bet: mSt.bet, mines: mSt.mines, revealed: r.revealed, mult: r.multiplier, cucumbers: r.mine_tiles });
      setMsg("mines-msg", "Cashed out ×" + Number(r.multiplier).toFixed(2) + " for " + fmt.format(r.payout) + " goog.", "ok");
    } catch (e) { setMsg("mines-msg", e.message, "error"); }
    finally { mBusy = false; }
  };

  async function minesResume() {
    try {
      const r = await rpc("mines_active");
      if (r.active) {
        $("mines-bet").value = r.bet;
        $("mines-count").value = r.mines;
        $("mines-count-out").textContent = r.mines;
        renderMines({ active: true, bet: r.bet, mines: r.mines, revealed: r.revealed, mult: r.multiplier, next: r.next_multiplier });
        setMsg("mines-msg", "Welcome back. Your round is still running.");
      } else if (!mSt || mSt.active) renderMines(null);
    } catch (e) { setMsg("mines-msg", e.message, "error"); }
  }

  // =====================================================================
  // Cat Rocket (crash)
  // =====================================================================
  const crashCanvas = $("crash-canvas");
  let cDims = null;
  const C = { running: false, t0: 0, rate: 0.09, auto: null, shown: 1, raf: 0, poll: 0, bet: 0, end: null, endAt: 0, endT: 0, busy: false };
  const multAt = (t) => Math.floor(Math.exp(C.rate * Math.min(t, 300)) * 100) / 100;

  function resizeCrash() { const d = sizeCanvas(crashCanvas); if (d) { cDims = d; drawCrash(); } }
  window.addEventListener("resize", () => { if (activeSub === "crash") resizeCrash(); if (activeSub === "plinko") resizePlinko(); });
  catImg.addEventListener("load", () => { if (activeSub === "crash") drawCrash(); if (activeSub === "plinko") drawPlinko(); });

  const niceStep = (raw) => [0.25, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500].find((s) => s >= raw) || 1000;

  function drawCrash() {
    if (!cDims) return;
    const { ctx, w, h } = cDims;
    const k = cssColors();
    ctx.clearRect(0, 0, w, h);
    const t = C.running ? (performance.now() - C.t0) / 1000 : (C.end ? C.endT : 0);
    const m = C.shown;
    const padL = 48, padB = 26, padT = 18, padR = 30;
    const xMax = Math.max(8, t * 1.12);
    const yTop = Math.max(2, m * 1.15, C.auto && C.running ? C.auto * 1.05 : 0);
    const X = (tt) => padL + (tt / xMax) * (w - padL - padR);
    const Y = (mm) => h - padB - ((mm - 1) / (yTop - 1)) * (h - padB - padT);

    ctx.lineWidth = 1; ctx.strokeStyle = k.line; ctx.fillStyle = k.muted;
    ctx.font = "12px Figtree, system-ui, sans-serif"; ctx.textAlign = "right"; ctx.textBaseline = "middle";
    const step = niceStep((yTop - 1) / 4);
    for (let v = 1; v <= yTop + 1e-9; v += step) {
      const y = Y(v);
      ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(w - padR, y); ctx.stroke();
      ctx.fillText(+v.toFixed(2) + "×", padL - 6, y);
    }
    if (C.auto && C.running) { // dashed line for the auto cash-out target
      ctx.setLineDash([6, 5]); ctx.strokeStyle = k.teal;
      ctx.beginPath(); ctx.moveTo(padL, Y(C.auto)); ctx.lineTo(w - padR, Y(C.auto)); ctx.stroke();
      ctx.setLineDash([]);
    }

    const crashed = C.end && C.end.kind === "crashed";
    ctx.beginPath();
    const N = 60;
    for (let i = 0; i <= N; i++) {
      const tt = (t * i) / N;
      const x = X(tt), y = Y(Math.min(Math.exp(C.rate * tt), yTop));
      if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
    }
    ctx.strokeStyle = crashed ? k.error : k.brass; ctx.lineWidth = 3; ctx.lineJoin = "round"; ctx.stroke();

    const tx = X(t), ty = Y(Math.min(Math.exp(C.rate * t), yTop));
    let cy = ty, rot = 0, f = 0;
    if (crashed) { f = (performance.now() - C.endAt) / 1000; cy += f * f * 260; rot = f * 7; } // the cat tumbles down
    if (cy < h + 30) {
      ctx.save();
      ctx.translate(tx, cy); ctx.rotate(rot);
      ctx.beginPath(); ctx.arc(0, 0, 17, 0, Math.PI * 2); ctx.clip();
      if (catImg.complete && catImg.naturalWidth) ctx.drawImage(catImg, -17, -17, 34, 34);
      ctx.restore();
      ctx.beginPath(); ctx.arc(tx, cy, 17, 0, Math.PI * 2);
      ctx.strokeStyle = k.brass; ctx.lineWidth = 2.5; ctx.stroke();
    }
    if (crashed && f < 0.45) { ctx.font = "30px serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillText("💥", tx, ty); }

    ctx.font = "800 44px 'Bricolage Grotesque', Figtree, sans-serif";
    ctx.textAlign = "left"; ctx.textBaseline = "alphabetic";
    ctx.fillStyle = crashed ? k.error : (C.end && C.end.kind === "cashed" ? k.teal : k.ink);
    ctx.fillText(m.toFixed(2) + "×", padL + 14, padT + 44);
  }

  function setCrashButtons(running) {
    $("crash-start").hidden = running;
    $("crash-cash").hidden = !running;
    $("crash-bet").disabled = running;
    $("crash-auto").disabled = running;
  }
  function stopCrashTimers() {
    cancelAnimationFrame(C.raf); C.raf = 0;
    clearInterval(C.poll); C.poll = 0;
  }
  function crashLoop() {
    if (C.running) {
      C.shown = multAt((performance.now() - C.t0) / 1000);
      $("crash-cash").textContent = "Cash out " + fmt.format(Math.floor(C.bet * C.shown)) + " goog";
    }
    drawCrash();
    if (C.running || (C.end && C.end.kind === "crashed" && performance.now() - C.endAt < 1700)) C.raf = requestAnimationFrame(crashLoop);
    else C.raf = 0;
  }
  function beginRun(s, sentAt) {
    stopCrashTimers();
    C.rate = Number(s.rate) || C.rate;
    C.auto = s.auto ? Number(s.auto) : null;
    // the server clock is about half a round trip ahead of the moment the reply arrived
    C.t0 = (sentAt + performance.now()) / 2 - s.elapsed_ms;
    C.bet = s.bet; C.running = true; C.end = null; C.shown = 1;
    setCrashButtons(true);
    C.raf = requestAnimationFrame(crashLoop);
    C.poll = setInterval(pollCrash, 400);
  }
  async function pollCrash() {
    if (!C.running || C.busy) return;
    const sentAt = performance.now();
    try {
      const s = await rpc("crash_status");
      if (!C.running || C.busy) return;
      if (s.status === "active") C.t0 = (sentAt + performance.now()) / 2 - s.elapsed_ms;
      else if (s.status === "none") crashIdle();
      else endRound(s);
    } catch (_) { /* transient; the next poll retries */ }
  }
  // s.status is "lost" (crashed) or "won" (cashed out, manual or automatic)
  function endRound(s) {
    stopCrashTimers();
    C.running = false;
    const crashed = s.status === "lost";
    const mult = crashed ? Number(s.crash_point) : Number(s.multiplier);
    C.end = { kind: crashed ? "crashed" : "cashed" };
    C.endT = Math.log(Math.max(mult, 1)) / C.rate;
    C.endAt = performance.now();
    C.shown = mult;
    setCrashButtons(false);
    $("crash-cash").textContent = "Cash out";
    if (crashed) setMsg("crash-msg", "💥 Crashed at ×" + Number(s.crash_point).toFixed(2) + ". You lost " + fmt.format(s.bet) + " goog.", "error");
    else setMsg("crash-msg", "Cashed out at ×" + mult.toFixed(2) + " for " + fmt.format(s.payout) + " goog. It would have crashed at ×" + Number(s.crash_point).toFixed(2) + ".", "ok");
    applyBalance(s);
    C.raf = requestAnimationFrame(crashLoop);
  }
  function crashIdle() {
    stopCrashTimers();
    C.running = false; C.end = null; C.shown = 1; C.auto = null;
    setCrashButtons(false);
    drawCrash();
  }

  $("crash-start").onclick = async () => {
    if (C.busy) return;
    C.busy = true;
    setMsg("crash-msg", "");
    try {
      const bet = readBet("crash-bet");
      const raw = $("crash-auto").value.trim();
      const auto = raw === "" ? null : Number(raw);
      if (auto !== null && !(auto >= 1.01 && auto <= 1000)) throw new Error("Auto cash-out must be between 1.01 and 1000.");
      const sentAt = performance.now();
      const s = await rpc("crash_start", { p_bet: bet, p_auto: auto });
      applyBalance(s);
      beginRun(s, sentAt);
    } catch (e) { setMsg("crash-msg", e.message, "error"); }
    finally { C.busy = false; }
  };
  $("crash-cash").onclick = async () => {
    if (C.busy || !C.running) return;
    C.busy = true;
    try { endRound(await rpc("crash_cashout")); }
    catch (e) { setMsg("crash-msg", e.message, "error"); }
    finally { C.busy = false; }
  };

  async function crashResume() {
    resizeCrash();
    try {
      const sentAt = performance.now();
      const s = await rpc("crash_status");
      if (s.status === "active") { setMsg("crash-msg", ""); beginRun(s, sentAt); }
      else if (s.status === "none") { if (!C.end) crashIdle(); }
      else endRound(s);
    } catch (e) { setMsg("crash-msg", e.message, "error"); }
  }

  // =====================================================================
  // Cat Dice
  // =====================================================================
  let diceOver = false;
  let diceBusy = false;
  const target = $("dice-target");

  function diceCalc() {
    const tg = Number(target.value);
    const chance = diceOver ? 99.99 - tg : tg; // percent; rolls are 0.00 to 99.99 (matches play_dice)
    return { target: tg, chance, mult: Math.round((99 / chance) * 10000) / 10000 };
  }
  function diceRender() {
    const c = diceCalc();
    $("dice-target-out").textContent = (diceOver ? "Roll over " : "Roll under ") + c.target.toFixed(2);
    $("dice-chance").textContent = c.chance.toFixed(2) + "%";
    $("dice-mult").textContent = "×" + c.mult.toFixed(4);
    const bet = Math.floor(Number($("dice-bet").value)) || 0;
    $("dice-payout").textContent = fmt.format(Math.floor(bet * c.mult));
    const track = $("dice-track");
    track.style.setProperty("--split", c.target + "%");
    track.style.setProperty("--zone-a", diceOver ? "var(--lose)" : "var(--win)");
    track.style.setProperty("--zone-b", diceOver ? "var(--win)" : "var(--lose)");
    $("dice-mode-under").setAttribute("aria-pressed", String(!diceOver));
    $("dice-mode-over").setAttribute("aria-pressed", String(diceOver));
  }
  target.addEventListener("input", diceRender);
  $("dice-bet").addEventListener("input", diceRender);
  $("dice-mode-under").onclick = () => { diceOver = false; diceRender(); };
  $("dice-mode-over").onclick = () => { diceOver = true; diceRender(); };

  $("dice-roll").onclick = async () => {
    if (diceBusy) return;
    diceBusy = true;
    $("dice-roll").disabled = true;
    setMsg("dice-msg", "");
    try {
      const bet = readBet("dice-bet");
      const c = diceCalc();
      const res = await rpc("play_dice", { p_bet: bet, p_target: c.target, p_over: diceOver });
      const marker = $("dice-marker");
      marker.classList.add("rolled");
      marker.style.left = "calc(1.4rem + (100% - 2.8rem) * " + res.roll / 100 + ")";
      $("dice-number").className = "dice-number";
      await new Promise((r) => setTimeout(r, 750)); // let the cat land before showing the result
      const num = $("dice-number");
      num.textContent = Number(res.roll).toFixed(2);
      num.classList.add(res.win ? "win" : "lose");
      setMsg("dice-msg", res.win
        ? "You won " + fmt.format(res.payout - bet) + " goog! (×" + Number(res.multiplier).toFixed(2) + ")"
        : "Not this time. You lost " + fmt.format(bet) + " goog.", res.win ? "ok" : "error");
      const pill = document.createElement("span");
      pill.className = "pill " + (res.win ? "win" : "lose");
      pill.textContent = Number(res.roll).toFixed(2);
      const recent = $("dice-recent");
      recent.prepend(pill);
      while (recent.children.length > 12) recent.lastChild.remove();
      applyBalance(res);
    } catch (e) { setMsg("dice-msg", e.message, "error"); }
    finally { diceBusy = false; $("dice-roll").disabled = false; }
  };

  // =====================================================================
  // Cat Drop (plinko)
  // =====================================================================
  const plinkoCanvas = $("plinko-canvas");
  const PL = { rows: 12, risk: "medium", table: null, tables: {}, dims: null, ball: null, hit: -1, busy: false, raf: 0 };

  function resizePlinko() { const d = sizeCanvas(plinkoCanvas); if (d) { PL.dims = d; drawPlinko(); } }

  function plGeometry() {
    const { w, h } = PL.dims;
    const n = PL.rows, pad = 10, top = 22, slotH = 26;
    const dx = (w - 2 * pad) / (n + 1);
    const rowH = (h - top - slotH - 16) / n;
    const cx = w / 2;
    return { w, h, n, dx, rowH, top, slotH, cx,
      px: (level, rights) => cx + (rights - level / 2) * dx,
      py: (level) => top + level * rowH };
  }

  function drawPlinko() {
    if (!PL.dims) return;
    const g = plGeometry();
    const { ctx } = PL.dims;
    const k = cssColors();
    ctx.clearRect(0, 0, g.w, g.h);

    // pegs
    ctx.fillStyle = k.muted;
    for (let lvl = 0; lvl < g.n; lvl++) {
      for (let j = 0; j <= lvl; j++) {
        ctx.beginPath(); ctx.arc(g.px(lvl, j), g.py(lvl), 3, 0, Math.PI * 2); ctx.fill();
      }
    }
    // slots with multipliers
    if (PL.table) {
      const y = g.py(g.n) + 8;
      const fs = Math.max(9, Math.min(13, g.dx * 0.36));
      ctx.font = "600 " + fs + "px Figtree, system-ui, sans-serif";
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      PL.table.forEach((mult, s) => {
        const x = g.px(g.n, s);
        const wSlot = g.dx * 0.9;
        const good = mult >= 1;
        ctx.fillStyle = s === PL.hit ? (good ? k.teal : k.error) : k.surface;
        ctx.strokeStyle = good ? k.brass : k.line;
        ctx.lineWidth = 1.5;
        ctx.beginPath(); ctx.roundRect(x - wSlot / 2, y, wSlot, g.slotH, 5); ctx.fill(); ctx.stroke();
        ctx.fillStyle = s === PL.hit ? "#fff" : (good ? k.ink : k.muted);
        ctx.fillText((mult >= 100 ? Math.round(mult) : +mult.toFixed(mult >= 10 ? 1 : 2)) + "×", x, y + g.slotH / 2);
      });
    }
    // ball (the cat)
    if (PL.ball) {
      const r = Math.max(8, Math.min(13, g.dx * 0.32));
      ctx.save();
      ctx.translate(PL.ball.x, PL.ball.y);
      ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.clip();
      if (catImg.complete && catImg.naturalWidth) ctx.drawImage(catImg, -r, -r, 2 * r, 2 * r);
      ctx.restore();
      ctx.beginPath(); ctx.arc(PL.ball.x, PL.ball.y, r, 0, Math.PI * 2);
      ctx.strokeStyle = k.brass; ctx.lineWidth = 2; ctx.stroke();
    }
  }

  async function plinkoLoadTable() {
    const key = PL.rows + ":" + PL.risk;
    if (!PL.tables[key]) {
      try { PL.tables[key] = (await rpc("plinko_table", { p_rows: PL.rows, p_risk: PL.risk })).map(Number); }
      catch (e) { setMsg("plinko-msg", e.message, "error"); return; }
    }
    if (key === PL.rows + ":" + PL.risk) { PL.table = PL.tables[key]; PL.hit = -1; PL.ball = null; drawPlinko(); }
  }

  function animateBall(path) {
    return new Promise((resolve) => {
      const g = plGeometry();
      const seg = 150; // ms per peg
      const start = performance.now();
      const total = seg * path.length + 200;
      const rightsAt = [0];
      path.forEach((b) => rightsAt.push(rightsAt[rightsAt.length - 1] + b));
      const step = (now) => {
        const el = now - start;
        const k = Math.min(path.length, Math.floor(el / seg));
        const f = Math.min(1, (el - k * seg) / seg);
        if (k >= path.length) {
          PL.ball = { x: g.px(g.n, rightsAt[g.n]), y: g.py(g.n) + 8 + g.slotH / 2 };
        } else {
          const x0 = g.px(k, rightsAt[k]);
          const x1 = g.px(k + 1, rightsAt[k + 1]);
          const y0 = g.py(k), y1 = k + 1 === g.n ? g.py(g.n) + 8 + g.slotH / 2 : g.py(k + 1);
          const ease = f * f * (3 - 2 * f);
          PL.ball = { x: x0 + (x1 - x0) * ease, y: y0 + (y1 - y0) * f - Math.sin(f * Math.PI) * 7 };
        }
        drawPlinko();
        if (el < total) PL.raf = requestAnimationFrame(step); else resolve();
      };
      PL.raf = requestAnimationFrame(step);
    });
  }

  $("plinko-rows").addEventListener("input", () => {
    PL.rows = Number($("plinko-rows").value);
    $("plinko-rows-out").textContent = PL.rows;
    if (!PL.busy) plinkoLoadTable();
  });
  document.querySelectorAll("[data-risk]").forEach((b) => b.addEventListener("click", () => {
    if (PL.busy) return;
    PL.risk = b.dataset.risk;
    document.querySelectorAll("[data-risk]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    plinkoLoadTable();
  }));

  $("plinko-drop").onclick = async () => {
    if (PL.busy) return;
    PL.busy = true;
    $("plinko-drop").disabled = true; $("plinko-rows").disabled = true;
    setMsg("plinko-msg", "");
    try {
      const bet = readBet("plinko-bet");
      PL.hit = -1;
      const res = await rpc("play_plinko", { p_bet: bet, p_rows: PL.rows, p_risk: PL.risk });
      await animateBall(res.path);
      PL.hit = res.slot;
      drawPlinko();
      const net = res.payout - bet;
      if (net > 0) setMsg("plinko-msg", "×" + Number(res.multiplier).toFixed(2) + ": you won " + fmt.format(net) + " goog!", "ok");
      else if (net === 0) setMsg("plinko-msg", "×" + Number(res.multiplier).toFixed(2) + ": you got your bet back.");
      else setMsg("plinko-msg", "×" + Number(res.multiplier).toFixed(2) + ": you lost " + fmt.format(-net) + " goog.", "error");
      applyBalance(res);
    } catch (e) { setMsg("plinko-msg", e.message, "error"); }
    finally { PL.busy = false; $("plinko-drop").disabled = false; $("plinko-rows").disabled = false; }
  };

  // =====================================================================
  // Tap the goog (free play)
  // =====================================================================
  const DURATION = 15000;
  let tapTimer = null, tapEnd = 0, tapScore = 0, tapBest = 0;
  try { tapBest = Number(localStorage.getItem("goog_tap_best")) || 0; } catch (_) {}
  $("g-best").textContent = tapBest;

  function moveTarget() {
    const arena = $("arena"), t = $("g-target");
    t.style.left = Math.random() * (arena.clientWidth - t.offsetWidth) + "px";
    t.style.top = Math.random() * (arena.clientHeight - t.offsetHeight) + "px";
  }
  function tapStart() {
    tapScore = 0;
    $("g-score").textContent = 0;
    $("g-start").hidden = true;
    $("g-target").hidden = false;
    setMsg("g-msg", "");
    tapEnd = performance.now() + DURATION;
    moveTarget();
    tapTimer = setInterval(() => {
      const left = Math.max(0, tapEnd - performance.now());
      $("g-time").textContent = (left / 1000).toFixed(1);
      if (left <= 0) tapFinish();
    }, 100);
  }
  function tapStop() {
    clearInterval(tapTimer);
    tapTimer = null;
    $("g-target").hidden = true;
    $("g-start").hidden = false;
    $("g-start").textContent = "Start";
    $("g-time").textContent = (DURATION / 1000).toFixed(1);
  }
  function tapFinish() {
    tapStop();
    $("g-start").textContent = "Play again";
    let msg = "Time's up. You tapped " + tapScore + " time" + (tapScore === 1 ? "" : "s") + ".";
    if (tapScore > tapBest) {
      tapBest = tapScore;
      $("g-best").textContent = tapBest;
      try { localStorage.setItem("goog_tap_best", String(tapBest)); } catch (_) {}
      msg += " New best!";
    }
    setMsg("g-msg", msg, "ok");
  }
  $("g-start").onclick = tapStart;
  $("g-target").addEventListener("pointerdown", (e) => {
    e.preventDefault();
    if (!tapTimer) return;
    tapScore += 1;
    $("g-score").textContent = tapScore;
    moveTarget();
  });

  // =====================================================================
  // Navigation between hub and games
  // =====================================================================
  let activeSub = null;

  function applyGates() {
    const li = G.loggedIn();
    BET_PANELS.forEach((p) => { $("gate-" + p).hidden = li; $("play-" + p).hidden = !li; });
  }

  function leave() {
    stopCrashTimers();   // an unfinished flight keeps running on the server; it resumes when you return
    tapStop();
  }

  function show(sub) {
    activeSub = PANELS.includes(sub) ? sub : null;
    $("games-hub").hidden = !!activeSub;
    $("games-back").hidden = !activeSub;
    PANELS.forEach((p) => ($("game-" + p).hidden = p !== activeSub));
    leave();
    applyGates();
    if (!G.loggedIn()) { renderMines(null); crashIdle(); return; }
    if (activeSub === "mines") minesResume();
    if (activeSub === "crash") crashResume();
    if (activeSub === "dice") diceRender();
    if (activeSub === "plinko") { resizePlinko(); plinkoLoadTable(); }
  }

  window.GoogGames = { show, leave, refresh: () => show(activeSub) };
  diceRender();
  renderMines(null);
})();
