// Stats, achievements, challenges, weekly leaderboard and the admin "Returns" view.
// Everything is decided and stored on the server (supabase/migration-008-stats-achievements.sql);
// this file only asks for the numbers and shows them. If the migration has not been run, the cards just stay hidden.
(() => {
  "use strict";
  const G = window.Goog;
  if (!G) return;
  const $ = (id) => document.getElementById(id);
  const { fmt, rpc } = G;

  const GAMES = {
    dice: "Cat Dice", mines: "Cucumber Boxes", crash: "Cat Rocket", plinko: "Cat Drop",
    slots: "Cat Slots", tower: "Cat Tower", roulette: "Cat Roulette", scratch: "Scratch Cards",
  };
  const gameName = (g) => GAMES[g] || g;
  const ICONS = {
    first_win: "🎉", rounds_100: "🎲", all_games: "🐾", mega_win: "💥", tower_top: "🗼",
    crash_5x_10: "🚀", mines_clear: "🥒", slots_free: "🎰", roulette_straight: "🍀", scratch_jackpot: "🌟",
  };

  function h(tag, cls, text) {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text !== undefined && text !== null) el.textContent = text;
    return el;
  }
  const signed = (n) => (n > 0 ? "+" : n < 0 ? "−" : "") + fmt.format(Math.abs(n));
  const tone = (el, n) => { el.classList.toggle("pos", n > 0); el.classList.toggle("neg", n < 0); return el; };
  const missing = (e) => /could not find|does not exist|schema cache/i.test(e.message || "");

  function ago(iso) {
    const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    return new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
  }
  function until(iso) {
    const s = Math.max(0, (new Date(iso).getTime() - Date.now()) / 1000);
    const d = Math.floor(s / 86400), hh = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    return d > 0 ? d + " d " + hh + " h" : hh > 0 ? hh + " h " + m + " min" : m + " min";
  }

  // ====================================================================================================
  // Things that just happened on the server (unlocked achievements, finished challenges)
  // Every game answer can carry an "events" list. We hold it back until the game has finished its animation
  // (the game then updates the balance, which calls flush), so nothing is spoiled.
  // ====================================================================================================
  const queue = [];
  let failsafe = 0;

  function collect(data) {
    if (!data || typeof data !== "object") return;
    const found = [];
    const take = (o) => { if (o && Array.isArray(o.events) && o.events.length) found.push(...o.events); };
    take(data);
    if (Array.isArray(data.drops)) data.drops.forEach(take);     // Cat Drop with several cats
    if (Array.isArray(data.cards)) data.cards.forEach(take);     // several scratch cards
    if (!found.length) return;
    queue.push(...found);
    clearTimeout(failsafe);
    failsafe = setTimeout(flush, 15000);                          // in case a game never reports the balance
  }

  let flushing = false;
  function flush() {
    clearTimeout(failsafe);
    if (flushing || !queue.length) return;
    flushing = true;
    setTimeout(() => { flushing = false; showEvents(queue.splice(0)); }, 900);   // let the win animation start first
  }

  function showEvents(list) {
    let delay = 0;
    list.forEach((ev) => {
      setTimeout(() => {
        const reward = ev.reward > 0 ? "  +" + fmt.format(ev.reward) + " goog" : "";
        if (ev.type === "achievement") {
          G.toast("🏆 Achievement unlocked: " + ev.title + reward, "ach");
          if (window.Fx) Fx.sound("win", 2);
        } else if (ev.type === "challenge") {
          G.toast("✅ " + (ev.period === "weekly" ? "Weekly" : "Daily") + " challenge done: " + ev.title + reward, "ach");
          if (window.Fx) Fx.sound("win", 1);
        }
        if (window.Fx && ev.reward > 0) Fx.pulseBalance();
      }, delay);
      delay += 1400;
    });
    setTimeout(() => { refreshPanel(); if (!$("view-profile").hidden) loadProfileStats(); }, delay);
  }

  // ====================================================================================================
  // Challenges panel (Games page, next to the daily bonus)
  // ====================================================================================================
  function progressText(c) {
    const p = Number(c.progress), t = Number(c.target);
    if (c.kind === "best_mult") return (Math.floor(p * 10) / 10) + "x / " + t + "x";
    if (c.kind === "wagered" || c.kind === "max_payout") return fmt.format(Math.floor(p)) + " / " + fmt.format(t);
    return Math.floor(p) + " / " + t;
  }

  function fillList(ul, items) {
    ul.replaceChildren();
    items.forEach((c) => {
      const li = h("li", "challenge" + (c.done ? " done" : ""));
      const top = h("div", "challenge-top");
      top.append(h("span", "challenge-title", (c.done ? "✓ " : "") + c.title), h("span", "challenge-reward", "+" + fmt.format(c.reward)));
      const bar = h("div", "pbar");
      bar.setAttribute("role", "progressbar");
      bar.setAttribute("aria-valuemin", "0");
      bar.setAttribute("aria-valuemax", String(c.target));
      bar.setAttribute("aria-valuenow", String(Math.min(c.progress, c.target)));
      bar.setAttribute("aria-label", c.title);
      const fill = h("span");
      fill.style.width = Math.min(100, Math.round((Number(c.progress) / Number(c.target)) * 100)) + "%";
      bar.appendChild(fill);
      li.append(top, bar, h("span", "challenge-num", c.done ? "Done" : progressText(c)));
      ul.appendChild(li);
    });
  }

  let panelBusy = false;
  async function refreshPanel() {
    const panel = $("today-panel");
    if (!panel) return;
    const onHub = !$("view-games").hidden && !$("games-hub").hidden;
    if (!G.loggedIn()) { panel.hidden = true; return; }
    if (!onHub || panelBusy) return;
    panelBusy = true;
    try {
      const c = await rpc("my_challenges");
      fillList($("today-daily"), c.daily.items);
      fillList($("today-weekly"), c.weekly.items);
      $("today-daily-reset").textContent = "resets in " + until(c.daily.resets_at);
      $("today-weekly-reset").textContent = "resets in " + until(c.weekly.resets_at);
      const st = window.GoogExtras && window.GoogExtras.status && window.GoogExtras.status();
      $("today-bonus").textContent = st
        ? (st.daily_available ? "Daily bonus: +" + st.daily_amount + " goog ready" : "Daily bonus: +" + st.daily_amount + " goog collected today ✓")
        : "";
      panel.hidden = false;
    } catch (e) {
      panel.hidden = true;                                       // migration 008 not run yet
    } finally { panelBusy = false; }
  }

  // ====================================================================================================
  // Leaderboard: richest / this week
  // ====================================================================================================
  const B = { mode: "rich" };
  function setMode(mode) {
    B.mode = mode;
    document.querySelectorAll("[data-bmode]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.bmode === mode)));
    $("board-rich").hidden = mode !== "rich";
    $("board-week").hidden = mode !== "week";
    $("board-title").textContent = mode === "rich" ? "Richest accounts" : "This week's best";
    if (mode === "week") loadWeekly();
  }
  document.querySelectorAll("[data-bmode]").forEach((b) => b.addEventListener("click", () => setMode(b.dataset.bmode)));

  async function loadWeekly() {
    const body = $("week-body"), status = $("week-status");
    if (!G.loggedIn()) { body.replaceChildren(); return G.setStatus(status, "Log in to see the weekly leaderboard."); }
    G.setStatus(status, "Loading…");
    try {
      const r = await rpc("weekly_board");
      body.replaceChildren();
      const me = G.me();
      r.rows.forEach((row, i) => {
        const tr = h("tr");
        if (i < 3) tr.classList.add("top3");
        if (me && row.id === me.id) tr.classList.add("me");
        const who = h("td"); const wrap = h("div", "who");
        wrap.append(G.makeAvatar(row, "sm"), h("span", "", row.username)); who.appendChild(wrap);
        const net = h("td", "num", signed(row.net)); tone(net, row.net);
        const best = h("td", "num hide-sm"); best.append(G.googIcon(), document.createTextNode(fmt.format(row.best_win)));
        tr.append(h("td", "", String(i + 1)), who, net, best);
        body.appendChild(tr);
      });
      $("week-sub").textContent = "Net goog won this week (payouts minus bets). Resets in " + until(r.resets_at) + ", Monday 00:00 UTC.";
      G.setStatus(status, r.rows.length ? "" : "Nobody has played this week yet.");
    } catch (e) {
      body.replaceChildren();
      G.setStatus(status, missing(e) ? "Not available yet: the site owner still has to run migration 008." : e.message, "error");
    }
  }

  // ====================================================================================================
  // Profile: stats, recent bets, achievements
  // ====================================================================================================
  let profileBusy = false;
  async function loadProfileStats() {
    if (profileBusy) return;
    profileBusy = true;
    try {
      const [stats, recent, ach] = await Promise.all([rpc("my_stats"), rpc("my_recent_plays", { p_limit: 15 }), rpc("my_achievements")]);
      paintStats(stats, recent);
      paintAchievements(ach);
    } catch (e) {
      $("stats-card").hidden = true; $("ach-card").hidden = true;   // migration 008 not run yet
    } finally { profileBusy = false; }
  }

  function paintStats(stats, recent) {
    const games = stats.games || [];
    const sum = (k) => games.reduce((a, g) => a + Number(g[k]), 0);
    $("stat-plays").textContent = fmt.format(sum("plays"));
    $("stat-wagered").textContent = fmt.format(sum("wagered"));
    const net = sum("paid") - sum("wagered");
    $("stat-net").textContent = signed(net); tone($("stat-net"), net);
    const big = stats.biggest;
    $("stat-biggest").textContent = big ? "+" + fmt.format(big.profit) : "–";
    $("stat-biggest-sub").textContent = big
      ? "In " + gameName(big.game) + ": " + fmt.format(big.bet) + " became " + fmt.format(big.payout) + " (" + Number(big.multiplier).toFixed(2) + "x), " + ago(big.at) + "."
      : "No wins yet. Go and play something.";

    const gb = $("stats-games"); gb.replaceChildren();
    games.forEach((g) => {
      const tr = h("tr");
      const n = Number(g.net);
      tr.append(h("td", "", gameName(g.game)), h("td", "num", fmt.format(g.plays)), h("td", "num", fmt.format(g.wagered)), tone(h("td", "num", signed(n)), n));
      gb.appendChild(tr);
    });
    if (!games.length) { const tr = h("tr"); const td = h("td", "", "No rounds yet."); td.colSpan = 4; tr.appendChild(td); gb.appendChild(tr); }

    const rb = $("stats-recent"); rb.replaceChildren();
    (recent || []).forEach((r) => {
      const tr = h("tr");
      const win = r.payout > r.bet;
      tr.append(h("td", "", gameName(r.game)), h("td", "num", fmt.format(r.bet)), h("td", "num", fmt.format(r.payout)),
        tone(h("td", "num", Number(r.multiplier).toFixed(2) + "x"), win ? 1 : r.payout < r.bet ? -1 : 0), h("td", "num hide-sm", ago(r.at)));
      rb.appendChild(tr);
    });
    if (!(recent || []).length) { const tr = h("tr"); const td = h("td", "", "Your bets will show up here."); td.colSpan = 5; tr.appendChild(td); rb.appendChild(tr); }
    $("stats-card").hidden = false;
  }

  function paintAchievements(list) {
    const grid = $("ach-grid"); grid.replaceChildren();
    let got = 0;
    list.forEach((a) => {
      const on = !!a.unlocked_at;
      if (on) got++;
      const b = h("div", "ach" + (on ? " on" : " locked"));
      b.setAttribute("role", "listitem");
      b.append(h("span", "ach-icon", on ? (ICONS[a.code] || "🏅") : "🔒"), h("strong", "", a.title), h("span", "ach-desc", a.description),
        h("span", "ach-meta", on ? "Unlocked " + new Date(a.unlocked_at).toLocaleDateString("en-GB", { day: "numeric", month: "short" })
                                  : (a.reward > 0 ? "Reward: " + fmt.format(a.reward) + " goog" : "Locked")));
      grid.appendChild(b);
    });
    grid.setAttribute("role", "list");
    $("ach-count").textContent = got + " / " + list.length;
    $("ach-card").hidden = false;
  }

  function renderProfile() {
    const on = G.loggedIn();
    if (!on) { $("stats-card").hidden = true; $("ach-card").hidden = true; return; }
    loadProfileStats();
  }

  // ====================================================================================================
  // Admin: what the games really paid back
  // ====================================================================================================
  const R = { days: "" };
  document.querySelectorAll("#ret-range [data-days]").forEach((b) => b.addEventListener("click", () => {
    R.days = b.dataset.days;
    document.querySelectorAll("#ret-range [data-days]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    adminReturns(R.msg);
  }));

  async function adminReturns(msg) {
    R.msg = msg || R.msg || (() => {});
    const body = $("admin-returns");
    try {
      const rows = await rpc("admin_game_stats", { p_days: R.days === "" ? null : Number(R.days) });
      body.replaceChildren();
      const row = (g, plays, wag, paid, rtp, target, margin, tot) => {
        const tr = h("tr"); if (tot) tr.classList.add("total");
        const diff = rtp - target;
        let verdict = "", cls = "";
        if (plays < 100) { verdict = "too few rounds"; cls = "muted"; }
        else if (Math.abs(diff) <= margin) { verdict = "within noise"; cls = "ok"; }
        else if (diff > 0) { verdict = "pays too much"; cls = "bad"; }
        else { verdict = "pays too little"; cls = "warn"; }
        const pct = (x) => (x * 100).toFixed(2) + "%";
        tr.append(h("td", "", g), h("td", "num", fmt.format(plays)), h("td", "num", fmt.format(wag)), h("td", "num", fmt.format(paid)),
          h("td", "num", pct(rtp)), h("td", "num", target ? pct(target) : "–"), h("td", "num", margin ? "±" + (margin * 100).toFixed(2) + "%" : "–"),
          (() => { const td = h("td"); td.appendChild(h("span", "verdict " + cls, target ? verdict : "")); return td; })());
        return tr;
      };
      let tp = 0, tw = 0, tpaid = 0;
      rows.forEach((r) => {
        tp += Number(r.plays); tw += Number(r.wagered); tpaid += Number(r.paid);
        body.appendChild(row(gameName(r.game), Number(r.plays), Number(r.wagered), Number(r.paid), Number(r.rtp), Number(r.target), Number(r.margin), false));
      });
      if (!rows.length) { const tr = h("tr"); const td = h("td", "", "No rounds recorded yet."); td.colSpan = 8; tr.appendChild(td); body.appendChild(tr); return; }
      const t = row("All games", tp, tw, tpaid, tw ? tpaid / tw : 0, 0, 0, true);
      body.appendChild(t);
    } catch (e) {
      R.msg(missing(e) ? "Run migration 008 first." : e.message, "error");
    }
  }

  // ====================================================================================================
  window.GoogStats = {
    collect, flush, renderProfile, refreshPanel, adminReturns,
    onRoute(name) {
      if (name === "games") refreshPanel();
      else if (name === "board" && B.mode === "week") loadWeekly();
    },
    onSession() { refreshPanel(); },
  };
})();
