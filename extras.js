// Daily login bonus, the "draw a cat" rescue, and the admin panel.
// All rules live on the server (supabase/migration-004-economy.sql); this file only asks and shows.
(() => {
  "use strict";
  const G = window.Goog;
  if (!G) return; // config missing; app.js already showed a message
  const $ = (id) => document.getElementById(id);
  const { fmt, rpc } = G;
  const setMsg = (id, text, kind = "") => G.setStatus($(id), text, kind);

  const E = { status: null, userId: null, timer: 0 };

  // ---------- status, daily bonus, rescue bar ----------
  // syncBalance: also copy the server balance into the balance chip (not done during games, where the chip is
  // deliberately held back until an animation has finished)
  async function refreshStatus(syncBalance) {
    if (!G.loggedIn()) { E.status = null; render(); return; }
    try {
      E.status = await rpc("my_status");
      const me = G.me();
      if (syncBalance === true && me && typeof E.status.goog === "number" && me.goog !== E.status.goog) G.setBalance(E.status.goog);
    } catch (_) { E.status = null; }
    render();
  }

  function render() {
    const st = E.status;
    $("nav-admin").hidden = !(st && st.is_admin);
    $("rescue-bar").hidden = !(st && st.rescue_available);
    if (!st && location.hash === "#admin") location.hash = "#games";
  }

  async function onSession(session) {
    const id = session ? session.user.id : null;
    if (id === E.userId) return;           // token refreshes and repeated events change nothing
    E.userId = id;
    if (!id) {
      E.status = null; render();
      if ($("draw-dialog").open) $("draw-dialog").close();
      return;
    }
    await refreshStatus(true);
    if (E.status && E.status.daily_available) {
      try {
        const r = await rpc("claim_daily");
        if (r.claimed) {
          G.setBalance(r.balance);
          G.toast("Daily login bonus: +" + r.amount + " goog", "ok");
        }
      } catch (_) { /* banned or offline: nothing to do */ }
      await refreshStatus();
    }
  }

  function balanceChanged(n) {
    if (!G.loggedIn()) return;
    const low = typeof n === "number" && n < (E.status ? E.status.rescue_below : 10);
    if (!low && !(E.status && E.status.rescue_available)) return;
    clearTimeout(E.timer);
    E.timer = setTimeout(() => refreshStatus(false), 700);   // let the game animation finish before the bar appears
  }

  window.GoogExtras = { onSession, balanceChanged, refreshStatus };

  // ---------- draw a cat ----------
  const dlg = $("draw-dialog");
  const cv = $("draw-canvas");
  const ctx = cv.getContext("2d");
  const D = { color: "#111111", size: 7, strokes: [], current: null, length: 0 };
  const COLORS = [["#111111", "Black"], ["#e0801a", "Orange"], ["#8a5a2b", "Brown"], ["#f2a9b8", "Pink"], ["#9aa3ad", "Grey"], ["#ffffff", "White (eraser)"]];

  COLORS.forEach(([c, name], i) => {
    const b = document.createElement("button");
    b.type = "button"; b.className = "swatch"; b.style.background = c; b.dataset.color = c;
    b.setAttribute("aria-label", name); b.setAttribute("aria-pressed", String(i === 0));
    $("draw-colors").appendChild(b);
  });
  $("draw-colors").addEventListener("click", (e) => {
    const b = e.target.closest(".swatch"); if (!b) return;
    D.color = b.dataset.color;
    $("draw-colors").querySelectorAll(".swatch").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
  });
  $("draw-sizes").addEventListener("click", (e) => {
    const b = e.target.closest("[data-size]"); if (!b) return;
    D.size = Number(b.dataset.size);
    $("draw-sizes").querySelectorAll("[data-size]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
  });

  function paintStroke(s) {
    ctx.strokeStyle = s.color; ctx.fillStyle = s.color; ctx.lineWidth = s.size; ctx.lineCap = "round"; ctx.lineJoin = "round";
    if (s.points.length === 1) {
      ctx.beginPath(); ctx.arc(s.points[0].x, s.points[0].y, s.size / 2, 0, Math.PI * 2); ctx.fill();
      return;
    }
    ctx.beginPath(); ctx.moveTo(s.points[0].x, s.points[0].y);
    for (let i = 1; i < s.points.length; i++) ctx.lineTo(s.points[i].x, s.points[i].y);
    ctx.stroke();
  }
  function redraw() {
    ctx.fillStyle = "#ffffff"; ctx.fillRect(0, 0, cv.width, cv.height);
    D.strokes.forEach(paintStroke);
    D.length = 0;
    D.strokes.forEach((s) => { if (s.color !== "#ffffff") for (let i = 1; i < s.points.length; i++) D.length += Math.hypot(s.points[i].x - s.points[i - 1].x, s.points[i].y - s.points[i - 1].y); });
    $("draw-send").disabled = D.length < 500 || D.strokes.length < 3;
  }
  const pt = (e) => {
    const r = cv.getBoundingClientRect();
    return { x: ((e.clientX - r.left) / r.width) * cv.width, y: ((e.clientY - r.top) / r.height) * cv.height };
  };
  cv.addEventListener("pointerdown", (e) => {
    cv.setPointerCapture(e.pointerId);
    D.current = { color: D.color, size: D.size, points: [pt(e)] };
    D.strokes.push(D.current);
    redraw();
  });
  cv.addEventListener("pointermove", (e) => {
    if (!D.current) return;
    D.current.points.push(pt(e));
    redraw();
  });
  const endStroke = () => { D.current = null; };
  cv.addEventListener("pointerup", endStroke);
  cv.addEventListener("pointercancel", endStroke);
  $("draw-undo").onclick = () => { D.strokes.pop(); redraw(); };
  $("draw-clear").onclick = () => { D.strokes = []; redraw(); };

  function openDraw() {
    if (!E.status || !E.status.rescue_available) { G.toast("You can draw a cat when you have less than 10 goog.", ""); return; }
    D.strokes = []; D.current = null;
    setMsg("draw-msg", "");
    redraw();
    if (typeof dlg.showModal === "function") dlg.showModal(); else dlg.setAttribute("open", "");
  }
  $("rescue-open").onclick = openDraw;
  $("draw-cancel").onclick = () => dlg.close();

  $("draw-send").onclick = async () => {
    const btn = $("draw-send");
    btn.disabled = true;
    setMsg("draw-msg", "Sending…");
    try {
      const out = document.createElement("canvas");
      out.width = out.height = 256;
      const o = out.getContext("2d");
      o.fillStyle = "#fff"; o.fillRect(0, 0, 256, 256);
      o.drawImage(cv, 0, 0, 256, 256);
      const b64 = out.toDataURL("image/png").replace(/^data:image\/png;base64,/, "");
      const r = await rpc("submit_cat_drawing", { p_png_base64: b64 });
      G.setBalance(r.balance);
      dlg.close();
      G.toast("Thanks! +" + r.amount + " goog. If the cat is not drawn well enough, the goog may be removed again.", "ok");
      await refreshStatus();
    } catch (e) {
      setMsg("draw-msg", e.message, "error");
      btn.disabled = D.length < 500;
    }
  };

  // ---------- admin panel ----------
  const A = { tab: "players", q: "", filter: "pending" };
  const msg = (t, k) => setMsg("admin-msg", t, k);
  const when = (iso) => new Date(iso).toLocaleString("en-GB", { dateStyle: "short", timeStyle: "short" });

  async function loadStats() {
    try {
      const s = await rpc("admin_overview");
      $("st-players").textContent = fmt.format(s.players);
      $("st-goog").textContent = fmt.format(s.total_goog);
      $("st-banned").textContent = fmt.format(s.banned);
      $("st-pending").textContent = fmt.format(s.pending_drawings);
    } catch (e) { msg(e.message, "error"); }
  }

  function setTab(t) {
    A.tab = t;
    ["players", "drawings", "log"].forEach((x) => {
      $("atab-" + x).setAttribute("aria-selected", String(x === t));
      $("apanel-" + x).hidden = x !== t;
    });
    msg("");
    loadTab();
  }
  ["players", "drawings", "log"].forEach((t) => ($("atab-" + t).onclick = () => setTab(t)));

  function loadTab() {
    if (A.tab === "players") return loadUsers();
    if (A.tab === "drawings") return loadDrawings();
    return loadLog();
  }

  async function loadUsers() {
    const body = $("admin-users");
    try {
      const rows = await rpc("admin_list_users", { p_search: A.q, p_limit: 50, p_offset: 0 });
      body.replaceChildren();
      rows.forEach((u) => {
        const tr = document.createElement("tr");
        const name = document.createElement("td");
        name.textContent = u.username;
        if (u.is_admin) { const b = document.createElement("span"); b.className = "badge ok"; b.textContent = "admin"; name.appendChild(b); }
        if (u.banned) { const b = document.createElement("span"); b.className = "badge bad"; b.textContent = "banned"; name.appendChild(b); }
        const goog = document.createElement("td"); goog.className = "num"; goog.textContent = fmt.format(u.goog);

        const adj = document.createElement("td");
        const box = document.createElement("div"); box.className = "adj";
        const input = document.createElement("input");
        input.type = "number"; input.min = "0"; input.placeholder = "goog"; input.setAttribute("aria-label", "Amount for " + u.username);
        const mk = (label, fn) => { const b = document.createElement("button"); b.type = "button"; b.textContent = label; b.onclick = () => fn(); return b; };
        const amount = () => { const n = Math.floor(Number(input.value)); if (!Number.isFinite(n) || n < 0) throw new Error("Enter an amount."); return n; };
        const run = async (fn) => { try { msg(""); await fn(); input.value = ""; await Promise.all([loadUsers(), loadStats()]); } catch (e) { msg(e.message, "error"); } };
        const after = (r, id) => { const me = G.me(); if (me && id === me.id && typeof r.balance === "number") G.setBalance(r.balance); };
        box.append(
          input,
          mk("Add", () => run(async () => { const n = amount(); if (!n) throw new Error("Enter an amount."); const r = await rpc("admin_adjust_goog", { p_user: u.id, p_delta: n, p_note: null }); after(r, u.id); msg("Gave " + fmt.format(r.applied) + " goog to " + u.username + ".", "ok"); })),
          mk("Remove", () => run(async () => { const n = amount(); if (!n) throw new Error("Enter an amount."); const r = await rpc("admin_adjust_goog", { p_user: u.id, p_delta: -n, p_note: null }); after(r, u.id); msg("Removed " + fmt.format(-r.applied) + " goog from " + u.username + ".", "ok"); })),
          mk("Set to", () => run(async () => { const n = amount(); const r = await rpc("admin_set_goog", { p_user: u.id, p_amount: n, p_note: null }); after(r, u.id); msg(u.username + " now has " + fmt.format(r.balance) + " goog.", "ok"); })),
        );
        adj.appendChild(box);

        const acc = document.createElement("td");
        const ban = document.createElement("button");
        ban.type = "button"; ban.className = "mini";
        ban.textContent = u.banned ? "Unban" : "Ban";
        ban.onclick = async () => {
          if (!u.banned && !window.confirm("Ban " + u.username + "? They will not be able to place bets.")) return;
          try { msg(""); await rpc("admin_set_banned", { p_user: u.id, p_banned: !u.banned }); await Promise.all([loadUsers(), loadStats()]); msg(u.username + (u.banned ? " is unbanned." : " is banned."), "ok"); }
          catch (e) { msg(e.message, "error"); }
        };
        acc.appendChild(ban);
        tr.append(name, goog, adj, acc);
        body.appendChild(tr);
      });
      if (!rows.length) { const tr = document.createElement("tr"); const td = document.createElement("td"); td.colSpan = 4; td.textContent = "No players found."; tr.appendChild(td); body.appendChild(tr); }
    } catch (e) { msg(e.message, "error"); }
  }
  $("admin-search").addEventListener("submit", (e) => { e.preventDefault(); A.q = $("admin-q").value.trim(); loadUsers(); });
  $("admin-everyone").addEventListener("submit", async (e) => {
    e.preventDefault();
    const n = Math.floor(Number($("admin-everyone-amt").value));
    if (!(n >= 1 && n <= 100000)) return msg("Enter 1 to 100000 goog.", "error");
    if (!window.confirm("Give " + fmt.format(n) + " goog to every player who is not banned?")) return;
    try {
      const r = await rpc("admin_give_everyone", { p_amount: n, p_note: null });
      $("admin-everyone-amt").value = "";
      msg("Gave " + fmt.format(n) + " goog to " + fmt.format(r.players) + " players.", "ok");
      await Promise.all([loadUsers(), loadStats(), refreshStatus(true)]);
    } catch (err) { msg(err.message, "error"); }
  });

  async function loadDrawings() {
    const box = $("admin-drawings");
    try {
      const rows = await rpc("admin_list_drawings", { p_status: A.filter, p_limit: 30 });
      box.replaceChildren();
      if (!rows.length) { const p = document.createElement("p"); p.className = "sub"; p.textContent = A.filter === "pending" ? "No drawings waiting for review." : "No drawings yet."; box.appendChild(p); return; }
      rows.forEach((d) => {
        const card = document.createElement("div"); card.className = "drawing";
        const img = new Image(); img.alt = "Cat drawn by " + d.username; img.src = "data:image/png;base64," + d.image;
        const info = document.createElement("p");
        info.textContent = d.username + " · " + when(d.created_at) + " · " + d.granted + " goog given · " + d.status;
        card.append(img, info);
        if (d.status === "pending") {
          const row = document.createElement("div"); row.className = "row-btns";
          const ok = document.createElement("button"); ok.type = "button"; ok.className = "btn small alt"; ok.textContent = "Approve";
          const no = document.createElement("button"); no.type = "button"; no.className = "btn small"; no.textContent = "Reject and take goog back";
          const act = (approve) => async () => {
            try { const r = await rpc("admin_review_drawing", { p_id: d.id, p_approve: approve }); msg(approve ? "Approved." : "Rejected. Took back " + r.taken_back + " goog.", "ok"); await Promise.all([loadDrawings(), loadStats()]); }
            catch (e) { msg(e.message, "error"); }
          };
          ok.onclick = act(true); no.onclick = act(false);
          row.append(ok, no); card.appendChild(row);
        }
        box.appendChild(card);
      });
    } catch (e) { msg(e.message, "error"); }
  }
  document.querySelectorAll("[data-dfilter]").forEach((b) => b.addEventListener("click", () => {
    A.filter = b.dataset.dfilter;
    document.querySelectorAll("[data-dfilter]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    loadDrawings();
  }));

  async function loadLog() {
    const ul = $("admin-log");
    try {
      const rows = await rpc("admin_recent_actions", { p_limit: 40 });
      ul.replaceChildren();
      if (!rows.length) { const li = document.createElement("li"); li.textContent = "Nothing yet."; ul.appendChild(li); return; }
      rows.forEach((a) => {
        const li = document.createElement("li");
        const t = document.createElement("time"); t.textContent = when(a.created_at);
        li.append(t, document.createTextNode((a.admin || "?") + ": " + a.action.replace(/_/g, " ") + (a.target ? " → " + a.target : "") + (a.detail ? " (" + a.detail + ")" : "")));
        ul.appendChild(li);
      });
    } catch (e) { msg(e.message, "error"); }
  }

  window.GoogAdmin = {
    async show() {
      await refreshStatus(true);
      if (!E.status || !E.status.is_admin) { msg("Admins only.", "error"); return; }
      loadStats();
      setTab(A.tab);
    },
  };
})();
