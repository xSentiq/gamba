-- Games: Cucumber Boxes (Mines), Cat Rocket (Crash), Cat Dice (Dice), Cat Drop (Plinko).
-- Run in Supabase → SQL Editor AFTER schema.sql (or migration-002-avatars.sql).
--
-- Every round is decided HERE, in the database, with cryptographically secure randomness.
-- The browser only asks to play and shows what the server decided, so nobody can cheat from the console.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- settings
create or replace function public.house_edge() returns numeric
language sql immutable as $$ select 0.01::numeric $$;           -- 1% => about 99% return to player

create or replace function public.crash_rate() returns numeric
language sql immutable as $$ select 0.09::numeric $$;           -- multiplier = e^(rate * seconds)

-- ---------------------------------------------------------------- helpers (not callable from the browser)
create or replace function public.secure_random() returns double precision
language sql volatile as $$
  select (('x' || encode(extensions.gen_random_bytes(7), 'hex'))::bit(56)::bigint)::double precision
         / 72057594037927936.0   -- 2^56, result is in [0, 1)
$$;

create or replace function public._take_bet(p_user uuid, p_bet bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_bal bigint;
begin
  if p_bet is null or p_bet < 1 then raise exception 'Bet at least 1 goog'; end if;
  select goog into v_bal from public.profiles where id = p_user for update;
  if not found then raise exception 'Profile not found'; end if;
  if p_bet > v_bal then raise exception 'Not enough goog'; end if;
  update public.profiles set goog = goog - p_bet where id = p_user returning goog into v_bal;
  return v_bal;
end $$;

create or replace function public._pay(p_user uuid, p_amount bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_bal bigint;
begin
  update public.profiles set goog = goog + p_amount where id = p_user returning goog into v_bal;
  return v_bal;
end $$;

-- ================================================================ DICE
create or replace function public.play_dice(p_bet bigint, p_target numeric, p_over boolean)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_target numeric; v_chance numeric; v_mult numeric; v_roll numeric;
  v_win boolean; v_pay bigint := 0; v_bal bigint;
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
  return json_build_object('roll', v_roll, 'win', v_win, 'multiplier', v_mult, 'payout', v_pay, 'balance', v_bal);
end $$;

-- ================================================================ MINES (5x5 grid, tiles 0..24)
create table if not exists public.mines_games (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  bet        bigint not null,
  mines      smallint not null check (mines between 1 and 24),
  mine_tiles smallint[] not null,                 -- secret until the round ends
  revealed   smallint[] not null default '{}',
  status     text not null default 'active' check (status in ('active', 'won', 'lost')),
  payout     bigint not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists mines_one_active_per_user on public.mines_games (user_id) where status = 'active';
alter table public.mines_games enable row level security;
revoke all on public.mines_games from anon, authenticated;   -- no policies: the browser can never read it

create or replace function public.mines_multiplier(p_mines int, p_safe int) returns numeric
language plpgsql immutable as $$
declare m numeric := 1; i int;
begin
  if p_safe < 1 then return 1; end if;
  for i in 0 .. p_safe - 1 loop
    m := m * (25 - i)::numeric / (25 - p_mines - i);
  end loop;
  return round(m * (1 - public.house_edge()), 4);
end $$;

create or replace function public.mines_start(p_bet bigint, p_mines int)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_bal bigint; v_tiles smallint[];
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 24 then raise exception 'Choose 1 to 24 cucumbers'; end if;
  if exists (select 1 from public.mines_games where user_id = v_uid and status = 'active') then
    raise exception 'Finish your current round first';
  end if;
  v_bal := public._take_bet(v_uid, p_bet);
  select array_agg(t::smallint) into v_tiles
  from (select t from generate_series(0, 24) as t order by public.secure_random() limit p_mines) s;
  insert into public.mines_games (user_id, bet, mines, mine_tiles)
  values (v_uid, p_bet, p_mines::smallint, v_tiles);
  return json_build_object('balance', v_bal, 'bet', p_bet, 'mines', p_mines,
                           'next_multiplier', public.mines_multiplier(p_mines, 1));
end $$;

create or replace function public.mines_reveal(p_tile int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); g public.mines_games%rowtype;
  v_rev smallint[]; v_safe int; v_mult numeric; v_pay bigint; v_bal bigint;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.mines_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active round'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Invalid box'; end if;
  if p_tile::smallint = any (g.revealed) then raise exception 'Box already opened'; end if;

  if p_tile::smallint = any (g.mine_tiles) then
    update public.mines_games set status = 'lost' where id = g.id;
    select goog into v_bal from public.profiles where id = v_uid;
    return json_build_object('hit', true, 'tile', p_tile, 'revealed', g.revealed,
                             'mine_tiles', g.mine_tiles, 'balance', v_bal);
  end if;

  v_rev  := array_append(g.revealed, p_tile::smallint);
  v_safe := cardinality(v_rev);
  v_mult := public.mines_multiplier(g.mines, v_safe);

  if v_safe = 25 - g.mines then                      -- every safe box opened: automatic cash-out
    v_pay := floor(g.bet * v_mult);
    v_bal := public._pay(v_uid, v_pay);
    update public.mines_games set revealed = v_rev, status = 'won', payout = v_pay where id = g.id;
    return json_build_object('hit', false, 'done', true, 'revealed', v_rev, 'mine_tiles', g.mine_tiles,
                             'multiplier', v_mult, 'payout', v_pay, 'balance', v_bal);
  end if;

  update public.mines_games set revealed = v_rev where id = g.id;
  select goog into v_bal from public.profiles where id = v_uid;
  return json_build_object('hit', false, 'done', false, 'revealed', v_rev, 'multiplier', v_mult,
                           'next_multiplier', public.mines_multiplier(g.mines, v_safe + 1), 'balance', v_bal);
end $$;

create or replace function public.mines_cashout()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); g public.mines_games%rowtype; v_safe int; v_mult numeric; v_pay bigint; v_bal bigint;
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
  return json_build_object('payout', v_pay, 'multiplier', v_mult, 'revealed', g.revealed,
                           'mine_tiles', g.mine_tiles, 'balance', v_bal);
end $$;

create or replace function public.mines_active()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); g public.mines_games%rowtype; v_safe int;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.mines_games where user_id = v_uid and status = 'active';
  if not found then return json_build_object('active', false); end if;
  v_safe := cardinality(g.revealed);
  return json_build_object('active', true, 'bet', g.bet, 'mines', g.mines, 'revealed', g.revealed,
                           'multiplier', public.mines_multiplier(g.mines, v_safe),
                           'next_multiplier', public.mines_multiplier(g.mines, v_safe + 1));
end $$;

-- ================================================================ CRASH
-- The crash point is picked when the round starts and kept secret. The multiplier is e^(rate * seconds),
-- measured by the server clock. P(crash point >= x) is about 0.99 / x.
create table if not exists public.crash_games (
  id               bigint generated always as identity primary key,
  user_id          uuid not null references auth.users(id) on delete cascade,
  bet              bigint not null,
  crash_point      numeric not null,
  auto_cashout     numeric,
  started_at       timestamptz not null,
  status           text not null default 'active' check (status in ('active', 'won', 'lost')),
  payout           bigint not null default 0,
  final_multiplier numeric
);
create unique index if not exists crash_one_active_per_user on public.crash_games (user_id) where status = 'active';
alter table public.crash_games enable row level security;
revoke all on public.crash_games from anon, authenticated;

-- Resolves the player's running round (auto cash-out, crash, or manual cash-out when p_cash is true).
create or replace function public._crash_settle(p_user uuid, p_cash boolean)
returns json language plpgsql security definer set search_path = public as $$
declare
  g public.crash_games%rowtype; v_el numeric; v_cur numeric; v_mult numeric; v_pay bigint; v_bal bigint;
begin
  select * into g from public.crash_games where user_id = p_user and status = 'active' for update;
  if not found then return null; end if;

  v_el  := extract(epoch from (clock_timestamp() - g.started_at));
  v_cur := exp(public.crash_rate() * v_el);

  if g.auto_cashout is not null and g.auto_cashout < g.crash_point and v_cur >= g.auto_cashout then
    v_mult := g.auto_cashout;                                   -- auto cash-out was reached before the crash
  elsif v_cur >= g.crash_point then
    update public.crash_games set status = 'lost', final_multiplier = g.crash_point where id = g.id;
    select goog into v_bal from public.profiles where id = p_user;
    return json_build_object('status', 'lost', 'crash_point', g.crash_point, 'bet', g.bet, 'balance', v_bal);
  elsif p_cash then
    v_mult := greatest(1.00, floor(v_cur * 100) / 100);         -- manual cash-out at the current multiplier
  else
    return json_build_object('status', 'active', 'elapsed_ms', round(v_el * 1000),
                             'rate', public.crash_rate(), 'bet', g.bet, 'auto', g.auto_cashout);
  end if;

  v_pay := floor(g.bet * v_mult);
  v_bal := public._pay(p_user, v_pay);
  update public.crash_games set status = 'won', payout = v_pay, final_multiplier = v_mult where id = g.id;
  return json_build_object('status', 'won', 'multiplier', v_mult, 'payout', v_pay,
                           'crash_point', g.crash_point, 'bet', g.bet, 'balance', v_bal);
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
                           'auto', p_auto, 'balance', v_bal);
