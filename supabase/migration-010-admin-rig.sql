-- goog migration 010: admin rigging. An admin can queue forced outcomes for any player and game.
-- Run once in the Supabase SQL Editor, after migration-008. Safe to run again.
--
-- * Rules live in rig_rules (no browser access). Each rule applies to the next N rounds of one game of one player.
-- * The games ask _rig_take() at the point where they roll their randomness; without a rule nothing changes.
-- * Rigged rounds are marked (meta.rigged) and left out of the admin return-vs-target table, so that stays honest.
-- * Every rule that is set or cancelled is written to the admin log.
--
-- Presets: dice win|lose, crash point (x multiplier), roulette number (0-36), plinko slot (0 = far left),
--          slots lose|win|big|free, mines safe|bomb, tower safe|bomb, scratch lose|win|jackpot.
-- Mines and tower rules are used up per box or tile opened, so set the number of uses to match the round.

alter table public.mines_games add column if not exists rigged boolean not null default false;
alter table public.tower_games add column if not exists rigged boolean not null default false;
alter table public.crash_games add column if not exists rigged boolean not null default false;

create table if not exists public.rig_rules (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  game        text not null check (game in ('dice', 'crash', 'roulette', 'plinko', 'slots', 'mines', 'tower', 'scratch')),
  preset      text not null,
  param       numeric,
  uses_left   int not null check (uses_left >= 0),
  uses_total  int not null,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  last_used   timestamptz
);
alter table public.rig_rules enable row level security;
revoke all on public.rig_rules from anon, authenticated;
create index if not exists rig_rules_lookup on public.rig_rules (user_id, game) where uses_left > 0;

-- takes one use of the oldest active rule for this player and game
create or replace function public._rig_take(p_user uuid, p_game text, out o_preset text, out o_param numeric)
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  select id into v_id from public.rig_rules where user_id = p_user and game = p_game and uses_left > 0
    order by created_at, id limit 1 for update skip locked;
  if v_id is not null then
    update public.rig_rules set uses_left = uses_left - 1, last_used = now() where id = v_id returning preset, param into o_preset, o_param;
  end if;
end $$;

create or replace function public._rig_meta(p_preset text) returns jsonb
language sql immutable as $$ select case when p_preset is null then '{}'::jsonb else jsonb_build_object('rigged', true) end $$;

