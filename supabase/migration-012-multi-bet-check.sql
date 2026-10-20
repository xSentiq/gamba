-- goog migration 012: Cat Drop (plinko) and scratch cards in bulk now need the whole stake up front.
-- Run once in the Supabase SQL Editor. Safe to run again.
--
-- Bug: the bulk functions played the rounds one after another and paid each win straight away, so a player with 20 goog
-- could start 20 drops of 10 goog as long as the balance never dipped below 10 on the way. A run that went broke halfway
-- failed and was rolled back (no loss), so only the lucky runs ever counted: a free option on the whole stake.
-- Fix: the full total (bet x rounds) must be in the balance before anything is played, as the comment always promised.

create or replace function public.play_plinko_multi(p_bet bigint, p_rows int, p_risk text, p_count int) returns json
language plpgsql security definer set search_path = public as $$
declare i int; r json; out json[] := '{}'; v_bal bigint;
begin
  if auth.uid() is null then raise exception 'Log in first'; end if;
  if p_count is null or p_count < 1 or p_count > 20 then raise exception 'Drop between 1 and 20 cats'; end if;
  if p_bet is null or p_bet < 1 then raise exception 'Bet at least 1 goog'; end if;
  select goog into v_bal from public.profiles where id = auth.uid() for update;
  if v_bal is null or p_bet * p_count > v_bal then raise exception 'Not enough goog'; end if;
  for i in 1 .. p_count loop
    r := public.play_plinko(p_bet, p_rows, p_risk);
    out := array_append(out, r);
  end loop;
  return json_build_object('drops', to_json(out), 'balance', (r->>'balance')::bigint);
end $$;

create or replace function public.play_scratch_multi(p_price bigint, p_count int) returns json
language plpgsql security definer set search_path = public as $$
declare i int; r json; out json[] := '{}'; v_bal bigint;
begin
  if auth.uid() is null then raise exception 'Log in first'; end if;
  if p_count is null or p_count < 1 or p_count > 10 then raise exception 'Buy between 1 and 10 cards'; end if;
  if p_price is null or p_price < 1 then raise exception 'Pick a card price'; end if;
  select goog into v_bal from public.profiles where id = auth.uid() for update;
  if v_bal is null or p_price * p_count > v_bal then raise exception 'Not enough goog'; end if;
  for i in 1 .. p_count loop
    r := public.play_scratch(p_price);
    out := array_append(out, r);
  end loop;
  return json_build_object('cards', to_json(out), 'balance', (r->>'balance')::bigint);
end $$;

revoke execute on function public.play_plinko_multi(bigint, int, text, int), public.play_scratch_multi(bigint, int) from public, anon;
grant execute on function public.play_plinko_multi(bigint, int, text, int), public.play_scratch_multi(bigint, int) to authenticated;
