(() => {
  const cfg = window.GOOG_CONFIG;
  const $ = (id) => document.getElementById(id);
  const fmt = new Intl.NumberFormat("en-US");

  if (!cfg || cfg.SUPABASE_URL.includes("YOUR-PROJECT")) {
    document.body.insertAdjacentHTML("afterbegin",
      '<p style="padding:1rem;background:#B3261E;color:#fff">Set your Supabase URL and anon key in config.js first (see README).</p>');
    return;
  }

  const db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
  let session = null;
  let me = null; // { id, username, goog, avatar_version, created_at }

  const PROFILE_COLS = "id, username, goog, avatar_version, created_at, bg_hue";
  const PROFILE_COLS_BASE = "id, username, goog, avatar_version, created_at";

  // ---------- helpers ----------
  function setStatus(el, msg, kind = "") { el.textContent = msg; el.className = "status " + kind; }

  function avatarUrl(id, version) {
    return `${cfg.SUPABASE_URL}/storage/v1/object/public/avatars/${id}/avatar.jpg?v=${version}`;
  }
  function makeAvatar(p, size) {
    const el = document.createElement("span");
    el.className = "avatar " + size;
    const initial = () => { el.replaceChildren(); el.textContent = p.username.charAt(0).toUpperCase(); };
    if (p.avatar_version) {
      const img = new Image();
      img.alt = "";
      img.loading = "lazy";
      img.onerror = initial;
      img.src = avatarUrl(p.id, p.avatar_version);
      el.appendChild(img);
    } else initial();
    return el;
  }
  function googIcon() {
    const img = new Image();
    img.className = "goog-icon";
    img.src = "assets/goog.jpg";
    img.alt = "";
    return img;
  }

  // ---------- cats (the slot cats are used by all games) ----------
  const CAT_COUNT = 6;
  const catUrl = (i) => "assets/cats/slotcat_" + i + ".jpg";
  const randCat = () => catUrl(1 + Math.floor(Math.random() * CAT_COUNT));

  // ---------- toasts ----------
  function toast(msg, kind = "") {
    const box = $("toasts");
    if (!box) return;
    const t = document.createElement("div");
    t.className = "toast " + kind;
    t.textContent = msg;
    box.appendChild(t);
    setTimeout(() => t.remove(), 5000);
  }

  async function rpc(name, args) {
    const { data, error } = await db.rpc(name, args || {});
    if (error) throw new Error(error.message);
    return data;
  }

  // For "do many rounds in one request" functions added by migration 006: if the database does not have the
  // function yet, run the fallback instead (several single rounds).
  async function rpcOrFallback(name, args, fallback) {
    try { return await rpc(name, args); }
    catch (e) {
      if (/could not find|does not exist|schema cache/i.test(e.message)) return fallback();
      throw e;
    }
  }

  // Background color: one hue per account (0..359), or none for the default look. Colors are in style.css.
  function applyHue(h) {
    const root = document.documentElement;
    const has = h !== null && h !== undefined && h !== "";
    if (has) { root.setAttribute("data-hue", ""); root.style.setProperty("--hue", String(h)); }
    else { root.removeAttribute("data-hue"); root.style.removeProperty("--hue"); }
    try { if (has) localStorage.setItem("goog-hue", String(h)); else localStorage.removeItem("goog-hue"); } catch (e) {}
    window.dispatchEvent(new Event("goog-theme"));
  }

  // Shared with games.js, games2.js and extras.js
  window.Goog = {
    db, fmt, googIcon, setStatus, toast, rpc, rpcOrFallback, applyHue, catUrl, randCat, CAT_COUNT, makeAvatar,
    me: () => me,
    loggedIn: () => !!session,
    setBalance(n) {
      if (me) { me.goog = n; renderNav(); }
      if (window.GoogExtras) window.GoogExtras.balanceChanged(n);
    },
  };

  // ---------- routing:  #games, #games/mines, #board, #profile ----------
  const VIEWS = ["games", "board", "profile", "admin", "disclaimer"];
  let current = null;
  function route() {
    const [v, sub] = location.hash.slice(1).split("/");
    show(VIEWS.includes(v) ? v : "games", sub);
  }
  function show(name, sub) {
    current = name;
    VIEWS.forEach((v) => ($("view-" + v).hidden = v !== name));
    document.querySelectorAll("#nav a").forEach((a) => {
      if (a.dataset.view === name) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
    });
    if (name === "games") { if (window.GoogGames) window.GoogGames.show(sub); }
    else if (window.GoogGames) window.GoogGames.leave();
    const dl = $("nav-disclaimer"); if (dl) { if (name === "disclaimer") dl.setAttribute("aria-current", "page"); else dl.removeAttribute("aria-current"); }
    if (name === "board") loadBoard();
    if (name === "profile") renderProfile();
    if (name === "admin" && window.GoogAdmin) window.GoogAdmin.show();
  }
  window.addEventListener("hashchange", route);

  // ---------- data ----------
  async function loadMe() {
    if (!session) { me = null; return; }
    let { data, error } = await db.from("profiles").select(PROFILE_COLS).eq("id", session.user.id).single();
    if (error) ({ data, error } = await db.from("profiles").select(PROFILE_COLS_BASE).eq("id", session.user.id).single());   // migration 006 not run yet
    me = error ? null : data;
    if (me && "bg_hue" in me) applyHue(me.bg_hue);
  }

  function renderNav() {
    const bal = $("balance");
    bal.hidden = !me;
    $("logout").hidden = !session;
    if (me) bal.replaceChildren(googIcon(), document.createTextNode(fmt.format(me.goog)));
  }

  // ---------- leaderboard ----------
  async function loadBoard() {
    const body = $("board-body");
    const status = $("board-status");
    setStatus(status, "Loading…");
    const { data, error } = await db.from("profiles")
      .select("id, username, goog, avatar_version")
      .order("goog", { ascending: false })
      .order("created_at", { ascending: true })
      .limit(25);
    if (error) return setStatus(status, "Could not load the leaderboard: " + error.message, "error");
    body.replaceChildren();
    data.forEach((row, i) => {
      const tr = document.createElement("tr");
      if (i < 3) tr.classList.add("top3");
      if (me && row.id === me.id) tr.classList.add("me");

      const rank = document.createElement("td"); rank.textContent = i + 1;

      const who = document.createElement("td");
      const wrap = document.createElement("div"); wrap.className = "who";
      const name = document.createElement("span"); name.textContent = row.username;
      wrap.append(makeAvatar(row, "sm"), name);
      who.appendChild(wrap);

      const amt = document.createElement("td"); amt.className = "num";
      amt.append(googIcon(), document.createTextNode(fmt.format(row.goog)));

      tr.append(rank, who, amt);
      body.appendChild(tr);
    });
    setStatus(status, data.length ? "" : "No accounts yet. Create the first one.");
  }
  $("refresh").onclick = loadBoard;

  // ---------- profile ----------
  async function renderProfile() {
    await loadMe();
    renderNav();
    $("auth-card").hidden = !!session;
    $("me-card").hidden = !session;
    if (!session) return;
    if (!me) return setStatus($("me-status"), "Could not load your profile.", "error");

    $("me-avatar-slot").replaceChildren(makeAvatar(me, "lg"));
    $("me-name").textContent = me.username;
    $("me-since").textContent = "Member since " + new Date(me.created_at).toLocaleDateString("en-GB", { year: "numeric", month: "long", day: "numeric" });
    $("me-goog").textContent = fmt.format(me.goog);
    $("avatar-remove").hidden = !me.avatar_version;
    paintBgCard();
    const { count } = await db.from("profiles").select("id", { count: "exact", head: true }).gt("goog", me.goog);
    $("me-rank").textContent = count === null ? "" : "Rank #" + (count + 1);
  }

  // ---------- background color gamble ----------
  function paintBgCard() {
    $("bg-card").hidden = !(session && me);
    const has = me && me.bg_hue !== null && me.bg_hue !== undefined;
    const sw = $("bg-swatch");
    sw.classList.toggle("set", !!has);
    if (has) sw.style.setProperty("--sw", me.bg_hue);
    $("bg-reset").hidden = !has;
  }
  let rolling = false;
  $("bg-roll").onclick = async () => {
    if (rolling || !me) return;
    rolling = true;
    const btn = $("bg-roll"), sw = $("bg-swatch");
    btn.disabled = true;
    setStatus($("bg-status"), "");
    sw.classList.add("set");
    const t0 = performance.now();
    const spin = setInterval(() => sw.style.setProperty("--sw", Math.floor(Math.random() * 360)), 70);
    try {
      const [res] = await Promise.all([rpc("gamble_bg_color"), new Promise((r) => setTimeout(r, 900))]);
      clearInterval(spin);
      sw.style.setProperty("--sw", res.hue);
      me.bg_hue = res.hue;
      applyHue(res.hue);
      window.Goog.setBalance(res.balance);
      setStatus($("bg-status"), "New color! Hue " + res.hue + ".", "ok");
    } catch (e) {
      clearInterval(spin);
      const m = /could not find|does not exist|schema cache/i.test(e.message) ? "Not available yet: the site owner still has to run migration 006." : e.message;
      setStatus($("bg-status"), m, "error");
    } finally { clearInterval(spin); rolling = false; btn.disabled = false; paintBgCard(); }
  };
  $("bg-reset").onclick = async () => {
    if (!me) return;
    try { await rpc("reset_bg_color"); me.bg_hue = null; applyHue(null); paintBgCard(); setStatus($("bg-status"), "Back to the default look.", "ok"); }
    catch (e) { setStatus($("bg-status"), e.message, "error"); }
  };

  // Resize to a 256×256 square JPEG before upload
  async function toAvatarBlob(file) {
    const bmp = await createImageBitmap(file);
    const s = Math.min(bmp.width, bmp.height);
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 256;
    canvas.getContext("2d").drawImage(bmp, (bmp.width - s) / 2, (bmp.height - s) / 2, s, s, 0, 0, 256, 256);
    return new Promise((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error("Could not process image"))), "image/jpeg", 0.85));
  }

  $("avatar-file").addEventListener("change", async (e) => {
    const file = e.target.files[0];
    e.target.value = "";
    if (!file || !me) return;
    const status = $("me-status");
    if (!file.type.startsWith("image/")) return setStatus(status, "Please choose an image file.", "error");
    if (file.size > 10 * 1024 * 1024) return setStatus(status, "That image is too large (max 10 MB).", "error");
    setStatus(status, "Uploading…");
    try {
      const blob = await toAvatarBlob(file);
      const path = `${me.id}/avatar.jpg`;
      const up = await db.storage.from("avatars").upload(path, blob, { upsert: true, contentType: "image/jpeg" });
      if (up.error) throw up.error;
      const upd = await db.from("profiles").update({ avatar_version: Date.now() }).eq("id", me.id);
      if (upd.error) throw upd.error;
      setStatus(status, "Picture updated.", "ok");
      await renderProfile();
    } catch (err) {
      setStatus(status, "Upload failed: " + err.message, "error");
    }
  });

  $("avatar-remove").onclick = async () => {
    if (!me) return;
    const status = $("me-status");
    setStatus(status, "Removing…");
    const rm = await db.storage.from("avatars").remove([`${me.id}/avatar.jpg`]);
    const upd = await db.from("profiles").update({ avatar_version: null }).eq("id", me.id);
    if (rm.error || upd.error) return setStatus(status, "Could not remove the picture.", "error");
    setStatus(status, "Picture removed.", "ok");
    await renderProfile();
  };

  // ---------- auth ----------
  function authTab(which) {
    const login = which === "login";
    $("form-login").hidden = !login;
    $("form-register").hidden = login;
    $("tab-login").setAttribute("aria-selected", login);
    $("tab-register").setAttribute("aria-selected", !login);
    setStatus($("auth-status"), "");
  }
  $("tab-login").onclick = () => authTab("login");
  $("tab-register").onclick = () => authTab("register");

  async function withBusy(form, fn) {
    const btn = form.querySelector("button[type=submit]");
    btn.disabled = true;
    try { await fn(); } finally { btn.disabled = false; }
  }

  $("form-login").addEventListener("submit", (e) => {
    e.preventDefault();
    const f = e.target;
    withBusy(f, async () => {
      const { error } = await db.auth.signInWithPassword({ email: f.email.value.trim(), password: f.password.value });
      if (error) return setStatus($("auth-status"), error.message, "error");
      f.reset();
    });
  });

  $("form-register").addEventListener("submit", (e) => {
    e.preventDefault();
    const f = e.target;
    withBusy(f, async () => {
      const username = f.username.value.trim();
      if (!/^[A-Za-z0-9_]{3,20}$/.test(username))
        return setStatus($("auth-status"), "Username must be 3–20 letters, numbers or underscores.", "error");
      const { data: taken } = await db.from("profiles").select("id").ilike("username", username).maybeSingle();
      if (taken) return setStatus($("auth-status"), "That username is taken.", "error");

      const { data, error } = await db.auth.signUp({
        email: f.email.value.trim(),
        password: f.password.value,
        options: { data: { username } }, // a database trigger creates the profile with 100 goog
      });
      if (error) return setStatus($("auth-status"), error.message, "error");
      f.reset();
      if (!data.session) {
        authTab("login");
        setStatus($("auth-status"), "Account created. Confirm your email, then log in.", "ok");
      }
    });
  });

  $("logout").onclick = async () => { await db.auth.signOut(); };

  // Don't await Supabase calls inside this callback (it can deadlock); defer instead.
  db.auth.onAuthStateChange((event, s) => {
    const prevId = session ? session.user.id : null;
    session = s;
    // The boot code below handles the first load. Token refreshes, and the SIGNED_IN that supabase-js re-sends
    // whenever the browser tab regains focus, change nothing, so skip them (they used to reload everything).
    if (event === "INITIAL_SESSION" || event === "TOKEN_REFRESHED") return;
    if (event === "SIGNED_IN" && s && s.user.id === prevId) return;
    if (!s) applyHue(null);
    setTimeout(async () => {
      await loadMe();
      renderNav();
      if (window.GoogExtras) window.GoogExtras.onSession(s);
      if (current === "profile") renderProfile();
      if (current === "board") loadBoard();
      if (current === "games" && window.GoogGames) window.GoogGames.refresh();
    }, 0);
  });

  // ---------- boot (after games.js has registered itself) ----------
  document.addEventListener("DOMContentLoaded", async () => {
    const { data } = await db.auth.getSession();                   // reads the saved login from the browser, no network
    session = data.session;
    if (!session) applyHue(null);
    route();                                                        // show the page right away
    const mine = loadMe();                                          // ...and fetch the profile and the daily bonus in parallel
    if (window.GoogExtras) window.GoogExtras.onSession(session);
    await mine;
    renderNav();
    if (current === "profile") renderProfile();
    // warm the browser cache with the cat pictures so slots, tower and scratch cards never wait on them
    const warm = () => { for (let i = 1; i <= CAT_COUNT; i++) { const im = new Image(); im.src = catUrl(i); } new Image().src = "assets/cats/plink.jpg"; new Image().src = "assets/cats/drooling.jpg"; };
    if (window.requestIdleCallback) window.requestIdleCallback(warm, { timeout: 2000 }); else setTimeout(warm, 300);
  });
})();


// ---- light / dark mode toggle ----
(function () {
  const btn = document.getElementById("theme-toggle");
  if (!btn) return;
  const root = document.documentElement;
  const paint = () => { btn.textContent = root.getAttribute("data-theme") === "dark" ? "☀" : "☾"; };
  paint();
  btn.addEventListener("click", () => {
    const next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    try { localStorage.setItem("goog-theme", next); } catch (e) {}
    paint();
    window.dispatchEvent(new Event("goog-theme")); // canvases redraw with the new colors
  });
})();