-- the play log marks rigged rounds
create or replace function public._record_play(p_user uuid, p_game text, p_bet bigint, p_payout bigint, p_meta jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_mult numeric; v_ev jsonb; v_rigged boolean := coalesce((p_meta ->> 'rigged')::boolean, false);
begin
  v_mult := round(p_payout::numeric / p_bet, 4);
  -- multi-step games remember on the round itself that an admin rig was used
  if not v_rigged then
    v_rigged := case p_game
      when 'mines' then coalesce((select rigged from public.mines_games where user_id = p_user order by id desc limit 1), false)
      when 'tower' then coalesce((select rigged from public.tower_games where user_id = p_user order by id desc limit 1), false)
      when 'crash' then coalesce((select rigged from public.crash_games where user_id = p_user order by id desc limit 1), false)
      else false end;
  end if;
  insert into public.game_plays (user_id, game, bet, payout, multiplier, meta)
    values (p_user, p_game, p_bet, p_payout, v_mult, coalesce(p_meta, '{}'::jsonb) || case when v_rigged then jsonb_build_object('rigged', true) else '{}'::jsonb end);
  insert into public.player_games (user_id, game) values (p_user, p_game) on conflict do nothing;
  v_ev := public._check_achievements(p_user, p_game, p_bet, p_payout, v_mult, coalesce(p_meta, '{}'::jsonb))
       || public._check_challenges(p_user, p_game, p_bet, p_payout, v_mult);
  return v_ev;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- The game functions with the rig hooks (everything else in them is unchanged from migration 008)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.play_dice(p_bet bigint, p_target numeric, p_over boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric; v_n int;
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
  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'dice');
  if v_rp is not null then
    if p_over then
      -- over: a roll above the target wins, one at or below it loses
      v_n := case when v_rp = 'win' then round((99.99 - v_target) * 100)::int else round(v_target * 100)::int + 1 end;
      v_roll := case when v_rp = 'win' then v_target + 0.01 * (1 + floor(public.secure_random() * v_n))
                     else floor(public.secure_random() * v_n)::numeric / 100 end;
    else
      -- under: a roll below the target wins, one at or above it loses
      v_n := case when v_rp = 'win' then round(v_target * 100)::int else round((99.99 - v_target) * 100)::int + 1 end;
      v_roll := case when v_rp = 'win' then floor(public.secure_random() * v_n)::numeric / 100
                     else v_target + 0.01 * floor(public.secure_random() * v_n) end;
    end if;
  end if;
  v_win  := case when p_over then v_roll > v_target else v_roll < v_target end;
  if v_win then
    v_pay := floor(p_bet * v_mult);
    v_bal := public._pay(v_uid, v_pay);
  end if;
  v_ev  := public._record_play(v_uid, 'dice', p_bet, v_pay, jsonb_build_object('target', v_target, 'over', p_over, 'chance', v_chance) || public._rig_meta(v_rp));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('roll', v_roll, 'win', v_win, 'multiplier', v_mult, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.crash_start(p_bet bigint, p_auto numeric default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric; v_uid uuid := auth.uid(); v_prev json; v_bal bigint; v_cp numeric; v_r double precision;
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
  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'crash');
  if v_rp = 'point' then v_cp := least(1000::numeric, greatest(1.00::numeric, round(v_rpar, 2))); end if;
  insert into public.crash_games (user_id, bet, crash_point, auto_cashout, started_at, rigged)
  values (v_uid, p_bet, v_cp, p_auto, clock_timestamp(), v_rp is not null);
  return json_build_object('rate', public.crash_rate(), 'elapsed_ms', 0, 'bet', p_bet,
                           'auto', p_auto, 'balance', v_bal,
                           'events', coalesce(v_prev -> 'events', '[]'::json));
end $$;

create or replace function public.play_plinko(p_bet bigint, p_rows int, p_risk text)
returns json language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric;
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
  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'plinko');
  if v_rp = 'slot' then
    v_slot := least(greatest(round(v_rpar)::int, 0), p_rows);
    select array_agg(case when rn <= v_slot then 1 else 0 end order by public.secure_random()) into v_path from generate_series(1, p_rows) rn;
  end if;
  v_mult := v_tbl[v_slot + 1];
  v_pay  := floor(p_bet * v_mult);
  if v_pay > 0 then v_bal := public._pay(v_uid, v_pay); end if;
  v_ev  := public._record_play(v_uid, 'plinko', p_bet, v_pay, jsonb_build_object('rows', p_rows, 'risk', p_risk, 'slot', v_slot) || public._rig_meta(v_rp));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('path', v_path, 'slot', v_slot, 'multiplier', v_mult,
                           'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.play_slots(p_per_line bigint, p_lines int, p_risk text)
returns json language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric; v_try int;
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
  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'slots');
  if v_rp is not null then                                          -- spin again until the spin looks the way you asked for (bounded)
    for v_try in 1 .. 1500 loop
      exit when case v_rp
        when 'lose' then (v_base ->> 'line_mult')::numeric = 0 and (v_base ->> 'scatters')::int < 3
        when 'win'  then (v_base ->> 'line_mult')::numeric > 0 and (v_base ->> 'scatters')::int < 3
        when 'big'  then (v_base ->> 'line_mult')::numeric >= 5 * p_lines
        when 'free' then (v_base ->> 'scatters')::int >= 3
        else true end;
      v_base := public._slots_spin(p_lines, p_risk);
    end loop;
  end if;
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

  v_ev  := public._record_play(v_uid, 'slots', v_total, v_pay, jsonb_build_object('lines', p_lines, 'risk', p_risk, 'scatters', v_scat, 'free_spins', v_nfree) || public._rig_meta(v_rp));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object(
    'grid', v_base -> 'grid', 'wins', v_base -> 'wins', 'base_win', round(v_base_win, 2),
    'scatters', v_scat, 'scatter_win', v_scat_win,
    'free_spins', v_nfree, 'free', v_free, 'free_win', round(v_free_win, 2),
    'total_bet', v_total, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.mines_reveal(p_tile int)
returns json language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric; v_alt int;
  v_uid uuid := auth.uid(); g public.mines_games%rowtype;
  v_rev smallint[]; v_safe int; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.mines_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active round'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Invalid box'; end if;
  if p_tile::smallint = any (g.revealed) then raise exception 'Box already opened'; end if;
  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'mines');
  if v_rp is not null then
    if v_rp = 'safe' and p_tile::smallint = any (g.mine_tiles) then
      select t into v_alt from generate_series(0, 24) t
        where t <> p_tile and t::smallint <> all (g.revealed) and t::smallint <> all (g.mine_tiles) order by public.secure_random() limit 1;
      if v_alt is not null then g.mine_tiles := array_replace(g.mine_tiles, p_tile::smallint, v_alt::smallint); end if;
    elsif v_rp = 'bomb' and p_tile::smallint <> all (g.mine_tiles) then
      g.mine_tiles := array_replace(g.mine_tiles, g.mine_tiles[1], p_tile::smallint);
    end if;
    update public.mines_games set mine_tiles = g.mine_tiles, rigged = true where id = g.id;
  end if;

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

create or replace function public.tower_pick(p_tile int) returns json
language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric; v_mask int; v_alt int;
  v_uid uuid := auth.uid(); g public.tower_games%rowtype; v_level int; v_mult numeric; v_pay bigint; v_bal bigint; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.tower_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active climb'; end if;
  if p_tile is null or p_tile < 0 or p_tile >= g.tiles then raise exception 'Invalid tile'; end if;
  v_level := coalesce(array_length(g.picks, 1), 0);                 -- floors cleared so far (0-based index of this floor)

  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'tower');
  if v_rp is not null then
    v_mask := g.trap_masks[v_level + 1];
    if v_rp = 'safe' and (v_mask & (1 << p_tile)) <> 0 then
      select x into v_alt from generate_series(0, g.tiles - 1) x where (v_mask & (1 << x)) = 0 order by public.secure_random() limit 1;
      if v_alt is not null then v_mask := (v_mask & ~(1 << p_tile)) | (1 << v_alt); end if;
    elsif v_rp = 'bomb' and (v_mask & (1 << p_tile)) = 0 then
      v_mask := (v_mask | (1 << p_tile)) & ~(v_mask & -v_mask);
    end if;
    g.trap_masks[v_level + 1] := v_mask;
    update public.tower_games set trap_masks = g.trap_masks, rigged = true where id = g.id;
  end if;

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

