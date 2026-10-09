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

  const PROFILE_COLS = "id, username, goog, avatar_version, created_at";

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

  // Shared with games.js
  window.Goog = {
    db, fmt, googIcon, setStatus,
    me: () => me,
    loggedIn: () => !!session,
    setBalance(n) { if (me) { me.goog = n; renderNav(); } },
  };

  // ---------- routing:  #games, #games/mines, #board, #profile ----------
  const VIEWS = ["games", "board", "profile"];
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
    if (name === "board") loadBoard();
    if (name === "profile") renderProfile();
  }
  window.addEventListener("hashchange", route);

  // ---------- data ----------
  async function loadMe() {
    if (!session) { me = null; return; }
    const { data, error } = await db.from("profiles").select(PROFILE_COLS).eq("id", session.user.id).single();
    me = error ? null : data;
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
    const { count } = await db.from("profiles").select("id", { count: "exact", head: true }).gt("goog", me.goog);
    $("me-rank").textContent = count === null ? "" : "Rank #" + (count + 1);
  }

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
  db.auth.onAuthStateChange((_event, s) => {
    session = s;
    setTimeout(async () => {
      await loadMe();
      renderNav();
      if (current === "profile") renderProfile();
      if (current === "board") loadBoard();
      if (current === "games" && window.GoogGames) window.GoogGames.refresh();
    }, 0);
  });

  // ---------- boot (after games.js has registered itself) ----------
  document.addEventListener("DOMContentLoaded", async () => {
    const { data } = await db.auth.getSession();
    session = data.session;
    await loadMe();
    renderNav();
    route();
  });
})();
