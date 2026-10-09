-- goog migration 006: multi-drop Plinko, buying several scratch cards at once, and the background-color gamble.
-- Run once in the Supabase SQL Editor, after migration-005. Safe to run again.

-- ---------------------------------------------------------------------------------------------------
-- Background color: one hue (0 to 359) per account, null = the default look.
-- ---------------------------------------------------------------------------------------------------
alter table public.profiles add column if not exists bg_hue smallint check (bg_hue between 0 and 359);
grant select (bg_hue) on public.profiles to anon, authenticated;

create or replace function public.bg_color_price() returns bigint language sql immutable as $$ select 1::bigint $$;

-- Pay 1 goog, get a random color (a different one is possible every time; the new one replaces the old one).
create or replace function public.gamble_bg_color() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_bal bigint; v_hue int;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  v_bal := public._take_bet(v_uid, public.bg_color_price());
  v_hue := floor(public.secure_random() * 360)::int;
  update public.profiles set bg_hue = v_hue where id = v_uid;
  return json_build_object('hue', v_hue, 'balance', v_bal, 'price', public.bg_color_price());
end $$;

-- Back to the default look (free).
create or replace function public.reset_bg_color() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  update public.profiles set bg_hue = null where id = v_uid;
  return json_build_object('hue', null);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- Several rounds in one request (one network round trip instead of many). All or nothing: if you cannot
-- afford every round, nothing is played and nothing is charged.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.play_plinko_multi(p_bet bigint, p_rows int, p_risk text, p_count int) returns json
language plpgsql security definer set search_path = public as $$
declare i int; r json; out json[] := '{}';
begin
  if auth.uid() is null then raise exception 'Log in first'; end if;
  if p_count is null or p_count < 1 or p_count > 20 then raise exception 'Drop between 1 and 20 cats'; end if;
  for i in 1 .. p_count loop
    r := public.play_plinko(p_bet, p_rows, p_risk);
    out := array_append(out, r);
  end loop;
  return json_build_object('drops', to_json(out), 'balance', (r->>'balance')::bigint);
end $$;

create or replace function public.play_scratch_multi(p_price bigint, p_count int) returns json
language plpgsql security definer set search_path = public as $$
declare i int; r json; out json[] := '{}';
begin
  if auth.uid() is null then raise exception 'Log in first'; end if;
  if p_count is null or p_count < 1 or p_count > 10 then raise exception 'Buy between 1 and 10 cards'; end if;
  for i in 1 .. p_count loop
    r := public.play_scratch(p_price);
    out := array_append(out, r);
  end loop;
  return json_build_object('cards', to_json(out), 'balance', (r->>'balance')::bigint);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- permissions: logged-in players only
-- ---------------------------------------------------------------------------------------------------
revoke execute on function
  public.gamble_bg_color(), public.reset_bg_color(),
  public.play_plinko_multi(bigint, int, text, int), public.play_scratch_multi(bigint, int)
from public, anon, authenticated;

grant execute on function
  public.gamble_bg_color(), public.reset_bg_color(),
  public.play_plinko_multi(bigint, int, text, int), public.play_scratch_multi(bigint, int)
to authenticated;