create or replace function public.play_roulette(p_bets jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric;
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
  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'roulette');
  if v_rp = 'number' then v_n := least(36, greatest(0, round(v_rpar)::int)); end if;

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
  v_ev  := public._record_play(v_uid, 'roulette', v_total, v_pay, jsonb_build_object('number', v_n, 'straight_hit', exists (select 1 from jsonb_array_elements(v_res) e where e ->> 'type' = 'straight' and (e ->> 'win')::boolean)) || public._rig_meta(v_rp));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('number', v_n,
    'color', case when v_n = 0 then 'green' when public._roulette_red(v_n) then 'red' else 'black' end,
    'results', v_res, 'total_bet', v_total, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

create or replace function public.play_scratch(p_price bigint) returns json
language plpgsql security definer set search_path = public as $$
declare v_rp text; v_rpar numeric;
  v_uid uuid := auth.uid(); v_bal bigint; pr int[] := public._scratch_prizes(); r int; acc int := 0; i int;
  v_sym int := null; v_mult int := 0; v_cells int[]; v_pool int[]; v_pay bigint := 0; v_ev jsonb;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  if p_price is null or p_price not in (1, 5, 25, 100) then raise exception 'Cards cost 1, 5, 25 or 100 goog'; end if;
  v_bal := public._take_bet(v_uid, p_price);

  r := floor(public.secure_random() * 1000000)::int;
  select o_preset, o_param into v_rp, v_rpar from public._rig_take(v_uid, 'scratch');
  if v_rp = 'jackpot' then r := 223500;                              -- the 500x tier
  elsif v_rp = 'win' then r := floor(public.secure_random() * 223890)::int;      -- any winning tier
  elsif v_rp = 'lose' then r := 999999; end if;
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
  v_ev  := public._record_play(v_uid, 'scratch', p_price, v_pay, jsonb_build_object('symbol', v_sym) || public._rig_meta(v_rp));
  v_bal := v_bal + public._ev_reward(v_ev);
  return json_build_object('cells', v_cells, 'win_symbol', v_sym, 'multiplier', v_mult,
                           'price', p_price, 'payout', v_pay, 'balance', v_bal, 'events', v_ev);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- Admin: the honest return table ignores rigged rounds
-- ---------------------------------------------------------------------------------------------------
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
      where (p_days is null or created_at >= now() - make_interval(days => p_days))
        and not coalesce((meta ->> 'rigged')::boolean, false)
      group by game) r), '[]'::json);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- Admin: set, list and cancel rules
