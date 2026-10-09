# goog

A small website with accounts, a `goog` currency (everyone starts with 100, the coin is the cat in `assets/goog.jpg`), a leaderboard, cat-themed games, a daily bonus, an admin panel and profile pictures.

- **Frontend:** plain HTML/CSS/JS, hosted free on GitHub Pages
- **Backend/database:** [Supabase](https://supabase.com) free tier (Postgres + auth + storage), no server of your own

## Setup

### 1. Supabase
1. Create a free project at supabase.com.
2. Open **SQL Editor** and run these files **once each, in this order**:
   1. `supabase/schema.sql` (accounts, balances, profile pictures)
   2. `supabase/migration-003-games.sql` (Mines, Crash, Dice, Plinko)
   3. `supabase/migration-004-economy.sql` (daily bonus, draw-a-cat rescue, admin tools)
   4. `supabase/migration-005-more-games.sql` (slots, tower, roulette, scratch cards)
   5. `supabase/migration-006-extras.sql` (multi-drop Plinko, buying several scratch cards, background color gamble)

   Only if you ran an old `schema.sql` from before profile pictures existed: run `migration-002-avatars.sql` first.
3. Open **Project Settings → API** and copy the *Project URL* and the *anon public* key into `config.js`.
4. Optional, for quick testing: **Authentication → Providers → Email** and turn off "Confirm email".

### 2. GitHub
1. Create a repository and push these files to `main`.
2. **Settings → Pages**: *Deploy from a branch*, `main`, `/ (root)`.
3. The site is live at `https://<your-username>.github.io/<repo>/` after a minute.
4. In Supabase, **Authentication → URL Configuration**, set the *Site URL* to that address.

### 3. Make yourself admin
Register on the site first, then run in the SQL Editor (use your username):
```sql
update public.profiles set is_admin = true where username = 'YourName';
```
An **Admin** tab then appears (reload the page).

### Run locally
```
python3 -m http.server 8000
```

## Games
All bets and payouts are decided inside the database; the browser only animates the result.

| Game | Return | Notes |
|---|---|---|
| Cat Slots | 99% | 5 reels × 3 rows, 1–20 lines, low/medium/high risk, autoplay. Goog cat = wild, drooling cat = scatter: pays ×1/×5/×25 of the total bet and starts 8/12/20 free games with doubled wins |
| Cat Tower | 99% | 8 floors, 4 difficulties, cash out any time |
| Cat Roulette | 97.3% | European single zero, straight/red/black/odd/even/low/high/dozen/column, many bets per spin |
| Scratch cards | 99% | 1/5/25/100 goog, buy 1 to 10 cards at once, match 3 of the same cat in a 3×3 grid, top prize ×500 |
| Cucumber Boxes (Mines), Cat Rocket (Crash), Cat Dice | 99% | |
| Cat Drop (Plinko) | 99% | drop 1 to 20 cats per click, one request |
| Tap the goog | | free play |

The Plink cat is only used in Plinko and the drooling cat only in the slots; the other cats appear everywhere else.

## Look and extras
- **Light / dark mode:** button in the top bar (white light mode, purple dark mode), remembered per device.
- **Background color:** Profile → Background color. 1 goog buys a random color (a hue stored on your account, applied in both modes); "Back to default" is free. Price: `bg_color_price()` in migration 006.
- **Disclaimer:** link at the top right. Edit the text in `index.html` (`#view-disclaimer`).

## Daily bonus and rescue
- **Daily bonus:** 25 goog on the first login of each calendar day (Berlin time).
- **Rescue:** below 10 goog a bar offers +10 goog for drawing a cat. The drawing is saved (Admin → Drawings) and, if email is set up, mailed to xsentiq@gmail.com. A note tells the player the goog may be taken back if the drawing isn't good enough; **Reject** in the admin panel removes it again (never below 0). Cooldown: 6 hours.

### Optional: email the drawings
Without this, drawings are still saved and visible in the admin panel.
1. Sign up at resend.com with xsentiq@gmail.com and create an API key. (The free test sender only mails the account owner's own address, which fits here.)
2. In Supabase enable the `pg_net` extension (Database → Extensions).
3. Run:
```sql
insert into public.app_secrets(key, value) values ('resend_api_key', 're_xxxxxxxx')
on conflict (key) do update set value = excluded.value;
```
Optional keys: `drawing_email_to`, `drawing_email_from`.

## Admin panel
Overview stats, user search, add / remove / set goog, ban / unban, give goog to everyone, review drawings, action log. Admin functions check `is_admin` on the server.

## Tuning
In the SQL files: `daily_bonus()`, `rescue_threshold()`, `rescue_amount()`, `rescue_cooldown()` (migration 004), `house_edge()` and `crash_rate()` (migration 003). Re-run the changed `create or replace function`. The slot paytables and scratch prizes are calibrated to exactly 99%; if you edit them the return changes.

goog is play money with no real-world value. If you ever let people buy or cash out goog, these games become real gambling and fall under gambling law.

## Security
The anon key in `config.js` is public by design. Row Level Security lets the browser read `profiles` and change only `avatar_version` on its own row. Balances change only inside server-side functions, which are granted to logged-in users only. Mine positions, crash points and tower traps live in tables the browser cannot read.

## Files
- `index.html`, `style.css`: page and look
- `app.js`: accounts, navigation, leaderboard, profile
- `games.js`: Mines, Crash, Dice, Plinko, Tap
- `games2.js`: slots, tower, roulette, scratch cards
- `extras.js`: daily bonus, rescue drawing, admin panel
- `config.js`: your Supabase URL and anon key
- `assets/`: coin, favicon, `cats/` (slotcat_1–6, plink, drooling_cat)
- `supabase/`: `schema.sql`, `migration-002` … `migration-006`
