-- goog migration 008: play log, stats, achievements, daily / weekly challenges and a weekly leaderboard.
-- Run once in the Supabase SQL Editor, after migration-007. Safe to run again.
--
-- Every settled round of the 8 games (dice, mines, crash, plinko, slots, tower, roulette, scratch) is written to
-- game_plays by the same server-side functions that pay the winnings, so the log cannot be faked from the browser.
-- Achievements and challenge progress are updated in that same transaction. Tap the goog is not a bet and is not logged.
--
-- The game functions further down are the existing ones from migrations 003 and 005 with two extra lines each
-- (_record_play) and an extra 'events' field in their answer. Nothing about the games themselves changes.

-- ---------------------------------------------------------------------------------------------------
-- Tables (no access from the browser at all: everything is read through the functions below)
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.game_plays (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  game        text not null check (game in ('dice', 'mines', 'crash', 'plinko', 'slots', 'tower', 'roulette', 'scratch')),
  bet         bigint not null check (bet >= 1),
  payout      bigint not null check (payout >= 0),
  multiplier  numeric(16, 4) not null,                 -- payout / bet
  meta        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists game_plays_user_time on public.game_plays (user_id, created_at desc);
create index if not exists game_plays_time      on public.game_plays (created_at desc);
create index if not exists game_plays_week      on public.game_plays (created_at, user_id);
create index if not exists game_plays_crash_big on public.game_plays (user_id) where game = 'crash' and multiplier >= 5;

create table if not exists public.player_games (          -- which games a player has tried (for "play every game")
  user_id uuid not null references public.profiles(id) on delete cascade,
  game    text not null,
  primary key (user_id, game)
);

create table if not exists public.achievement_defs (
  code        text primary key,
  title       text not null,
  description text not null,
  reward      int not null default 0 check (reward >= 0),
  sort        int not null default 0
);
create table if not exists public.user_achievements (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  code        text not null references public.achievement_defs(code) on delete cascade,
  unlocked_at timestamptz not null default now(),
  primary key (user_id, code)
);

create table if not exists public.challenge_defs (
  code    text primary key,
  period  text not null check (period in ('daily', 'weekly')),
  title   text not null,
  kind    text not null check (kind in ('plays', 'wins', 'wagered', 'max_payout', 'best_mult', 'distinct_games')),
  game    text,                                         -- null = any game
  target  numeric not null check (target > 0),
  reward  int not null default 0 check (reward >= 0),
  active  boolean not null default true
);
create table if not exists public.challenge_progress (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  code       text not null references public.challenge_defs(code) on delete cascade,
  period_key date not null,                             -- the UTC day (daily) or the Monday (weekly) it belongs to
  progress   numeric not null default 0,
  games      text[] not null default '{}',
  done_at    timestamptz,
  primary key (user_id, code, period_key)
);

alter table public.game_plays          enable row level security;
alter table public.player_games        enable row level security;
alter table public.achievement_defs    enable row level security;
alter table public.user_achievements   enable row level security;
alter table public.challenge_defs      enable row level security;
alter table public.challenge_progress  enable row level security;
revoke all on public.game_plays, public.player_games, public.achievement_defs, public.user_achievements,
              public.challenge_defs, public.challenge_progress from anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- Settings: achievements and challenges (change the numbers here, then run this file again)
-- ---------------------------------------------------------------------------------------------------
insert into public.achievement_defs (code, title, description, reward, sort) values
  ('first_win',         'First win',         'Win a round.',                                              5, 10),
  ('rounds_100',        'Regular',           'Play 100 rounds.',                                         10, 20),
  ('all_games',         'Tried them all',    'Play each of the 8 games at least once.',                  20, 30),
  ('mega_win',          'MEGA WIN',          'Win 50 times your bet or more in a single round.',         25, 40),
  ('tower_top',         'Top of the tower',  'Climb all 8 floors of the Cat Tower.',                     25, 50),
  ('crash_5x_10',       'Rocket regular',    'Cash out 10 Cat Rocket rounds at 5x or more.',             25, 60),
  ('mines_clear',       'Cucumber master',   'Open every safe box in Cucumber Boxes.',                   25, 70),
  ('slots_free',        'Free games!',       'Trigger free games in Cat Slots.',                         10, 80),
  ('roulette_straight', 'Lucky number',      'Hit a single number in Cat Roulette.',                     15, 90),
  ('scratch_jackpot',   'Golden cat',        'Win the top prize on a scratch card (500x).',              50, 100)
on conflict (code) do update set title = excluded.title, description = excluded.description,
                                 reward = excluded.reward, sort = excluded.sort;

-- period: daily resets at 00:00 UTC, weekly on Monday 00:00 UTC. Each period 3 of the active challenges are shown,
-- chosen by the date (so every player sees the same ones). Add more rows to get more variety.
-- kind: plays = number of rounds, wins = rounds won, wagered = goog staked, max_payout = biggest single payout,
--       best_mult = best single multiplier, distinct_games = different games played
insert into public.challenge_defs (code, period, title, kind, game, target, reward) values
  ('d_plinko_20',   'daily',  'Drop 20 cats in Cat Drop',                'plays',      'plinko',   20,  8),
  ('d_slots_30',    'daily',  'Spin the Cat Slots 30 times',             'plays',      'slots',    30,  8),
  ('d_scratch_5',   'daily',  'Scratch 5 cards',                         'plays',      'scratch',   5,  6),
  ('d_roulette_10', 'daily',  'Spin the roulette wheel 10 times',        'plays',      'roulette', 10,  6),
  ('d_dice_15',     'daily',  'Roll the dice 15 times',                  'plays',      'dice',     15,  6),
  ('d_any_25',      'daily',  'Play 25 rounds in any game',              'plays',      null,       25,  6),
  ('d_wins_10',     'daily',  'Win 10 rounds in any game',               'wins',       null,       10,  8),
  ('d_wager_200',   'daily',  'Wager 200 goog in total',                 'wagered',    null,      200,  8),
  ('d_crash_3x',    'daily',  'Cash out Cat Rocket at 3x or more',       'best_mult',  'crash',     3,  8),
  ('d_mines_3',     'daily',  'Win 3 rounds of Cucumber Boxes',          'wins',       'mines',     3,  8),
  ('w_big_win',     'weekly', 'Land a single win of 250 goog or more',   'max_payout', null,      250, 40),
  ('w_mult_20',     'weekly', 'Hit a 20x win in any game',               'best_mult',  null,       20, 40),
  ('w_plays_150',   'weekly', 'Play 150 rounds',                         'plays',      null,      150, 30),
  ('w_wins_60',     'weekly', 'Win 60 rounds',                           'wins',       null,       60, 30),
  ('w_wager_2000',  'weekly', 'Wager 2,000 goog in total',               'wagered',    null,     2000, 35),
  ('w_games_5',     'weekly', 'Play 5 different games',                  'distinct_games', null,    5, 30)
on conflict (code) do update set period = excluded.period, title = excluded.title, kind = excluded.kind,
                                 game = excluded.game, target = excluded.target, reward = excluded.reward;

-- ---------------------------------------------------------------------------------------------------
-- Periods (UTC)
-- ---------------------------------------------------------------------------------------------------
create or replace function public._period_key(p_period text) returns date
language sql stable as $$
  select case p_period when 'weekly' then date_trunc('week', now() at time zone 'utc')::date
                       else (now() at time zone 'utc')::date end
$$;
create or replace function public._period_start(p_period text) returns timestamptz
language sql stable as $$ select public._period_key(p_period)::timestamp at time zone 'utc' $$;
create or replace function public._period_end(p_period text) returns timestamptz
language sql stable as $$ select public._period_start(p_period) + case p_period when 'weekly' then interval '7 days' else interval '1 day' end $$;

create or replace function public._active_challenges(p_period text) returns setof public.challenge_defs
language sql stable as $$
  select * from public.challenge_defs
  where period = p_period and active
  order by md5(code || public._period_key(p_period)::text)
  limit 3
$$;

-- ---------------------------------------------------------------------------------------------------
-- Achievements
-- ---------------------------------------------------------------------------------------------------
create or replace function public._ev_reward(ev jsonb) returns bigint
language sql immutable as $$
  select coalesce(sum((e ->> 'reward')::bigint), 0) from jsonb_array_elements(coalesce(ev, '[]'::jsonb)) e
$$;

create or replace function public._check_achievements(p_user uuid, p_game text, p_bet bigint, p_payout bigint, p_mult numeric, p_meta jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare have text[]; want text[] := '{}'; c text; d public.achievement_defs; v_ev jsonb := '[]'::jsonb; v_n int;
begin
  select coalesce(array_agg(code), '{}') into have from public.user_achievements where user_id = p_user;

  if not ('first_win' = any (have)) and p_payout > p_bet then want := array_append(want, 'first_win'); end if;
  if not ('mega_win' = any (have)) and p_mult >= 50 then want := array_append(want, 'mega_win'); end if;
  if not ('tower_top' = any (have)) and p_game = 'tower' and p_payout > 0
     and coalesce((p_meta ->> 'floors')::int, 0) >= public._tower_rows() then want := array_append(want, 'tower_top'); end if;
  if not ('mines_clear' = any (have)) and p_game = 'mines' and coalesce((p_meta ->> 'cleared')::boolean, false) then
    want := array_append(want, 'mines_clear'); end if;
  if not ('slots_free' = any (have)) and p_game = 'slots' and coalesce((p_meta ->> 'scatters')::int, 0) >= 3 then
    want := array_append(want, 'slots_free'); end if;
  if not ('roulette_straight' = any (have)) and p_game = 'roulette' and coalesce((p_meta ->> 'straight_hit')::boolean, false) then
    want := array_append(want, 'roulette_straight'); end if;
  if not ('scratch_jackpot' = any (have)) and p_game = 'scratch' and p_mult >= 500 then
    want := array_append(want, 'scratch_jackpot'); end if;
  if not ('crash_5x_10' = any (have)) and p_game = 'crash' and p_mult >= 5 then
    select count(*) into v_n from (select 1 from public.game_plays where user_id = p_user and game = 'crash' and multiplier >= 5 limit 10) s;
    if v_n >= 10 then want := array_append(want, 'crash_5x_10'); end if;
  end if;
  if not ('all_games' = any (have)) then
    select count(*) into v_n from public.player_games where user_id = p_user;
    if v_n >= 8 then want := array_append(want, 'all_games'); end if;
  end if;
  if not ('rounds_100' = any (have)) then
    select count(*) into v_n from (select 1 from public.game_plays where user_id = p_user limit 100) s;
    if v_n >= 100 then want := array_append(want, 'rounds_100'); end if;
  end if;

  foreach c in array want loop
    insert into public.user_achievements (user_id, code) values (p_user, c) on conflict do nothing;
    if found then
      select * into d from public.achievement_defs where code = c;
      if coalesce(d.reward, 0) > 0 then perform public._pay(p_user, d.reward); end if;
      v_ev := v_ev || jsonb_build_array(jsonb_build_object('type', 'achievement', 'code', c, 'title', d.title, 'reward', coalesce(d.reward, 0)));
    end if;
  end loop;
  return v_ev;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- Challenges: progress is updated one round at a time (no scanning of the log)
-- ---------------------------------------------------------------------------------------------------
create or replace function public._check_challenges(p_user uuid, p_game text, p_bet bigint, p_payout bigint, p_mult numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.challenge_defs; cp public.challenge_progress; v_key date; v_new numeric; v_games text[]; v_ev jsonb := '[]'::jsonb;
begin
  for c in select * from public._active_challenges('daily') union all select * from public._active_challenges('weekly') loop
    continue when c.game is not null and c.game <> p_game;
    v_key := public._period_key(c.period);
    select * into cp from public.challenge_progress where user_id = p_user and code = c.code and period_key = v_key for update;
    if not found then
      insert into public.challenge_progress (user_id, code, period_key) values (p_user, c.code, v_key) returning * into cp;
    end if;
    continue when cp.done_at is not null;

    v_games := cp.games;
    v_new := case c.kind
      when 'plays'      then cp.progress + 1
      when 'wins'       then cp.progress + case when p_payout > p_bet then 1 else 0 end
      when 'wagered'    then cp.progress + p_bet
      when 'max_payout' then greatest(cp.progress, p_payout)
      when 'best_mult'  then greatest(cp.progress, p_mult)
      when 'distinct_games' then cp.progress + case when p_game = any (cp.games) then 0 else 1 end
      else cp.progress end;
    if c.kind = 'distinct_games' and not (p_game = any (v_games)) then v_games := array_append(v_games, p_game); end if;

    if v_new >= c.target then
      update public.challenge_progress set progress = v_new, games = v_games, done_at = now()
        where user_id = p_user and code = c.code and period_key = v_key;
      if c.reward > 0 then perform public._pay(p_user, c.reward); end if;
      v_ev := v_ev || jsonb_build_array(jsonb_build_object('type', 'challenge', 'code', c.code, 'title', c.title,
                                                          'period', c.period, 'reward', c.reward));
    elsif v_new is distinct from cp.progress then
      update public.challenge_progress set progress = v_new, games = v_games
        where user_id = p_user and code = c.code and period_key = v_key;
    end if;
  end loop;
  return v_ev;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- The one place that logs a round. Called only from the game functions below (not from the browser).
-- Returns a list of things that just happened (achievements / completed challenges), including their goog rewards.
-- ---------------------------------------------------------------------------------------------------
create or replace function public._record_play(p_user uuid, p_game text, p_bet bigint, p_payout bigint, p_meta jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_mult numeric; v_ev jsonb;
begin
  v_mult := round(p_payout::numeric / p_bet, 4);
  insert into public.game_plays (user_id, game, bet, payout, multiplier, meta)
    values (p_user, p_game, p_bet, p_payout, v_mult, coalesce(p_meta, '{}'::jsonb));
  insert into public.player_games (user_id, game) values (p_user, p_game) on conflict do nothing;
  v_ev := public._check_achievements(p_user, p_game, p_bet, p_payout, v_mult, coalesce(p_meta, '{}'::jsonb))
       || public._check_challenges(p_user, p_game, p_bet, p_payout, v_mult);
  return v_ev;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- The game functions (migrations 003 and 005) with the logging added
-- ---------------------------------------------------------------------------------------------------
create or replace function public.play_dice(p_bet bigint, p_target numeric, p_over boolean)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_target numeric; v_chance numeric; v_mult numeric; v_roll numeric;
  v_win boolean; v_pay bigint := 0; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_target is null or p_target < 2 or p_target > 98 then raise exception 'Target must be between 2 and 98'; end if;
  v_target := round(p_target, 2);
  -- rolls are 0.00 .. 99.99 (10,000 equally likely values)
  v_chance := case when p_over then 99.99 - v_target else v_target end;      -- in percent
  v_mult   := round(100 * (1 - public.house_edge()) / v_chance, 4);

  v_bal  := public._take_bet(v_uid, p_bet);
  v_roll := floor(public.secure_random() * 10000)::numeric / 100;
  v_win  := case when p_over then v_roll > v_target else v_roll < v_target end;
  if v_win then
    v_pay := floor(p_bet * v_mult);
    v_bal := public._pay(v_uid, v_pay);
  end if;
  v_ev  := public._record_play(v_uid, 'dice', p_bet, v_pay, jsonb_build_object('target', v_target, 'over', p_over, 'chance', v_chance));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('roll', v_roll, 'win', v_win, 'multiplier', v_mult, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.mines_reveal(p_tile int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); g public.mines_games%rowtype;
  v_rev smallint[]; v_safe int; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.mines_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active round'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Invalid box'; end if;
  if p_tile::smallint = any (g.revealed) then raise exception 'Box already opened'; end if;

  if p_tile::smallint = any (g.mine_tiles) then
    update public.mines_games set status = 'lost' where id = g.id;
    v_ev := public._record_play(v_uid, 'mines', g.bet, 0, jsonb_build_object('mines', g.mines, 'opened', cardinality(g.revealed)));
    select goog into v_bal from public.profiles where id = v_uid;
    return json_build_object('hit', true, 'tile', p_tile, 'revealed', g.revealed,
                             'mine_tiles', g.mine_tiles, 'balance', v_bal, 'events', v_ev);
  end if;

  v_rev  := array_append(g.revealed, p_tile::smallint);
  v_safe := cardinality(v_rev);
  v_mult := public.mines_multiplier(g.mines, v_safe);

  if v_safe = 25 - g.mines then                      -- every safe box opened: automatic cash-out
    v_pay := floor(g.bet * v_mult);
    v_bal := public._pay(v_uid, v_pay);
    update public.mines_games set revealed = v_rev, status = 'won', payout = v_pay where id = g.id;
    v_ev  := public._record_play(v_uid, 'mines', g.bet, v_pay, jsonb_build_object('mines', g.mines, 'opened', v_safe, 'cleared', true));
    v_bal := v_bal + public._ev_reward(v_ev);
    return json_build_object('hit', false, 'done', true, 'revealed', v_rev, 'mine_tiles', g.mine_tiles,
                             'multiplier', v_mult, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
  end if;

  update public.mines_games set revealed = v_rev where id = g.id;
  select goog into v_bal from public.profiles where id = v_uid;
  return json_build_object('hit', false, 'done', false, 'revealed', v_rev, 'multiplier', v_mult,
                           'next_multiplier', public.mines_multiplier(g.mines, v_safe + 1), 'balance', v_bal);
end $$;

create or replace function public.mines_cashout()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); g public.mines_games%rowtype; v_safe int; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.mines_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active round'; end if;
  v_safe := cardinality(g.revealed);
  if v_safe < 1 then raise exception 'Open at least one box first'; end if;
  v_mult := public.mines_multiplier(g.mines, v_safe);
  v_pay  := floor(g.bet * v_mult);
  v_bal  := public._pay(v_uid, v_pay);
  update public.mines_games set status = 'won', payout = v_pay where id = g.id;
  v_ev  := public._record_play(v_uid, 'mines', g.bet, v_pay, jsonb_build_object('mines', g.mines, 'opened', v_safe));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('payout', v_pay, 'multiplier', v_mult, 'revealed', g.revealed,
                           'mine_tiles', g.mine_tiles, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public._crash_settle(p_user uuid, p_cash boolean)
returns json language plpgsql security definer set search_path = public as $$
declare
  g public.crash_games%rowtype; v_el numeric; v_cur numeric; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  select * into g from public.crash_games where user_id = p_user and status = 'active' for update;
  if not found then return null; end if;

  v_el  := extract(epoch from (clock_timestamp() - g.started_at));
  v_cur := exp(public.crash_rate() * v_el);

  if g.auto_cashout is not null and g.auto_cashout < g.crash_point and v_cur >= g.auto_cashout then
    v_mult := g.auto_cashout;                                   -- auto cash-out was reached before the crash
  elsif v_cur >= g.crash_point then
    update public.crash_games set status = 'lost', final_multiplier = g.crash_point where id = g.id;
    v_ev := public._record_play(p_user, 'crash', g.bet, 0, jsonb_build_object('crash_point', g.crash_point));
    select goog into v_bal from public.profiles where id = p_user;
    return json_build_object('status', 'lost', 'crash_point', g.crash_point, 'bet', g.bet, 'balance', v_bal, 'events', v_ev);
  elsif p_cash then
    v_mult := greatest(1.00, floor(v_cur * 100) / 100);         -- manual cash-out at the current multiplier
  else
    return json_build_object('status', 'active', 'elapsed_ms', round(v_el * 1000),
                             'rate', public.crash_rate(), 'bet', g.bet, 'auto', g.auto_cashout);
  end if;

  v_pay := floor(g.bet * v_mult);
  v_bal := public._pay(p_user, v_pay);
  update public.crash_games set status = 'won', payout = v_pay, final_multiplier = v_mult where id = g.id;
  v_ev  := public._record_play(p_user, 'crash', g.bet, v_pay, jsonb_build_object('cashout', v_mult, 'crash_point', g.crash_point));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('status', 'won', 'multiplier', v_mult, 'payout', v_pay,
                           'crash_point', g.crash_point, 'bet', g.bet, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.crash_start(p_bet bigint, p_auto numeric default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_prev json; v_bal bigint; v_cp numeric; v_r double precision;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_auto is not null and (p_auto < 1.01 or p_auto > 1000) then
    raise exception 'Auto cash-out must be between 1.01 and 1000';
  end if;
  v_prev := public._crash_settle(v_uid, false);                 -- closes a round that already crashed
  if v_prev is not null and (v_prev ->> 'status') = 'active' then
    raise exception 'A round is already running';
  end if;
  v_bal := public._take_bet(v_uid, p_bet);
  v_r   := public.secure_random();
  v_cp  := least(1000::numeric, greatest(1.00::numeric,
             (floor((100 * (1 - public.house_edge()))::double precision / (1 - v_r)) / 100.0)::numeric));
  insert into public.crash_games (user_id, bet, crash_point, auto_cashout, started_at)
  values (v_uid, p_bet, v_cp, p_auto, clock_timestamp());
  return json_build_object('rate', public.crash_rate(), 'elapsed_ms', 0, 'bet', p_bet,
                           'auto', p_auto, 'balance', v_bal,
                           'events', coalesce(v_prev -> 'events', '[]'::json));
end $$;

create or replace function public.play_plinko(p_bet bigint, p_rows int, p_risk text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_tbl numeric[]; v_path int[] := '{}'; v_slot int := 0;
  i int; v_bit int; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  v_tbl := public.plinko_table(p_rows, p_risk);
  v_bal := public._take_bet(v_uid, p_bet);
  for i in 1 .. p_rows loop                                          -- every peg: left (0) or right (1), 50/50
    v_bit  := case when public.secure_random() < 0.5 then 1 else 0 end;
    v_path := array_append(v_path, v_bit);
    v_slot := v_slot + v_bit;
  end loop;
  v_mult := v_tbl[v_slot + 1];
  v_pay  := floor(p_bet * v_mult);
  if v_pay > 0 then v_bal := public._pay(v_uid, v_pay); end if;
  v_ev  := public._record_play(v_uid, 'plinko', p_bet, v_pay, jsonb_build_object('rows', p_rows, 'risk', p_risk, 'slot', v_slot));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('path', v_path, 'slot', v_slot, 'multiplier', v_mult,
                           'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.play_slots(p_per_line bigint, p_lines int, p_risk text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_total bigint; v_bal bigint; v_base json; v_sp json;
  v_scat int; v_nfree int := 0; v_free jsonb := '[]'::jsonb; v_free_win numeric := 0;
  v_base_win numeric; v_scat_win numeric := 0; v_grand numeric; v_pay bigint; i int; v_fw numeric; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_risk is null or p_risk not in ('low', 'medium', 'high') then raise exception 'Risk must be low, medium or high'; end if;
  if p_lines is null or p_lines < 1 or p_lines > 20 then raise exception 'Choose 1 to 20 lines'; end if;
  if p_per_line is null or p_per_line < 1 or p_per_line > 1000000 then raise exception 'Bet per line must be 1 to 1,000,000 goog'; end if;
  v_total := p_per_line * p_lines;
  v_bal := public._take_bet(v_uid, v_total);

  v_base := public._slots_spin(p_lines, p_risk);
  v_scat := (v_base ->> 'scatters')::int;
  v_base_win := (v_base ->> 'line_mult')::numeric * p_per_line;

  if v_scat >= 3 then
    v_scat_win := v_total * case when v_scat >= 5 then 25 when v_scat = 4 then 5 else 1 end;
    v_nfree := case when v_scat >= 5 then 20 when v_scat = 4 then 12 else 8 end;
    for i in 1 .. v_nfree loop
      v_sp := public._slots_spin(p_lines, p_risk);
      v_fw := (v_sp ->> 'line_mult')::numeric * p_per_line * 2;                  -- free games pay double
      v_free_win := v_free_win + v_fw;
      v_free := v_free || jsonb_build_object('grid', v_sp -> 'grid', 'wins', v_sp -> 'wins', 'win', round(v_fw, 2));
    end loop;
  end if;

  v_grand := v_base_win + v_scat_win + v_free_win;
  v_pay := floor(v_grand)::bigint;
  if public.secure_random() < (v_grand - floor(v_grand)) then v_pay := v_pay + 1; end if;   -- unbiased rounding
  if v_pay > 0 then v_bal := public._pay(v_uid, v_pay); end if;

  v_ev  := public._record_play(v_uid, 'slots', v_total, v_pay, jsonb_build_object('lines', p_lines, 'risk', p_risk, 'scatters', v_scat, 'free_spins', v_nfree));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object(
    'grid', v_base -> 'grid', 'wins', v_base -> 'wins', 'base_win', round(v_base_win, 2),
    'scatters', v_scat, 'scatter_win', v_scat_win,
    'free_spins', v_nfree, 'free', v_free, 'free_win', round(v_free_win, 2),
    'total_bet', v_total, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.tower_pick(p_tile int) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); g public.tower_games%rowtype; v_level int; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.tower_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active climb'; end if;
  if p_tile is null or p_tile < 0 or p_tile >= g.tiles then raise exception 'Invalid tile'; end if;
  v_level := coalesce(array_length(g.picks, 1), 0);                 -- floors cleared so far (0-based index of this floor)

  if (g.trap_masks[v_level + 1] & (1 << p_tile)) <> 0 then
    update public.tower_games set status = 'lost' where id = g.id;
    v_ev := public._record_play(v_uid, 'tower', g.bet, 0, jsonb_build_object('difficulty', g.difficulty, 'floors', v_level));
    select goog into v_bal from public.profiles where id = v_uid;
    return json_build_object('hit', true, 'level', v_level, 'tile', p_tile, 'picks', g.picks,
                             'trap_masks', g.trap_masks, 'balance', v_bal, 'events', v_ev);
  end if;

  v_level := v_level + 1;
  v_mult := public._tower_mult(g.tiles, g.traps, v_level);
  if v_level = public._tower_rows() then                            -- reached the top: automatic cash-out
    v_pay := floor(g.bet * v_mult)::bigint;
    v_bal := public._pay(v_uid, v_pay);
    update public.tower_games set picks = array_append(picks, p_tile), status = 'won', payout = v_pay where id = g.id;
    v_ev  := public._record_play(v_uid, 'tower', g.bet, v_pay, jsonb_build_object('difficulty', g.difficulty, 'floors', v_level));
    v_bal := v_bal + public._ev_reward(v_ev);
    return json_build_object('hit', false, 'done', true, 'level', v_level, 'picks', array_append(g.picks, p_tile),
                             'multiplier', v_mult, 'payout', v_pay, 'trap_masks', g.trap_masks, 'balance', v_bal, 'events', v_ev);
  end if;
  update public.tower_games set picks = array_append(picks, p_tile) where id = g.id;
  select goog into v_bal from public.profiles where id = v_uid;
  return json_build_object('hit', false, 'done', false, 'level', v_level, 'picks', array_append(g.picks, p_tile),
                           'multiplier', v_mult, 'next_multiplier', public._tower_mult(g.tiles, g.traps, v_level + 1),
                           'balance', v_bal);
end $$;

create or replace function public.tower_cashout() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); g public.tower_games%rowtype; v_level int; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.tower_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active climb'; end if;
  v_level := coalesce(array_length(g.picks, 1), 0);
  if v_level < 1 then raise exception 'Climb at least one floor first'; end if;
  v_mult := public._tower_mult(g.tiles, g.traps, v_level);
  v_pay := floor(g.bet * v_mult)::bigint;
  v_bal := public._pay(v_uid, v_pay);
  update public.tower_games set status = 'won', payout = v_pay where id = g.id;
  v_ev  := public._record_play(v_uid, 'tower', g.bet, v_pay, jsonb_build_object('difficulty', g.difficulty, 'floors', v_level));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('payout', v_pay, 'multiplier', v_mult, 'level', v_level, 'picks', g.picks,
                           'trap_masks', g.trap_masks, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.play_roulette(p_bets jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); b jsonb; v_type text; v_val int; v_amt bigint; v_total bigint := 0;
  v_n int; v_pay bigint := 0; v_one bigint; v_win boolean; v_res jsonb := '[]'::jsonb; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_bets is null or jsonb_typeof(p_bets) <> 'array' or jsonb_array_length(p_bets) < 1 or jsonb_array_length(p_bets) > 60 then
    raise exception 'Place between 1 and 60 bets';
  end if;
  -- validate everything before taking money
  for b in select * from jsonb_array_elements(p_bets) loop
    v_type := b ->> 'type';
    begin v_amt := (b ->> 'amount')::bigint; v_val := (b ->> 'value')::int; exception when others then raise exception 'Invalid bet'; end;
    if v_amt is null or v_amt < 1 or v_amt > 1000000 then raise exception 'Each bet must be 1 to 1,000,000 goog'; end if;
    if v_type = 'straight' then
      if v_val is null or v_val < 0 or v_val > 36 then raise exception 'Straight bets need a number from 0 to 36'; end if;
    elsif v_type in ('dozen', 'column') then
      if v_val is null or v_val < 1 or v_val > 3 then raise exception 'Choose 1, 2 or 3'; end if;
    elsif v_type not in ('red', 'black', 'even', 'odd', 'low', 'high') then
      raise exception 'Unknown bet type';
    end if;
    v_total := v_total + v_amt;
  end loop;

  v_bal := public._take_bet(v_uid, v_total);
  v_n := floor(public.secure_random() * 37)::int;

  for b in select * from jsonb_array_elements(p_bets) loop
    v_type := b ->> 'type'; v_amt := (b ->> 'amount')::bigint; v_val := (b ->> 'value')::int;
    v_win := case v_type
      when 'straight' then v_n = v_val
      when 'red'      then v_n > 0 and public._roulette_red(v_n)
      when 'black'    then v_n > 0 and not public._roulette_red(v_n)
      when 'even'     then v_n > 0 and v_n % 2 = 0
      when 'odd'      then v_n % 2 = 1
      when 'low'      then v_n between 1 and 18
      when 'high'     then v_n between 19 and 36
      when 'dozen'    then v_n > 0 and (v_n - 1) / 12 + 1 = v_val
      when 'column'   then v_n > 0 and (case when v_n % 3 = 0 then 3 else v_n % 3 end) = v_val
    end;
    v_one := case when not v_win then 0
                  when v_type = 'straight' then v_amt * 36
                  when v_type in ('dozen', 'column') then v_amt * 3
                  else v_amt * 2 end;                               -- payout includes the stake
    v_pay := v_pay + v_one;
    v_res := v_res || jsonb_build_object('type', v_type, 'value', v_val, 'amount', v_amt, 'win', v_win, 'payout', v_one);
  end loop;
  if v_pay > 0 then v_bal := public._pay(v_uid, v_pay); end if;
  v_ev  := public._record_play(v_uid, 'roulette', v_total, v_pay, jsonb_build_object('number', v_n, 'straight_hit', exists (select 1 from jsonb_array_elements(v_res) e where e ->> 'type' = 'straight' and (e ->> 'win')::boolean)));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('number', v_n,
    'color', case when v_n = 0 then 'green' when public._roulette_red(v_n) then 'red' else 'black' end,
    'results', v_res, 'total_bet', v_total, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.play_scratch(p_price bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_bal bigint; pr int[] := public._scratch_prizes(); r int; acc int := 0; i int;
  v_sym int := null; v_mult int := 0; v_cells int[]; v_pool int[]; v_pay bigint := 0; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_price is null or p_price not in (1, 5, 25, 100) then raise exception 'Cards cost 1, 5, 25 or 100 goog'; end if;
  v_bal := public._take_bet(v_uid, p_price);

  r := floor(public.secure_random() * 1000000)::int;
  for i in 1 .. 6 loop
    acc := acc + pr[i][3];
    if r < acc then v_sym := pr[i][1]; v_mult := pr[i][2]; exit; end if;
  end loop;

  if v_sym is null then
    -- losing card: any 9 of 12 tiles (every cat twice), so no cat appears 3 times
    select array_agg(c order by public.secure_random()) into v_pool from (select c from generate_series(1, 6) c, generate_series(1, 2)) x;
    v_cells := v_pool[1:9];
  else
    -- winning card: exactly 3 winning cats, the other 6 tiles from the other cats (each at most twice)
    select array_agg(c order by public.secure_random()) into v_pool
      from (select c from generate_series(1, 6) c, generate_series(1, 2) where c <> v_sym) x;
    v_cells := v_pool[1:6] || array[v_sym, v_sym, v_sym];
    select array_agg(c order by public.secure_random()) into v_cells from unnest(v_cells) c;
    v_pay := p_price * v_mult;
    v_bal := public._pay(v_uid, v_pay);
  end if;
  v_ev  := public._record_play(v_uid, 'scratch', p_price, v_pay, jsonb_build_object('symbol', v_sym));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('cells', v_cells, 'win_symbol', v_sym, 'multiplier', v_mult,
                           'price', p_price, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- What the site reads
-- ---------------------------------------------------------------------------------------------------
-- Per game totals, the biggest win and the totals, for the logged-in player
create or replace function public.my_stats() returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  return json_build_object(
    'games', coalesce((
      select json_agg(json_build_object('game', game, 'plays', plays, 'wagered', wagered, 'paid', paid, 'net', paid - wagered,
                                        'best_win', best) order by game)
      from (select game, count(*) plays, sum(bet) wagered, sum(payout) paid, max(payout - bet) best
            from public.game_plays where user_id = v_uid group by game) g), '[]'::json),
    'biggest', (
      select json_build_object('game', game, 'bet', bet, 'payout', payout, 'profit', payout - bet, 'multiplier', multiplier, 'at', created_at)
      from public.game_plays where user_id = v_uid and payout > bet order by payout - bet desc, created_at desc limit 1)
  );
end $$;

create or replace function public.my_recent_plays(p_limit int default 20) returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  return coalesce((
    select json_agg(json_build_object('game', game, 'bet', bet, 'payout', payout, 'multiplier', multiplier, 'at', created_at) order by created_at desc, id desc)
    from (select * from public.game_plays where user_id = v_uid order by created_at desc, id desc limit least(greatest(coalesce(p_limit, 20), 1), 100)) r
  ), '[]'::json);
end $$;

create or replace function public.my_achievements() returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  return coalesce((
    select json_agg(json_build_object('code', d.code, 'title', d.title, 'description', d.description, 'reward', d.reward,
                                      'unlocked_at', u.unlocked_at) order by d.sort)
    from public.achievement_defs d
    left join public.user_achievements u on u.code = d.code and u.user_id = v_uid
  ), '[]'::json);
end $$;

create or replace function public._challenge_items(p_user uuid, p_period text) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('code', c.code, 'title', c.title, 'kind', c.kind, 'game', c.game,
                                             'target', c.target, 'reward', c.reward,
                                             'progress', least(coalesce(cp.progress, 0), c.target),
                                             'done', cp.done_at is not null) order by c.code), '[]'::json)
  from public._active_challenges(p_period) c
  left join public.challenge_progress cp
    on cp.user_id = p_user and cp.code = c.code and cp.period_key = public._period_key(p_period)
$$;

create or replace function public.my_challenges() returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  return json_build_object(
    'daily',  json_build_object('resets_at', public._period_end('daily'),  'items', public._challenge_items(v_uid, 'daily')),
    'weekly', json_build_object('resets_at', public._period_end('weekly'), 'items', public._challenge_items(v_uid, 'weekly')));
end $$;

-- Weekly leaderboard: net goog won this week (UTC, Monday to Sunday), top 10. Resets together with the weekly challenges.
create or replace function public.weekly_board() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Log in first'; end if;
  return json_build_object(
    'resets_at', public._period_end('weekly'),
    'rows', coalesce((
      select json_agg(json_build_object('id', id, 'username', username, 'avatar_version', avatar_version,
                                        'net', net, 'best_win', best, 'plays', plays) order by net desc, best desc, username)
      from (select p.id, p.username, p.avatar_version, sum(g.payout - g.bet) net, max(g.payout) best, count(*) plays
            from public.game_plays g join public.profiles p on p.id = g.user_id
            where g.created_at >= public._period_start('weekly')
            group by p.id, p.username, p.avatar_version
            order by sum(g.payout - g.bet) desc, max(g.payout) desc, p.username limit 10) r), '[]'::json));
end $$;

-- Admin: what the games really paid back compared to the target (all time, or the last p_days days).
-- "margin" is the usual random noise (about 95% of the time the real return lies within +/- margin of the long-run value).
create or replace function public.admin_game_stats(p_days int default null) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((
    select json_agg(r order by r.game) from (
      select game, count(*) plays, count(distinct user_id) players, sum(bet) wagered, sum(payout) paid,
             round(sum(payout)::numeric / nullif(sum(bet), 0), 4) rtp,
             case game when 'roulette' then 0.9730 else 0.9900 end target,
             round(1.96 * coalesce(stddev_samp(multiplier), 0) / sqrt(greatest(count(*), 1)::numeric), 4) margin
      from public.game_plays
      where p_days is null or created_at >= now() - make_interval(days => p_days)
      group by game) r), '[]'::json);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- permissions: helpers are server-only, the readers are for logged-in players
-- ---------------------------------------------------------------------------------------------------
revoke execute on function
  public._period_key(text), public._period_start(text), public._period_end(text), public._active_challenges(text),
  public._ev_reward(jsonb),
  public._check_achievements(uuid, text, bigint, bigint, numeric, jsonb),
  public._check_challenges(uuid, text, bigint, bigint, numeric),
  public._record_play(uuid, text, bigint, bigint, jsonb),
  public._challenge_items(uuid, text),
  public.my_stats(), public.my_recent_plays(int), public.my_achievements(), public.my_challenges(), public.weekly_board(),
  public.admin_game_stats(int)
from public, anon, authenticated;

grant execute on function
  public.my_stats(), public.my_recent_plays(int), public.my_achievements(), public.my_challenges(), public.weekly_board(),
  public.admin_game_stats(int)
to authenticated;
