-- goog migration 009: Tap the goog leaderboard, "fair" runs without upgrades, and time back for every tap.
-- Run once in the Supabase SQL Editor, after migration-007. Safe to run again.
--
-- * A run is either "fair" (15 s, base goog per tap, upgrades ignored) or "up" (your upgrades count).
-- * Every tap gives 0.1 s back on the client. The server only has to limit the taps, so it allows
--   round length + tap_bonus_cap_s() + 3 s of tapping at tap_max_cps().
-- * The best run of each player is kept per mode and shown on a leaderboard.

create or replace function public.tap_bonus_cap_s() returns int language sql immutable as $$ select 30 $$;   -- the most seconds taps can add to one run

alter table public.tap_stats add column if not exists round_mode text not null default 'up' check (round_mode in ('fair', 'up'));

create table if not exists public.tap_scores (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  mode       text not null check (mode in ('fair', 'up')),
  best_taps  int not null default 0,
  achieved_at timestamptz not null default now(),
  primary key (user_id, mode)
);
alter table public.tap_scores enable row level security;
revoke all on public.tap_scores from anon, authenticated;
create index if not exists tap_scores_rank on public.tap_scores (mode, best_taps desc, achieved_at);

-- the view now also tells the site the bonus rules and the player's best runs
create or replace function public._tap_view(r public.tap_stats, p_balance bigint) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'levels', json_build_object('time', r.lvl_time, 'value', r.lvl_value),
    'seconds', public.tap_seconds(r.lvl_time),
    'fair_seconds', public.tap_seconds(0),
    'milli_per_tap', public.tap_milli_per_tap(r.lvl_value),
    'bonus_ms', 100,
    'bonus_cap_s', public.tap_bonus_cap_s(),
    'best', json_build_object(
      'fair', coalesce((select best_taps from public.tap_scores where user_id = r.user_id and mode = 'fair'), 0),
      'up',   coalesce((select best_taps from public.tap_scores where user_id = r.user_id and mode = 'up'), 0)),
    'earned_today', r.earned_today,
    'carry_milli', r.carry_milli,
    'best_taps', r.best_taps,
    'balance', p_balance,
    'upgrades', json_build_object(
      'time',  json_build_object('level', r.lvl_time,  'max', public.tap_max_level('time'),  'cost', case when r.lvl_time  < 5 then public.tap_upgrade_cost('time',  r.lvl_time)  end, 'now', public.tap_seconds(r.lvl_time),       'next', case when r.lvl_time  < 5 then public.tap_seconds(r.lvl_time + 1) end),
      'value', json_build_object('level', r.lvl_value, 'max', public.tap_max_level('value'), 'cost', case when r.lvl_value < 5 then public.tap_upgrade_cost('value', r.lvl_value) end, 'now', public.tap_milli_per_tap(r.lvl_value), 'next', case when r.lvl_value < 5 then public.tap_milli_per_tap(r.lvl_value + 1) end)
    )
  ) $$;

drop function if exists public.tap_start();
create or replace function public.tap_start(p_mode text default 'up') returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r public.tap_stats; v_banned boolean; v_mode text := coalesce(p_mode, 'up'); v_secs int;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if v_mode not in ('fair', 'up') then raise exception 'Unknown mode'; end if;
  select banned into v_banned from public.profiles where id = v_uid;
  if v_banned then raise exception 'This account is banned from playing'; end if;
  r := public._tap_row(v_uid);
  v_secs := case v_mode when 'fair' then public.tap_seconds(0) else public.tap_seconds(r.lvl_time) end;
  update public.tap_stats set round_started = now(), round_seconds = v_secs, round_mode = v_mode where user_id = v_uid;
  return json_build_object('seconds', v_secs, 'mode', v_mode, 'bonus_ms', 100, 'bonus_cap_s', public.tap_bonus_cap_s());
end $$;

create or replace function public.tap_finish(p_taps int) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); r public.tap_stats; v_bal bigint;
  v_elapsed numeric; v_allowed int; v_taps int; v_milli bigint; v_paid int; v_rate int; v_mode text; v_best int; v_new boolean := false;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  r := public._tap_row(v_uid);
  if r.round_started is null then raise exception 'Start a round first'; end if;
  v_mode := r.round_mode;
  v_elapsed := extract(epoch from (now() - r.round_started));
  -- nobody taps faster than tap_max_cps(), and a run lasts at most the round length plus the capped time bonus (plus network slack)
  v_allowed := ceil(least(v_elapsed, r.round_seconds + public.tap_bonus_cap_s() + 3) * public.tap_max_cps());
  v_taps := greatest(0, least(coalesce(p_taps, 0), v_allowed));

  v_rate  := case v_mode when 'fair' then public.tap_milli_per_tap(0) else public.tap_milli_per_tap(r.lvl_value) end;
  v_milli := r.carry_milli + v_taps::bigint * v_rate;
  v_paid  := (v_milli / 1000)::int;

  update public.tap_stats set
    round_started = null, round_seconds = null,
    carry_milli = (v_milli % 1000)::int,
    earned_today = earned_today + v_paid,
    best_taps = greatest(best_taps, v_taps),
    total_taps = total_taps + v_taps
  where user_id = v_uid returning * into r;

  select best_taps into v_best from public.tap_scores where user_id = v_uid and mode = v_mode;
  if v_taps > 0 and (v_best is null or v_taps > v_best) then
    insert into public.tap_scores(user_id, mode, best_taps, achieved_at) values (v_uid, v_mode, v_taps, now())
    on conflict (user_id, mode) do update set best_taps = excluded.best_taps, achieved_at = excluded.achieved_at;
    v_new := true;
  end if;

  if v_paid > 0 then v_bal := public._pay(v_uid, v_paid);
  else select goog into v_bal from public.profiles where id = v_uid; end if;
  return json_build_object('taps', v_taps, 'paid', v_paid, 'mode', v_mode, 'new_best', v_new, 'balance', v_bal, 'info', public._tap_view(r, v_bal));
end $$;

-- top 20 of a mode, plus the caller's own rank
create or replace function public.tap_board(p_mode text default 'fair') returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_mode text := coalesce(p_mode, 'fair'); v_rank int; v_best int;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if v_mode not in ('fair', 'up') then raise exception 'Unknown mode'; end if;
  select best_taps into v_best from public.tap_scores where user_id = v_uid and mode = v_mode;
  if v_best is not null then
    select 1 + count(*) into v_rank from public.tap_scores s
    where s.mode = v_mode and (s.best_taps > v_best or (s.best_taps = v_best and s.achieved_at < (select achieved_at from public.tap_scores where user_id = v_uid and mode = v_mode)));
  end if;
  return json_build_object('mode', v_mode, 'my_best', v_best, 'my_rank', v_rank, 'rows', coalesce((
    select json_agg(json_build_object('id', id, 'username', username, 'avatar_version', avatar_version, 'taps', best_taps) order by best_taps desc, achieved_at)
    from (select p.id, p.username, p.avatar_version, s.best_taps, s.achieved_at
          from public.tap_scores s join public.profiles p on p.id = s.user_id
          where s.mode = v_mode and not coalesce(p.banned, false)
          order by s.best_taps desc, s.achieved_at limit 20) r), '[]'::json));
end $$;

revoke execute on function
  public._tap_view(public.tap_stats, bigint), public.tap_start(text), public.tap_finish(int), public.tap_board(text)
from public, anon, authenticated;
grant execute on function
  public.tap_start(text), public.tap_finish(int), public.tap_board(text)
to authenticated;