end $$;

create or replace function public.crash_cashout()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r json;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  r := public._crash_settle(v_uid, true);
  if r is null then raise exception 'No running round'; end if;
  return r;
end $$;

create or replace function public.crash_status()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r json;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  r := public._crash_settle(v_uid, false);
  return coalesce(r, json_build_object('status', 'none'));
end $$;

-- ================================================================ PLINKO
-- Payout table for a given number of rows and risk level (8..16 rows). Edge slots pay the most.
create or replace function public.plinko_table(p_rows int, p_risk text)
returns numeric[] language plpgsql immutable set search_path = public as $$
declare
  n int := p_rows; s numeric; c numeric := 1; tot numeric := 0;
  g numeric[] := '{}'; res numeric[] := '{}'; i int; d numeric; factor numeric;
begin
  if p_rows is null or p_rows < 8 or p_rows > 16 then raise exception 'Rows must be between 8 and 16'; end if;
  s := case p_risk when 'low' then 2.0 when 'medium' then 4.0 when 'high' then 6.0 end;
  if s is null then raise exception 'Risk must be low, medium or high'; end if;
  for i in 0 .. n loop
    if i > 0 then c := c * (n - i + 1) / i; end if;                 -- binomial coefficient
    d := abs(i - n / 2.0) / (n / 2.0);
    g := array_append(g, exp(s * power(d, 2.5)));
    tot := tot + (c / power(2::numeric, n)) * g[i + 1];
  end loop;
  factor := (1 - public.house_edge()) / tot;                         -- scale so the average return is about 99%
  for i in 1 .. n + 1 loop
    res := array_append(res, round(g[i] * factor, 2));
  end loop;
  return res;
