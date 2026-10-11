-- goog migration 007: upgrades for the "Tap the goog" minigame.
-- Taps earn a tiny amount of goog, with a daily limit. Upgrades (bought with goog) add time, a little more goog
-- per tap, and a slightly higher daily limit. Run once in the Supabase SQL Editor, after migration-006. Safe to run again.
--
-- Everything is checked on the server: the browser only reports how many taps it counted, and the server
-- limits that to what a human could tap in the time the round was open (tap_max_cps), and then to the daily cap.

-- ---------------------------------------------------------------------------------------------------
-- Settings (change the numbers here to tune the economy)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.tap_seconds(lvl int) returns int language sql immutable as $$ select 15 + 3 * lvl $$;          -- 15 s .. 30 s
create or replace function public.tap_milli_per_tap(lvl int) returns int language sql immutable as $$ select 5 + 3 * lvl $$;      -- 0.005 .. 0.020 goog per tap
create or replace function public.tap_daily_cap(lvl int) returns int language sql immutable as $$ select 15 + 5 * lvl $$;         -- 15 .. 35 goog per day
create or replace function public.tap_max_cps() returns int language sql immutable as $$ select 12 $$;                           -- taps per second a human can reach
create or replace function public.tap_max_level(kind text) returns int language sql immutable as $$
  select case kind when 'time' then 5 when 'value' then 5 when 'cap' then 4 else 0 end $$;
-- price of the NEXT level (lvl = the level you have now)
create or replace function public.tap_upgrade_cost(kind text, lvl int) returns bigint language sql immutable as $$
  select case kind
    when 'time'  then (array[50, 100, 200, 400, 800])[lvl + 1]
    when 'value' then (array[100, 200, 400, 800, 1600])[lvl + 1]
    when 'cap'   then (array[75, 150, 300, 600])[lvl + 1]
  end::bigint $$;

-- ---------------------------------------------------------------------------------------------------
-- Per-player state (no direct access from the browser)
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.tap_stats (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  lvl_time       smallint not null default 0 check (lvl_time between 0 and 5),
  lvl_value      smallint not null default 0 check (lvl_value between 0 and 5),
  lvl_cap        smallint not null default 0 check (lvl_cap between 0 and 4),
  carry_milli    int not null default 0,            -- thousandths of a goog that have not added up to 1 goog yet
  earned_day     date,
  earned_today   int not null default 0,
  round_started  timestamptz,
  round_seconds  int,
  best_taps      int not null default 0,
  total_taps     bigint not null default 0
);
alter table public.tap_stats enable row level security;
revoke all on public.tap_stats from anon, authenticated;

create or replace function public._tap_row(p_user uuid) returns public.tap_stats
language plpgsql security definer set search_path = public as $$
declare r public.tap_stats;
begin
  insert into public.tap_stats(user_id) values (p_user) on conflict (user_id) do nothing;
  select * into r from public.tap_stats where user_id = p_user for update;
  if r.earned_day is distinct from public._berlin_today() then
    update public.tap_stats set earned_day = public._berlin_today(), earned_today = 0 where user_id = p_user returning * into r;
  end if;
  return r;
end $$;

create or replace function public._tap_view(r public.tap_stats, p_balance bigint) returns json
language sql stable as $$
  select json_build_object(
    'levels', json_build_object('time', r.lvl_time, 'value', r.lvl_value, 'cap', r.lvl_cap),
    'seconds', public.tap_seconds(r.lvl_time),
    'milli_per_tap', public.tap_milli_per_tap(r.lvl_value),
    'daily_cap', public.tap_daily_cap(r.lvl_cap),
    'earned_today', r.earned_today,
    'carry_milli', r.carry_milli,
    'best_taps', r.best_taps,
    'balance', p_balance,
    'upgrades', json_build_object(
      'time',  json_build_object('level', r.lvl_time,  'max', public.tap_max_level('time'),  'cost', case when r.lvl_time  < 5 then public.tap_upgrade_cost('time',  r.lvl_time)  end, 'now', public.tap_seconds(r.lvl_time),       'next', case when r.lvl_time  < 5 then public.tap_seconds(r.lvl_time + 1) end),
      'value', json_build_object('level', r.lvl_value, 'max', public.tap_max_level('value'), 'cost', case when r.lvl_value < 5 then public.tap_upgrade_cost('value', r.lvl_value) end, 'now', public.tap_milli_per_tap(r.lvl_value), 'next', case when r.lvl_value < 5 then public.tap_milli_per_tap(r.lvl_value + 1) end),
      'cap',   json_build_object('level', r.lvl_cap,   'max', public.tap_max_level('cap'),   'cost', case when r.lvl_cap   < 4 then public.tap_upgrade_cost('cap',   r.lvl_cap)   end, 'now', public.tap_daily_cap(r.lvl_cap),     'next', case when r.lvl_cap   < 4 then public.tap_daily_cap(r.lvl_cap + 1) end)
    )
  ) $$;

