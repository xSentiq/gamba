// Cat Slots, Cat Tower, Cat Roulette and Scratch Cards. The server decides every result; this file only shows it.
(() => {
  "use strict";
  const G = window.Goog;
  const GG = window.GoogGames;
  if (!G || !GG) return; // config missing; app.js already showed a message
  const $ = (id) => document.getElementById(id);
  const { fmt, rpc } = G;
  const setMsg = (id, text, kind = "") => G.setStatus($(id), text, kind);
  const applyBalance = (res) => { if (res && typeof res.balance === "number") G.setBalance(res.balance); };
  const reduced = () => !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  const sleep = (ms) => new Promise((r) => setTimeout(r, reduced() ? Math.min(ms, 30) : ms));
  const money = (n) => fmt.format(Math.round(n * 100) / 100);

  function readBet(id) {
    const n = Math.floor(Number($(id).value));
    if (!Number.isFinite(n) || n < 1) throw new Error("Enter a bet of at least 1 goog.");
    return n;
  }
  const colors = () => GG.shared.cssColors();

  // =====================================================================
  // CAT SLOTS
  // =====================================================================
  // Same 20 paylines as the server (row per reel: 0 top, 1 middle, 2 bottom)
  const LINES = [
    [1,1,1,1,1],[0,0,0,0,0],[2,2,2,2,2],[0,1,2,1,0],[2,1,0,1,2],
    [0,0,1,2,2],[2,2,1,0,0],[1,0,0,0,1],[1,2,2,2,1],[0,1,1,1,0],
    [2,1,1,1,2],[1,0,1,2,1],[1,2,1,0,1],[0,1,0,1,0],[2,1,2,1,2],
    [1,1,0,1,1],[1,1,2,1,1],[0,0,2,0,0],[2,2,0,2,2],[0,2,2,2,0]];
  const symUrl = (s) => (s <= 6 ? G.catUrl(s) : s === 7 ? "assets/goog.jpg" : "assets/cats/drooling.jpg");

  const S = { risk: "medium", busy: false, auto: false, left: 0, session: 0, cells: [], info: {} };
  const reelsEl = $("slot-reels");
  for (let row = 0; row < 3; row++) {
    for (let reel = 0; reel < 5; reel++) {
      const el = document.createElement("div");
      el.className = "cell";
      const img = new Image();
      img.alt = "";
      el.appendChild(img);
      reelsEl.appendChild(el);
      S.cells[reel * 3 + row] = el;
    }
  }
  const cellEl = (reel, row) => S.cells[reel * 3 + row];
  function setCell(reel, row, sym) {
    const el = cellEl(reel, row);
    el.dataset.sym = sym;
    el.firstChild.src = symUrl(sym);
  }
  function randomSym() { return 1 + Math.floor(Math.random() * 8); }
  function fillRandom() {
    for (let r = 0; r < 5; r++) for (let w = 0; w < 3; w++) setCell(r, w, 1 + Math.floor(Math.random() * 6));
  }
  function clearHighlights() { S.cells.forEach((c) => c.classList.remove("win", "dim")); }

  async function animateReels(grid, fast) {
    clearHighlights();
    if (reduced()) {
      for (let r = 0; r < 5; r++) for (let w = 0; w < 3; w++) setCell(r, w, grid[r][w]);
      return;
    }
    const t0 = performance.now();
    const stopAt = [0, 1, 2, 3, 4].map((r) => (fast ? 260 : 650) + r * (fast ? 100 : 230));
    const stopped = [false, false, false, false, false];
    S.cells.forEach((c) => c.classList.add("spinning"));
    await new Promise((resolve) => {
      const iv = setInterval(() => {
        const el = performance.now() - t0;
        for (let r = 0; r < 5; r++) {
          if (stopped[r]) continue;
          if (el >= stopAt[r]) {
            stopped[r] = true;
            for (let w = 0; w < 3; w++) { setCell(r, w, grid[r][w]); cellEl(r, w).classList.remove("spinning"); }
          } else {
            for (let w = 0; w < 3; w++) setCell(r, w, randomSym());
          }
        }
        if (stopped.every(Boolean)) { clearInterval(iv); resolve(); }
      }, 70);
    });
  }

  function highlightWins(grid, wins) {
    clearHighlights();
    const hit = new Set();
    (wins || []).forEach((w) => {
      for (let reel = 0; reel < w.count; reel++) hit.add(reel * 3 + LINES[w.line - 1][reel]);
    });
    let scat = 0;
    for (let r = 0; r < 5; r++) for (let w = 0; w < 3; w++) if (grid[r][w] === 8) scat++;
    if (scat >= 3) for (let r = 0; r < 5; r++) for (let w = 0; w < 3; w++) if (grid[r][w] === 8) hit.add(r * 3 + w);
    if (!hit.size) return;
    S.cells.forEach((c, i) => c.classList.add(hit.has(i) ? "win" : "dim"));
  }

  function slotTotal() { return (Math.floor(Number($("slots-bet").value)) || 0) * Number($("slots-lines").value); }
  // ---- payline viewer ----
  const lineColor = (i) => "hsl(" + Math.round((i * 137.5) % 360) + " 70% 50%)";
  function lineSvg(idx, opts) {
    const NS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("viewBox", "0 0 5 3");
    svg.setAttribute("aria-hidden", "true");
    for (let r = 0; r < 5; r++) for (let w = 0; w < 3; w++) {
      const c = document.createElementNS(NS, "rect");
      c.setAttribute("x", r + 0.06); c.setAttribute("y", w + 0.06);
      c.setAttribute("width", 0.88); c.setAttribute("height", 0.88); c.setAttribute("rx", 0.12);
      c.setAttribute("class", "pl-cell");
      svg.appendChild(c);
    }
    idx.forEach((i) => {
      const pl = document.createElementNS(NS, "polyline");
      pl.setAttribute("points", LINES[i].map((row, reel) => (reel + 0.5) + "," + (row + 0.5)).join(" "));
      pl.setAttribute("class", "pl-line");
      pl.setAttribute("stroke", lineColor(i));
      pl.setAttribute("stroke-width", opts.thick);
      svg.appendChild(pl);
      const d = document.createElementNS(NS, "circle");
      d.setAttribute("cx", 0.5); d.setAttribute("cy", LINES[i][0] + 0.5); d.setAttribute("r", opts.thick * 0.9);
      d.setAttribute("fill", lineColor(i));
      svg.appendChild(d);
    });
    return svg;
  }
  S.plSel = 0; // 0 = show all active lines, otherwise a single line number
  function renderPaylines() {
    const n = Number($("slots-lines").value);
    $("slots-lines-n").textContent = n; $("slots-lines-n2").textContent = n;
    const main = $("payline-main"), th = $("payline-thumbs");
    if (S.plSel > n) S.plSel = 0;
    const show = S.plSel ? [S.plSel - 1] : Array.from({ length: n }, (_, i) => i);
    main.replaceChildren(lineSvg(show, { thick: S.plSel ? 0.1 : 0.06 }));
    if (!th.children.length) {
      for (let i = 0; i < 20; i++) {
        const b = document.createElement("button");
        b.type = "button"; b.className = "payline-thumb"; b.dataset.line = i + 1;
        b.setAttribute("aria-label", "Line " + (i + 1));
        const t = document.createElement("span"); t.textContent = i + 1;
        b.append(lineSvg([i], { thick: 0.14 }), t);
        b.addEventListener("click", () => { S.plSel = S.plSel === i + 1 ? 0 : i + 1; renderPaylines(); });
        th.appendChild(b);
      }
    }
    [...th.children].forEach((b, i) => {
      b.classList.toggle("off", i + 1 > n);
      b.disabled = i + 1 > n;
      b.setAttribute("aria-pressed", String(S.plSel === i + 1));
    });
  }

  function slotRender() {
    renderPaylines();
    $("slots-lines-out").textContent = $("slots-lines").value;
    $("slots-total").textContent = fmt.format(slotTotal());
  }
  function setSlotLock(on) {
    S.busy = on;
    ["slots-bet", "slots-lines"].forEach((id) => ($(id).disabled = on || S.auto));
    document.querySelectorAll("[data-slot-risk]").forEach((b) => (b.disabled = on || S.auto));
    $("slots-spin").disabled = on || S.auto;
    $("slots-auto-count").disabled = S.auto;
  }
  function setAutoUI() {
    const b = $("slots-auto");
    b.textContent = S.auto ? "Stop auto-play (" + S.left + " left)" : "Start auto-play";
    setSlotLock(S.busy);
  }
  function setSession(delta) {
    S.session += delta;
    $("slots-session").textContent = (S.session > 0 ? "+" : "") + fmt.format(S.session);
  }

  function banner(res, text) {
    const el = $("slot-banner");
    if (!text) { el.hidden = true; el.replaceChildren(); $("slot-machine").classList.remove("free"); return; }
    el.hidden = false;
    el.replaceChildren();
    const img = new Image(); img.src = "assets/cats/drooling.jpg"; img.alt = "";
    const span = document.createElement("span"); span.textContent = text;
    el.append(img, span);
    $("slot-machine").classList.add("free");
  }

  async function spinOnce(fast) {
    const perLine = readBet("slots-bet");
    const lines = Number($("slots-lines").value);
    setSlotLock(true);
    try {
      const res = await rpc("play_slots", { p_per_line: perLine, p_lines: lines, p_risk: S.risk });
      G.setBalance(res.balance - res.payout);                     // the bet is gone, the win is not shown yet
      setMsg("slots-msg", "");
      $("slot-win").textContent = "…"; $("slot-win").className = "slot-win";
      await animateReels(res.grid, fast);
      highlightWins(res.grid, res.wins);
      const lineText = res.wins.length ? res.wins.length + (res.wins.length === 1 ? " line pays " : " lines pay ") + money(res.base_win) + " goog" : "No win";
      $("slot-win").textContent = lineText;
      if (res.free_spins > 0) {
        const extra = res.scatter_win > 0 ? " Bonus pay " + money(res.scatter_win) + " goog." : "";
        $("slot-win").textContent = res.scatters + " drooling cats!" + extra;
        await sleep(1400);
        await playFree(res, fast);
      } else if (res.payout > 0) {
        $("slot-win").textContent = "Win " + fmt.format(res.payout) + " goog";
      }
      const net = res.payout - res.total_bet;
      $("slots-lastwin").textContent = fmt.format(res.payout);
      $("slot-win").classList.toggle("big", res.payout >= res.total_bet * 5);
      setSession(net);
      G.setBalance(res.balance);
      return res;
    } finally {
      setSlotLock(false);
    }
  }

  async function playFree(res, fast) {
    const n = res.free.length;
    let running = 0;
    banner(res, n + " free games. All wins pay double.");
    await sleep(1200);
    for (let i = 0; i < n; i++) {
      const f = res.free[i];
      banner(res, "Free game " + (i + 1) + " of " + n + ". Won so far: " + money(running) + " goog");
      await animateReels(f.grid, true);
      highlightWins(f.grid, f.wins);
      running += Number(f.win);
      $("slot-win").textContent = f.win > 0 ? "+" + money(f.win) + " goog" : "No win";
      await sleep(f.win > 0 ? 900 : 450);
    }
    banner(res, "Free games finished. Free game wins: " + money(res.free_win) + " goog");
    $("slot-win").textContent = "Total win " + fmt.format(res.payout) + " goog";
    await sleep(1800);
    banner(res, null);
  }

  $("slots-spin").onclick = async () => {
    if (S.busy || S.auto) return;
    try { await spinOnce(false); } catch (e) { setMsg("slots-msg", e.message, "error"); }
  };

  async function runAuto() {
    S.auto = true; S.left = Number($("slots-auto-count").value); setAutoUI();
    while (S.auto && S.left > 0) {
      let res;
      try { res = await spinOnce(true); }
      catch (e) { setMsg("slots-msg", e.message, "error"); break; }
      S.left--; setAutoUI();
      if (res.free_spins > 0 && $("slots-stop-free").checked) { setMsg("slots-msg", "Auto-play stopped: free games.", "ok"); break; }
      if ($("slots-stop-big").checked && res.payout >= res.total_bet * 20) { setMsg("slots-msg", "Auto-play stopped: big win.", "ok"); break; }
      const me = G.me();
      if (me && me.goog < slotTotal()) { setMsg("slots-msg", "Auto-play stopped: not enough goog for the next spin."); break; }
      await sleep(res.payout > 0 ? 700 : 250);
    }
    S.auto = false; S.left = 0; setAutoUI();
  }
  $("slots-auto").onclick = () => {
    if (S.auto) { S.auto = false; setAutoUI(); return; }   // the running spin finishes, then the loop ends
    if (S.busy) return;
    runAuto();
  };

  document.querySelectorAll("[data-slot-risk]").forEach((b) => b.addEventListener("click", () => {
    if (S.busy || S.auto) return;
    S.risk = b.dataset.slotRisk;
    document.querySelectorAll("[data-slot-risk]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    loadPaytable();
  }));
  ["slots-bet", "slots-lines"].forEach((id) => $(id).addEventListener("input", slotRender));

  async function loadPaytable() {
    const box = $("slots-paytable");
    try {
      if (!S.info[S.risk]) S.info[S.risk] = await rpc("slots_info", { p_risk: S.risk });
      const info = S.info[S.risk];
      const t = document.createElement("table"); t.className = "pay-table";
      t.innerHTML = "<thead><tr><th>Cat</th><th class='num'>3 in a row</th><th class='num'>4 in a row</th><th class='num'>5 in a row</th></tr></thead>";
      const tb = document.createElement("tbody");
      for (let s = 1; s <= 6; s++) {
        const tr = document.createElement("tr");
        const first = document.createElement("td");
        const img = new Image(); img.src = symUrl(s); img.alt = "";
        first.append(img, document.createTextNode("Cat " + s));
        tr.appendChild(first);
        info.pay[s].forEach((v) => { const td = document.createElement("td"); td.className = "num"; td.textContent = "×" + Number(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }); tr.appendChild(td); });
        tb.appendChild(tr);
      }
      t.appendChild(tb);
      const notes = document.createElement("div");
      notes.innerHTML =
        "<p class='sub small'>Pays are multiples of your bet per line, from the left reel. The goog cat is wild and replaces any cat. " +
        "Three, four or five drooling cats anywhere pay ×1, ×5 or ×25 of your total bet and start 8, 12 or 20 free games where all wins are doubled. " +
        "Free games cannot be retriggered. Every risk level returns 99% over time; low risk wins small and often, high risk wins big and rarely. " +
        "Small wins are rounded up or down at random, in proportion to the fraction, so nothing is lost to rounding.</p>";
      box.replaceChildren(t, notes);
    } catch (e) { box.textContent = e.message; }
  }

  GG.register("slots", {
    show() { slotRender(); if (!S.session) fillRandom(); loadPaytable(); },
    leave() { S.auto = false; S.left = 0; setAutoUI(); },
  });
  fillRandom();
  slotRender();

  // =====================================================================
  // CAT TOWER
  // =====================================================================
  const DIFFS = {
    easy:   "4 tiles on every floor, 1 spray bottle.",
    medium: "3 tiles on every floor, 1 spray bottle.",
    hard:   "2 tiles on every floor, 1 spray bottle.",
    expert: "3 tiles on every floor, 2 spray bottles.",
  };
  const T = { diff: "medium", ladders: {}, st: null, over: null, busy: false };

  async function towerLadder(diff) {
    if (!T.ladders[diff]) T.ladders[diff] = await rpc("tower_ladder", { p_diff: diff });
    return T.ladders[diff];
  }

  // st = { active, bet, tiles, traps, rows, level, picks[], mult, next }; over = { masks, hitTile, won }
  function renderTower() {
    const board = $("tower-board");
    const lad = T.ladders[T.diff];
    board.replaceChildren();
    if (!lad) return;
    const st = T.st;
    const rows = lad.rows, tiles = st ? st.tiles : lad.tiles;
    const level = st ? st.level : 0;
    const active = !!st && st.active;
    for (let r = rows - 1; r >= 0; r--) {
      const row = document.createElement("div");
      row.className = "tower-row" + (active && r === level ? " current" : "") + (st && r < level ? " cleared" : "") + (T.over ? " over" : "");
      const m = document.createElement("div");
      m.className = "tower-mult";
      m.textContent = "×" + Number(lad.multipliers[r]).toFixed(2);
      const tilesEl = document.createElement("div");
      tilesEl.className = "tower-tiles";
      for (let t = 0; t < tiles; t++) {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "t-tile";
        b.dataset.tile = t;
        b.setAttribute("aria-label", "Floor " + (r + 1) + ", tile " + (t + 1));
        const picked = st && r < st.picks.length && st.picks[r] === t;
        const isTrap = T.over && (T.over.masks[r] & (1 << t)) !== 0;
        if (picked) {
          b.classList.add("safe");
          const img = new Image(); img.src = G.randCat(); img.alt = "Cat"; b.appendChild(img);
        } else if (T.over && st && r === T.over.hitLevel && t === T.over.hitTile) {
          b.classList.add("trap", "hit"); b.textContent = "💦";
        } else if (T.over) {
          if (isTrap) { b.classList.add("trap"); b.textContent = "💦"; } else b.classList.add("ghost");
        }
        b.disabled = !(active && r === level);
        tilesEl.appendChild(b);
      }
      row.append(m, tilesEl);
      board.appendChild(row);
    }
    const mult = st && st.level > 0 ? st.mult : 1;
    $("tower-mult").textContent = "×" + Number(mult).toFixed(2);
    $("tower-next").textContent = active && st.next ? "×" + Number(st.next).toFixed(2) : "–";
    $("tower-start").disabled = active || T.busy;
    $("tower-bet").disabled = active;
    document.querySelectorAll("[data-diff]").forEach((b) => (b.disabled = active));
    const cash = $("tower-cash");
    cash.disabled = !(active && st.level > 0);
    cash.textContent = active && st.level > 0 ? "Cash out " + fmt.format(Math.floor(st.bet * st.mult)) + " goog" : "Cash out";
  }

  async function setDiff(d) {
    T.diff = d;
    document.querySelectorAll("[data-diff]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.diff === d)));
    $("tower-diff-note").textContent = DIFFS[d];
    try { await towerLadder(d); } catch (e) { setMsg("tower-msg", e.message, "error"); }
    renderTower();
  }
  document.querySelectorAll("[data-diff]").forEach((b) => b.addEventListener("click", () => { if (!(T.st && T.st.active)) setDiff(b.dataset.diff); }));

  $("tower-start").onclick = async () => {
    if (T.busy) return;
    T.busy = true;
    try {
      const bet = readBet("tower-bet");
      const r = await rpc("tower_start", { p_bet: bet, p_diff: T.diff });
      applyBalance(r);
      T.over = null;
      T.st = { active: true, bet, tiles: r.tiles, traps: r.traps, rows: r.rows, level: 0, picks: [], mult: 1, next: r.next_multiplier };
      setMsg("tower-msg", "Pick a tile on the bottom floor. Avoid the spray bottles.");
    } catch (e) { setMsg("tower-msg", e.message, "error"); }
    finally { T.busy = false; renderTower(); }
  };

  $("tower-board").addEventListener("click", async (e) => {
    const b = e.target.closest(".t-tile");
    if (!b || b.disabled || T.busy || !T.st || !T.st.active) return;
    T.busy = true;
    const tile = Number(b.dataset.tile);
    try {
      const r = await rpc("tower_pick", { p_tile: tile });
      applyBalance(r);
      if (r.hit) {
        T.over = { masks: r.trap_masks, hitLevel: r.level, hitTile: tile, won: false };
        T.st = { ...T.st, active: false, picks: r.picks };
        setMsg("tower-msg", "💦 Spray bottle! The cat tumbled off. You lost " + fmt.format(T.st.bet) + " goog.", "error");
      } else if (r.done) {
        T.over = { masks: r.trap_masks, hitLevel: -1, hitTile: -1, won: true };
        T.st = { ...T.st, active: false, level: r.level, picks: r.picks, mult: r.multiplier, next: null };
        setMsg("tower-msg", "You reached the top! Cashed out ×" + Number(r.multiplier).toFixed(2) + " for " + fmt.format(r.payout) + " goog.", "ok");
      } else {
        T.st = { ...T.st, level: r.level, picks: r.picks, mult: r.multiplier, next: r.next_multiplier };
        setMsg("tower-msg", "");
      }
    } catch (err) { setMsg("tower-msg", err.message, "error"); }
    finally { T.busy = false; renderTower(); }
  });

  $("tower-cash").onclick = async () => {
    if (T.busy || !T.st || !T.st.active) return;
    T.busy = true;
    try {
      const r = await rpc("tower_cashout");
      applyBalance(r);
      T.over = { masks: r.trap_masks, hitLevel: -1, hitTile: -1, won: true };
      T.st = { ...T.st, active: false, level: r.level, picks: r.picks, mult: r.multiplier, next: null };
      setMsg("tower-msg", "Cashed out ×" + Number(r.multiplier).toFixed(2) + " for " + fmt.format(r.payout) + " goog.", "ok");
    } catch (e) { setMsg("tower-msg", e.message, "error"); }
    finally { T.busy = false; renderTower(); }
  };

  async function towerShow() {
    try {
      const a = await rpc("tower_active");
      if (a.active) {
        $("tower-bet").value = a.bet;
        await towerLadder(a.difficulty);
        T.over = null;
        T.st = { active: true, bet: a.bet, tiles: a.tiles, traps: a.traps, rows: a.rows, level: a.level, picks: a.picks, mult: a.multiplier, next: a.next_multiplier };
        await setDiff(a.difficulty);
        setMsg("tower-msg", "Welcome back. Your climb is still running.");
        return;
      }
    } catch (e) { setMsg("tower-msg", e.message, "error"); }
    if (!T.st || T.st.active) T.st = null;
    await setDiff(T.diff);
  }
  GG.register("tower", { show: towerShow });

  // =====================================================================
  // CAT ROULETTE
  // =====================================================================
  const ORDER = [0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26];
  const REDS = new Set([1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
  const numColor = (n) => (n === 0 ? "green" : REDS.has(n) ? "red" : "black");
  const R = { chip: 5, bets: new Map(), order: [], last: null, busy: false, wheel: 0, ball: null, ballCat: new Image(), raf: 0, dims: null };
  R.ballCat.src = G.catUrl(5);
  const betKey = (type, value) => type + ":" + (value == null ? "" : value);

  const board = $("roulette-board");
  function addBetButton(label, type, value, cls, col, row, span) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "rb " + (cls || "");
    b.dataset.type = type;
    if (value != null) b.dataset.value = value;
    b.textContent = label;
    b.setAttribute("aria-label", type === "straight" ? "Number " + label : label);
    if (col) b.style.gridColumn = col + (span ? " / span " + span : "");
    if (row) b.style.gridRow = row;
    board.appendChild(b);
    return b;
  }
  addBetButton("0", "straight", 0, "zero green");
  for (let k = 0; k < 12; k++) {
    for (let r = 0; r < 3; r++) {
      const n = k * 3 + (3 - r);                         // top row has 3, 6, 9 ...
      addBetButton(String(n), "straight", n, numColor(n), 2 + k, 1 + r);
    }
  }
  [3, 2, 1].forEach((c, i) => addBetButton("2:1", "column", c, "colbet", 14, 1 + i));
  ["1st 12", "2nd 12", "3rd 12"].forEach((t, i) => addBetButton(t, "dozen", i + 1, "dozen", 2 + i * 4, 4, 4));
  [["1–18", "low", ""], ["Even", "even", ""], ["Red", "red", "red"], ["Black", "black", "black"], ["Odd", "odd", ""], ["19–36", "high", ""]]
    .forEach(([t, type, cls], i) => addBetButton(t, type, null, "outside " + cls, 2 + i * 2, 5, 2));

  function renderBets() {
    let total = 0;
    board.querySelectorAll(".rb").forEach((b) => {
      const key = betKey(b.dataset.type, b.dataset.value);
      const amt = R.bets.get(key) || 0;
      total += amt;
      let st = b.querySelector(".stack");
      if (amt) {
        if (!st) { st = document.createElement("span"); st.className = "stack"; b.appendChild(st); }
        st.textContent = amt >= 1000 ? Math.round(amt / 100) / 10 + "k" : amt;
      } else if (st) st.remove();
    });
    $("roulette-total").textContent = fmt.format(total);
    $("roulette-count").textContent = R.bets.size;
    $("roulette-spin").disabled = R.busy || total === 0;
    $("roulette-repeat").disabled = R.busy || !R.last;
  }
  board.addEventListener("click", (e) => {
    const b = e.target.closest(".rb");
    if (!b || R.busy) return;
    const key = betKey(b.dataset.type, b.dataset.value);
    R.bets.set(key, (R.bets.get(key) || 0) + R.chip);
    R.order.push({ key, amount: R.chip });
    board.querySelectorAll(".won").forEach((x) => x.classList.remove("won"));
    renderBets();
  });
  document.querySelectorAll("[data-chip]").forEach((b) => b.addEventListener("click", () => {
    R.chip = Number(b.dataset.chip);
    document.querySelectorAll("[data-chip]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
  }));
  $("roulette-undo").onclick = () => {
    if (R.busy) return;
    const last = R.order.pop();
    if (!last) return;
    const left = (R.bets.get(last.key) || 0) - last.amount;
    if (left > 0) R.bets.set(last.key, left); else R.bets.delete(last.key);
    renderBets();
  };
  $("roulette-clear").onclick = () => { if (R.busy) return; R.bets.clear(); R.order = []; renderBets(); };
  $("roulette-repeat").onclick = () => {
    if (R.busy || !R.last) return;
    R.bets = new Map(R.last); R.order = [...R.last].map(([key, amount]) => ({ key, amount }));
    renderBets();
  };

  // wheel drawing
  const rCanvas = $("roulette-canvas");
  function resizeRoulette() {
    const d = GG.shared.sizeCanvas(rCanvas);
    if (d) { R.dims = d; drawWheel(); }
  }
  window.addEventListener("resize", () => { if ($("game-roulette") && !$("game-roulette").hidden) resizeRoulette(); });
  R.ballCat.addEventListener("load", () => drawWheel());

  function drawWheel() {
    if (!R.dims) return;
    const { ctx, w, h } = R.dims;
    const k = colors();
    ctx.clearRect(0, 0, w, h);
    const cx = w / 2, cy = h / 2, rOut = w / 2 - 30, rIn = rOut * 0.58, sector = (Math.PI * 2) / 37;

    // rim
    ctx.beginPath(); ctx.arc(cx, cy, rOut + 8, 0, Math.PI * 2); ctx.fillStyle = k.brass; ctx.fill();
    ctx.beginPath(); ctx.arc(cx, cy, rOut + 2, 0, Math.PI * 2); ctx.fillStyle = k.paper; ctx.fill();

    for (let i = 0; i < 37; i++) {
      const n = ORDER[i];
      const a = R.wheel + i * sector - Math.PI / 2;      // centre of this pocket
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(a - sector / 2) * rIn, cy + Math.sin(a - sector / 2) * rIn);
      ctx.arc(cx, cy, rOut, a - sector / 2, a + sector / 2);
      ctx.arc(cx, cy, rIn, a + sector / 2, a - sector / 2, true);
      ctx.closePath();
      ctx.fillStyle = n === 0 ? "#1F7A6D" : REDS.has(n) ? "#B3261E" : "#1b2433";
      ctx.fill();
      ctx.strokeStyle = "rgba(255,255,255,.35)"; ctx.lineWidth = 1; ctx.stroke();
      ctx.save();
      ctx.translate(cx + Math.cos(a) * (rOut * 0.86), cy + Math.sin(a) * (rOut * 0.86));
      ctx.rotate(a + Math.PI / 2);
      ctx.fillStyle = "#fff"; ctx.font = "600 " + Math.max(9, rOut * 0.075) + "px 'Comic Sans MS', 'Comic Neue', cursive";
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.fillText(String(n), 0, 0);
      ctx.restore();
    }
    ctx.beginPath(); ctx.arc(cx, cy, rIn - 2, 0, Math.PI * 2); ctx.fillStyle = k.surface; ctx.fill();
    ctx.strokeStyle = k.brass; ctx.lineWidth = 3; ctx.stroke();
    ctx.beginPath(); ctx.arc(cx, cy, rIn * 0.22, 0, Math.PI * 2); ctx.fillStyle = k.brass; ctx.fill();

    // pointer
    ctx.beginPath(); ctx.moveTo(cx, cy - rOut - 6); ctx.lineTo(cx - 9, cy - rOut - 24); ctx.lineTo(cx + 9, cy - rOut - 24); ctx.closePath();
    ctx.fillStyle = k.ink; ctx.fill();

    // the cat ball
    const bl = R.ball || { angle: -Math.PI / 2, radius: rOut * 0.86 };
    const bx = cx + Math.cos(bl.angle) * (bl.radius), by = cy + Math.sin(bl.angle) * (bl.radius);
    const br = Math.max(10, rOut * 0.1);
    ctx.save();
    ctx.beginPath(); ctx.arc(bx, by, br, 0, Math.PI * 2); ctx.clip();
    if (R.ballCat.complete && R.ballCat.naturalWidth) ctx.drawImage(R.ballCat, bx - br, by - br, br * 2, br * 2);
    else { ctx.fillStyle = k.brass; ctx.fillRect(bx - br, by - br, br * 2, br * 2); }
    ctx.restore();
    ctx.beginPath(); ctx.arc(bx, by, br, 0, Math.PI * 2); ctx.strokeStyle = k.brass; ctx.lineWidth = 2.5; ctx.stroke();
  }

  function spinWheel(number) {
    return new Promise((resolve) => {
      const { w } = R.dims;
      const rOut = w / 2 - 30;
      const sector = (Math.PI * 2) / 37, idx = ORDER.indexOf(number);
      const w0 = R.wheel;
      const turns = Math.ceil((w0 + 5 * Math.PI * 2 + idx * sector) / (Math.PI * 2));
      const wEnd = turns * Math.PI * 2 - idx * sector;
      const dur = 4200, t0 = performance.now();
      R.ballCat.src = G.randCat();
      const ease = (t) => 1 - Math.pow(1 - t, 3);
      const step = (now) => {
        const t = Math.min(1, (now - t0) / dur), e = ease(t);
        R.wheel = w0 + (wEnd - w0) * e;
        const settle = Math.min(1, Math.max(0, (t - 0.55) / 0.45));
        R.ball = {
          angle: -Math.PI / 2 - (1 - e) * Math.PI * 14,
          radius: rOut * 0.97 - (rOut * 0.97 - rOut * 0.86) * (settle * settle * (3 - 2 * settle)),
        };
        drawWheel();
        if (t < 1) R.raf = requestAnimationFrame(step); else { R.ball = { angle: -Math.PI / 2, radius: rOut * 0.86 }; drawWheel(); resolve(); }
      };
      R.raf = requestAnimationFrame(step);
    });
  }
  function jumpWheel(number) {
    const idx = ORDER.indexOf(number);
    R.wheel = -idx * ((Math.PI * 2) / 37);
    R.ball = null;
    drawWheel();
  }

  $("roulette-spin").onclick = async () => {
    if (R.busy || !R.bets.size) return;
    R.busy = true; renderBets();
    const bets = [...R.bets].map(([key, amount]) => {
      const [type, value] = key.split(":");
      const o = { type, amount };
      if (value !== "") o.value = Number(value);
      return o;
    });
    const used = new Map(R.bets);
    try {
      const res = await rpc("play_roulette", { p_bets: bets });
      G.setBalance(res.balance - res.payout);
      setMsg("roulette-msg", "");
      $("roulette-result").textContent = "No more bets…";
      if (reduced()) jumpWheel(res.number); else await spinWheel(res.number);
      const net = res.payout - res.total_bet;
      const rr = $("roulette-result");
      rr.textContent = res.number + " " + res.color;
      rr.style.color = res.color === "red" ? "#B3261E" : res.color === "green" ? "#1F7A6D" : "";
      const pill = document.createElement("span");
      pill.className = "pill " + (res.color === "red" ? "lose" : res.color === "green" ? "win" : "");
      pill.textContent = res.number;
      const hist = $("roulette-history"); hist.prepend(pill);
      while (hist.children.length > 14) hist.lastChild.remove();
      board.querySelectorAll(".won").forEach((x) => x.classList.remove("won"));
      const hit = board.querySelector('.rb[data-type="straight"][data-value="' + res.number + '"]');
      if (hit) hit.classList.add("won");
      if (res.payout > 0) setMsg("roulette-msg", (net >= 0 ? "You won " + fmt.format(net) + " goog" : "You got back " + fmt.format(res.payout) + " goog (net " + fmt.format(net) + ")") + ".", net >= 0 ? "ok" : "");
      else setMsg("roulette-msg", "No win. You lost " + fmt.format(res.total_bet) + " goog.", "error");
      G.setBalance(res.balance);
      R.last = used;
      R.bets.clear(); R.order = [];
    } catch (e) { setMsg("roulette-msg", e.message, "error"); }
    finally { R.busy = false; renderBets(); }
  };

  GG.register("roulette", {
    show() { resizeRoulette(); renderBets(); },
    leave() { cancelAnimationFrame(R.raf); },
  });
  renderBets();

  // =====================================================================
  // SCRATCH CARDS
  // =====================================================================
  const SC = { price: 5, card: null, busy: false, drawing: false, info: null, queue: [], idx: 0, finalBal: 0, pending: 0, spent: 0, won: 0, winners: 0 };
  const sCanvas = $("scratch-canvas");
  const sCtx = sCanvas.getContext("2d", { willReadFrequently: true });

  function paintCover(label) {
    const card = $("scratch-card");
    const w = card.clientWidth, h = card.clientHeight;
    if (!w || !h) return false;
    const dpr = window.devicePixelRatio || 1;
    sCanvas.width = Math.round(w * dpr); sCanvas.height = Math.round(h * dpr);
    sCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
    sCtx.globalCompositeOperation = "source-over";
    const g = sCtx.createLinearGradient(0, 0, w, h);
    g.addColorStop(0, "#c9ced6"); g.addColorStop(0.5, "#eef0f3"); g.addColorStop(1, "#aeb5bf");
    sCtx.fillStyle = g; sCtx.fillRect(0, 0, w, h);
    sCtx.fillStyle = "rgba(0,0,0,.06)";
    for (let i = 0; i < 700; i++) sCtx.fillRect(Math.random() * w, Math.random() * h, 2, 2);
    sCtx.fillStyle = "rgba(15,27,45,.55)";
    sCtx.font = "800 " + Math.round(w * 0.085) + "px 'Comic Sans MS', 'Comic Neue', cursive";
    sCtx.textAlign = "center"; sCtx.textBaseline = "middle";
    sCtx.fillText(label || "Scratch here", w / 2, h / 2);
    sCanvas.classList.remove("done");
    return true;
  }

  function buildGrid(cells, win) {
    const grid = $("scratch-grid");
    grid.replaceChildren();
    cells.forEach((c) => {
      const d = document.createElement("div");
      d.className = "s-cell";
      d.dataset.sym = c;
      const img = new Image(); img.src = G.catUrl(c); img.alt = "Cat " + c;
      d.appendChild(img);
      grid.appendChild(d);
    });
  }

  const scCount = () => Math.max(1, Math.min(10, Math.floor(Number($("scratch-count").value)) || 1));
  function scRender() {
    const n = scCount();
    $("scratch-count-out").textContent = n;
    $("scratch-total").textContent = fmt.format(n * SC.price);
    $("scratch-buy").textContent = n > 1 ? "Buy " + n + " cards" : "Buy a card";
  }
  function scButtons() {
    const left = SC.queue.length - SC.idx - 1;                         // cards after the current one
    const cur = SC.card;
    $("scratch-next").hidden = !(cur && cur.revealed && left > 0);
    $("scratch-next").textContent = "Next card (" + left + " left)";
    $("scratch-reveal").disabled = !(cur && (!cur.revealed || left > 0));
    $("scratch-buy").disabled = SC.busy;
  }
  function showCard(i, quiet) {
    SC.idx = i;
    const res = SC.queue[i];
    buildGrid(res.cells, res.win_symbol);
    if (!paintCover() && !quiet) throw new Error("Open the Scratch Cards screen first.");
    SC.card = { res, revealed: false };
    const n = SC.queue.length;
    setMsg("scratch-msg", (n > 1 ? "Card " + (i + 1) + " of " + n + ". " : "") + "Scratch the card to reveal your tiles.");
    scButtons();
  }
  function settle(res) {                                               // pay out one card in the display
    SC.pending -= Number(res.payout);
    SC.won += Number(res.payout);
    if (res.payout > 0) SC.winners++;
    G.setBalance(SC.finalBal - SC.pending);
  }
  function summary() {
    const n = SC.queue.length;
    const net = SC.won - SC.spent;
    const txt = n + " cards: " + SC.winners + " winner" + (SC.winners === 1 ? "" : "s") + ", won " + fmt.format(SC.won) + " of " + fmt.format(SC.spent) + " goog (" + (net >= 0 ? "+" : "") + fmt.format(net) + ").";
    setMsg("scratch-msg", txt, net > 0 ? "ok" : net < 0 ? "error" : "");
  }
  function revealCard() {
    const c = SC.card;
    if (!c || c.revealed) return;
    c.revealed = true;
    sCanvas.classList.add("done");
    const res = c.res;
    document.querySelectorAll("#scratch-grid .s-cell").forEach((d) => {
      if (res.win_symbol && Number(d.dataset.sym) === res.win_symbol) d.classList.add("win");
    });
    settle(res);
    const n = SC.queue.length, last = SC.idx === n - 1;
    if (n === 1) {
      if (res.payout > 0) setMsg("scratch-msg", "Three matching cats! ×" + res.multiplier + " wins " + fmt.format(res.payout) + " goog.", "ok");
      else setMsg("scratch-msg", "No match this time.", "error");
    } else if (last) summary();
    else setMsg("scratch-msg", (res.payout > 0 ? "Card " + (SC.idx + 1) + ": ×" + res.multiplier + " wins " + fmt.format(res.payout) + " goog! " : "Card " + (SC.idx + 1) + ": no match. ") + "Next card when you are ready.", res.payout > 0 ? "ok" : "");
    scButtons();
  }
  function revealAll() {                                               // finish the whole stack at once
    if (!SC.card) return;
    revealCard();
    while (SC.idx < SC.queue.length - 1) {
      showCard(SC.idx + 1, true);
      const c = SC.card; c.revealed = true; sCanvas.classList.add("done");
      settle(c.res);
      document.querySelectorAll("#scratch-grid .s-cell").forEach((d) => { if (c.res.win_symbol && Number(d.dataset.sym) === c.res.win_symbol) d.classList.add("win"); });
    }
    if (SC.queue.length > 1) summary();
    scButtons();
  }

  function scratchedFraction() {
    const w = sCanvas.width, h = sCanvas.height;
    const data = sCtx.getImageData(0, 0, w, h).data;
    let clear = 0, total = 0;
    const step = 12;
    for (let y = 0; y < h; y += step) for (let x = 0; x < w; x += step) { total++; if (data[(y * w + x) * 4 + 3] < 40) clear++; }
    return total ? clear / total : 0;
  }
  function scratchAt(e) {
    const r = sCanvas.getBoundingClientRect();
    const x = e.clientX - r.left, y = e.clientY - r.top;
    sCtx.globalCompositeOperation = "destination-out";
    sCtx.beginPath(); sCtx.arc(x, y, 20, 0, Math.PI * 2); sCtx.fill();
    if (SC.last) {
      sCtx.lineWidth = 40; sCtx.lineCap = "round";
      sCtx.beginPath(); sCtx.moveTo(SC.last.x, SC.last.y); sCtx.lineTo(x, y); sCtx.stroke();
    }
    SC.last = { x, y };
  }
  sCanvas.addEventListener("pointerdown", (e) => { if (!SC.card || SC.card.revealed) return; SC.drawing = true; SC.last = null; sCanvas.setPointerCapture(e.pointerId); scratchAt(e); });
  sCanvas.addEventListener("pointermove", (e) => { if (SC.drawing) scratchAt(e); });
  const endScratch = () => {
    if (!SC.drawing) return;
    SC.drawing = false; SC.last = null;
    if (SC.card && !SC.card.revealed && scratchedFraction() > 0.55) revealCard();
  };
  sCanvas.addEventListener("pointerup", endScratch);
  sCanvas.addEventListener("pointercancel", endScratch);

  document.querySelectorAll("[data-price]").forEach((b) => b.addEventListener("click", () => {
    SC.price = Number(b.dataset.price);
    document.querySelectorAll("[data-price]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    scRender();
  }));
  $("scratch-count").addEventListener("input", scRender);
  scRender();

  $("scratch-buy").onclick = async () => {
    if (SC.busy) return;
    SC.busy = true;
    if (SC.card) revealAll();                                         // buying new cards finishes the old stack first
    $("scratch-buy").disabled = true; $("scratch-reveal").disabled = true; $("scratch-next").hidden = true;
    try {
      const n = scCount(), price = SC.price;
      let cards, balance;
      if (n === 1) {
        const r = await rpc("play_scratch", { p_price: price });
        cards = [r]; balance = r.balance;
      } else {
        const r = await G.rpcOrFallback("play_scratch_multi", { p_price: price, p_count: n }, async () => {
          let last = 0;
          const all = await Promise.all(Array.from({ length: n }, () => rpc("play_scratch", { p_price: price }).then((x) => { last = x.balance; return x; })));
          return { cards: all, balance: last };
        });
        cards = r.cards; balance = r.balance;
      }
      SC.queue = cards; SC.finalBal = balance; SC.spent = price * cards.length; SC.won = 0; SC.winners = 0;
      SC.pending = cards.reduce((a, c) => a + Number(c.payout), 0);
      G.setBalance(balance - SC.pending);                             // the price is gone; prizes show as you scratch
      showCard(0);
    } catch (e) { setMsg("scratch-msg", e.message, "error"); }
    finally { SC.busy = false; $("scratch-buy").disabled = false; scButtons(); }
  };
  $("scratch-reveal").onclick = revealAll;
  $("scratch-next").onclick = () => { if (SC.card && SC.card.revealed && SC.idx < SC.queue.length - 1) showCard(SC.idx + 1); };

  async function scratchShow() {
    if (!SC.info) {
      try {
        SC.info = await rpc("scratch_info");
        const box = $("scratch-prizes");
        box.replaceChildren();
        [...SC.info].sort((a, b) => b.multiplier - a.multiplier).forEach((p) => {
          const row = document.createElement("div"); row.className = "prize-row";
          const img = new Image(); img.src = G.catUrl(p.symbol); img.alt = "Cat " + p.symbol;
          const val = document.createElement("span"); val.className = "prize"; val.textContent = "3 matching: ×" + p.multiplier;
          const odds = document.createElement("span"); odds.className = "odds"; odds.textContent = "1 in " + fmt.format(Math.round(1 / p.chance));
          row.append(img, val, odds);
          box.appendChild(row);
        });
      } catch (e) { setMsg("scratch-msg", e.message, "error"); }
    }
    if (!SC.card) {
      $("scratch-grid").replaceChildren();
      for (let i = 0; i < 9; i++) { const d = document.createElement("div"); d.className = "s-cell"; d.textContent = "?"; $("scratch-grid").appendChild(d); }
      paintCover("Buy a card");
      $("scratch-canvas").classList.remove("done");
    }
  }
  GG.register("scratch", {
    show: scratchShow,
    leave() { if (SC.card) revealAll(); },
  });
})();