-- ---------------------------------------------------------------------------------------------------
create or replace function public.admin_rig_set(p_user uuid, p_game text, p_preset text, p_param numeric default null, p_uses int default 1)
returns json language plpgsql security definer set search_path = public as $$
declare v_ok boolean; v_name text; v_id bigint; v_param numeric := p_param;
begin
  perform public._require_admin();
  select username into v_name from public.profiles where id = p_user;
  if v_name is null then raise exception 'Player not found'; end if;
  if p_uses is null or p_uses < 1 or p_uses > 1000 then raise exception 'Uses must be 1 to 1000'; end if;
  v_ok := (p_game, p_preset) in (
    ('dice', 'win'), ('dice', 'lose'), ('crash', 'point'), ('roulette', 'number'), ('plinko', 'slot'),
    ('slots', 'lose'), ('slots', 'win'), ('slots', 'big'), ('slots', 'free'),
    ('mines', 'safe'), ('mines', 'bomb'), ('tower', 'safe'), ('tower', 'bomb'),
    ('scratch', 'lose'), ('scratch', 'win'), ('scratch', 'jackpot'));
  if not v_ok then raise exception 'Unknown game or preset'; end if;
  if p_preset = 'point' then
    if v_param is null or v_param < 1 or v_param > 1000 then raise exception 'Crash point must be 1.00 to 1000'; end if;
    v_param := round(v_param, 2);
  elsif p_preset = 'number' then
    if v_param is null or v_param < 0 or v_param > 36 then raise exception 'Roulette number must be 0 to 36'; end if;
    v_param := round(v_param);
  elsif p_preset = 'slot' then
    if v_param is null or v_param < 0 or v_param > 16 then raise exception 'Plinko slot must be 0 to 16'; end if;
    v_param := round(v_param);
  else v_param := null; end if;
  insert into public.rig_rules (user_id, game, preset, param, uses_left, uses_total, created_by)
    values (p_user, p_game, p_preset, v_param, p_uses, p_uses, auth.uid()) returning id into v_id;
  insert into public.admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), p_user, 'rig_set', p_game || ' ' || p_preset || coalesce(' ' || v_param::text, '') || ' x' || p_uses);
  return json_build_object('id', v_id, 'username', v_name);
end $$;

create or replace function public.admin_rig_list(p_limit int default 60) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select json_agg(row_to_json(t)) from (
    select r.id, p.username, r.user_id, r.game, r.preset, r.param, r.uses_left, r.uses_total, r.created_at, r.last_used
    from public.rig_rules r join public.profiles p on p.id = r.user_id
    order by (r.uses_left > 0) desc, r.created_at desc, r.id desc
    limit least(greatest(coalesce(p_limit, 60), 1), 200)) t), '[]'::json);
end $$;

-- cancels one rule (p_id) or every active rule of a player (p_user)
create or replace function public.admin_rig_clear(p_id bigint default null, p_user uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_n int; v_target uuid;
begin
  perform public._require_admin();
  if p_id is null and p_user is null then raise exception 'Nothing to cancel'; end if;
  if p_id is not null then
    update public.rig_rules set uses_left = 0 where id = p_id and uses_left > 0 returning user_id into v_target;
    get diagnostics v_n = row_count;
  else
    update public.rig_rules set uses_left = 0 where user_id = p_user and uses_left > 0;
    get diagnostics v_n = row_count; v_target := p_user;
  end if;
  if v_n > 0 then
    insert into public.admin_actions (admin_id, target_id, action, detail) values (auth.uid(), v_target, 'rig_cancel', v_n || ' rule(s)');
  end if;
  return json_build_object('cancelled', v_n);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- permissions
-- ---------------------------------------------------------------------------------------------------
revoke execute on function public._rig_take(uuid, text), public._rig_meta(text) from public, anon, authenticated;
revoke execute on function public.admin_rig_set(uuid, text, text, numeric, int), public.admin_rig_list(int), public.admin_rig_clear(bigint, uuid) from public, anon;
grant execute on function public.admin_rig_set(uuid, text, text, numeric, int), public.admin_rig_list(int), public.admin_rig_clear(bigint, uuid) to authenticated;