-- ---------------------------------------------------------------------------------------------------
-- What the site calls
-- ---------------------------------------------------------------------------------------------------
create or replace function public.tap_info() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r public.tap_stats; v_bal bigint;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  r := public._tap_row(v_uid);
  select goog into v_bal from public.profiles where id = v_uid;
  return public._tap_view(r, v_bal);
end $$;

create or replace function public.tap_start() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r public.tap_stats; v_banned boolean;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select banned into v_banned from public.profiles where id = v_uid;
  if v_banned then raise exception 'This account is banned from playing'; end if;
  r := public._tap_row(v_uid);
  update public.tap_stats set round_started = now(), round_seconds = public.tap_seconds(r.lvl_time) where user_id = v_uid;
  return json_build_object('seconds', public.tap_seconds(r.lvl_time));
end $$;

create or replace function public.tap_finish(p_taps int) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); r public.tap_stats; v_bal bigint;
  v_elapsed numeric; v_allowed int; v_taps int; v_milli bigint; v_whole int; v_room int; v_paid int; v_capped boolean := false;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  r := public._tap_row(v_uid);
  if r.round_started is null then raise exception 'Start a round first'; end if;
  v_elapsed := extract(epoch from (now() - r.round_started));
  -- a human cannot tap faster than tap_max_cps(), and the round only lasts round_seconds (plus a little network slack)
  v_allowed := ceil(least(v_elapsed, r.round_seconds + 3) * public.tap_max_cps());
  v_taps := greatest(0, least(coalesce(p_taps, 0), v_allowed));

  v_milli := r.carry_milli + v_taps::bigint * public.tap_milli_per_tap(r.lvl_value);
  v_whole := (v_milli / 1000)::int;
  v_room  := greatest(0, public.tap_daily_cap(r.lvl_cap) - r.earned_today);
  v_paid  := least(v_whole, v_room);
  if v_whole > v_room then v_capped := true; end if;

  update public.tap_stats set
    round_started = null, round_seconds = null,
    carry_milli = case when v_capped then 0 else (v_milli % 1000)::int end,
    earned_today = earned_today + v_paid,
    best_taps = greatest(best_taps, v_taps),
    total_taps = total_taps + v_taps
  where user_id = v_uid returning * into r;

  if v_paid > 0 then v_bal := public._pay(v_uid, v_paid);
  else select goog into v_bal from public.profiles where id = v_uid; end if;
  return json_build_object('taps', v_taps, 'paid', v_paid, 'capped', v_capped, 'balance', v_bal, 'info', public._tap_view(r, v_bal));
end $$;

create or replace function public.tap_buy(p_kind text) returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r public.tap_stats; v_lvl int; v_cost bigint; v_bal bigint;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_kind not in ('time', 'value', 'cap') then raise exception 'Unknown upgrade'; end if;
  r := public._tap_row(v_uid);
  v_lvl := case p_kind when 'time' then r.lvl_time when 'value' then r.lvl_value else r.lvl_cap end;
  if v_lvl >= public.tap_max_level(p_kind) then raise exception 'Already at the highest level'; end if;
  v_cost := public.tap_upgrade_cost(p_kind, v_lvl);
  v_bal := public._take_bet(v_uid, v_cost);                                   -- also stops banned accounts and checks the balance
  update public.tap_stats set
    lvl_time  = lvl_time  + (p_kind = 'time')::int,
    lvl_value = lvl_value + (p_kind = 'value')::int,
    lvl_cap   = lvl_cap   + (p_kind = 'cap')::int
  where user_id = v_uid returning * into r;
  return json_build_object('balance', v_bal, 'info', public._tap_view(r, v_bal));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- permissions: logged-in players only
-- ---------------------------------------------------------------------------------------------------
revoke execute on function
  public._tap_row(uuid), public._tap_view(public.tap_stats, bigint),
  public.tap_info(), public.tap_start(), public.tap_finish(int), public.tap_buy(text)
from public, anon, authenticated;

grant execute on function
  public.tap_info(), public.tap_start(), public.tap_finish(int), public.tap_buy(text)
to authenticated;