end $$;

create or replace function public.play_plinko(p_bet bigint, p_rows int, p_risk text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_tbl numeric[]; v_path int[] := '{}'; v_slot int := 0;
  i int; v_bit int; v_mult numeric; v_pay bigint; v_bal bigint;
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
  return json_build_object('path', v_path, 'slot', v_slot, 'multiplier', v_mult,
                           'payout', v_pay, 'balance', v_bal);
end $$;

-- ================================================================ permissions
-- Functions are executable by everyone by default, so lock the sensitive ones first, then open only what the site calls.
-- (house_edge, crash_rate and mines_multiplier are harmless pure calculations and stay open.)
revoke execute on function
  public.secure_random(), public._take_bet(uuid, bigint), public._pay(uuid, bigint),
  public._crash_settle(uuid, boolean),
  public.play_dice(bigint, numeric, boolean),
  public.mines_start(bigint, int), public.mines_reveal(int), public.mines_cashout(), public.mines_active(),
  public.crash_start(bigint, numeric), public.crash_cashout(), public.crash_status(),
  public.plinko_table(int, text), public.play_plinko(bigint, int, text)
from public, anon, authenticated;

grant execute on function
  public.play_dice(bigint, numeric, boolean),
  public.mines_start(bigint, int), public.mines_reveal(int), public.mines_cashout(), public.mines_active(),
  public.crash_start(bigint, numeric), public.crash_cashout(), public.crash_status(),
  public.plinko_table(int, text), public.play_plinko(bigint, int, text)
to authenticated;
