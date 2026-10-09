-- More games: Cat Slots (with free games), Cat Tower, Cat Roulette, Scratch Cards.
-- Run in Supabase -> SQL Editor AFTER migration-004-economy.sql. Safe to re-run.
--
-- Like the earlier games, every round is decided here in the database. The browser only asks to play.
-- Returns to player: Slots 99% (exact, all three risk levels), Tower 99%, Scratch cards 99%,
-- Roulette 97.3% (standard single-zero payouts, which is the real game's edge).

-- =====================================================================================================
-- CAT SLOTS: 5 reels x 3 rows, up to 20 paylines, pays left to right from reel 1, 3+ of a kind.
-- Symbols: 1..6 = slotcat_1..slotcat_6 (1 pays the most), 7 = wild (the goog cat), 8 = scatter (the drooling cat).
-- 3 / 4 / 5+ drooling cats anywhere start 8 / 12 / 20 free games with all wins doubled and also pay 1x / 5x / 25x
-- of the total bet. Free games cannot be retriggered and the scatter pays nothing during them.
-- Every cell is drawn independently with the weights below, so the return is exactly computable. The paytables were
-- scaled so that line wins + scatter pays + free games return 99.0% of the bet (checked by simulation, see README).
-- Risk changes how the same return is spread: low = frequent small wins, high = rare huge wins.
-- Wins are fractions of a goog for small bets, so the final payout is rounded randomly up or down in proportion to
-- the fraction. That keeps the return exact even for 1 goog bets (no systematic rounding loss).
-- =====================================================================================================
create or replace function public._slots_weights(p_risk text) returns int[]
language sql immutable as $$
  select case p_risk
    when 'low'    then array[5,7,10,14,20,28,8,3]
    when 'medium' then array[3,5,8,13,20,29,6,3]
    when 'high'   then array[2,3,6,11,21,35,5,3]
  end
$$;

-- 18 numbers per risk: for each cat 1..6 the pay (x line bet) for 3, 4 and 5 of a kind
create or replace function public._slots_paytable(p_risk text) returns numeric[]
language sql immutable as $$
  select case p_risk
    when 'low'    then array[10.92,32.75,98.26,8.19,24.56,73.69,6.55,19.65,58.96,4.91,14.74,44.22,3.55,10.64,31.93,2.73,8.19,24.56]::numeric[]
    when 'medium' then array[11.56,57.80,289.02,6.94,34.68,173.41,4.62,23.12,115.61,2.89,14.45,72.25,1.73,8.67,43.35,1.16,5.78,28.90]::numeric[]
    when 'high'   then array[27.04,270.36,2162.88,11.27,112.65,901.20,4.51,45.06,360.48,1.80,18.02,144.19,0.68,6.76,54.07,0.23,2.25,18.02]::numeric[]
  end
$$;

-- rows (0 = top, 1 = middle, 2 = bottom) per reel for each of the 20 paylines
create or replace function public._slots_lines() returns int[]
language sql immutable as $$
  select array[
    [1,1,1,1,1],[0,0,0,0,0],[2,2,2,2,2],[0,1,2,1,0],[2,1,0,1,2],
    [0,0,1,2,2],[2,2,1,0,0],[1,0,0,0,1],[1,2,2,2,1],[0,1,1,1,0],
    [2,1,1,1,2],[1,0,1,2,1],[1,2,1,0,1],[0,1,0,1,0],[2,1,2,1,2],
    [1,1,0,1,1],[1,1,2,1,1],[0,0,2,0,0],[2,2,0,2,2],[0,2,2,2,0]]
$$;

-- One spin, no money involved. Returns the grid (5 reels x 3 rows), the winning lines and the summed line multiplier.
create or replace function public._slots_spin(p_lines int, p_risk text)
returns json language plpgsql volatile set search_path = public as $$
declare
  w int[] := public._slots_weights(p_risk); tot int; pay numeric[] := public._slots_paytable(p_risk);
  lines int[] := public._slots_lines();
  grid int[] := array_fill(0, array[5, 3]);
  reel int; rw int; r int; s int; acc int; scat int := 0;
  l int; c int; cnt int; sym int; cell int; m numeric; sum_m numeric := 0; wins jsonb := '[]'::jsonb;
begin
  select sum(x) into tot from unnest(w) x;
  for reel in 1 .. 5 loop
    for rw in 1 .. 3 loop
      r := floor(public.secure_random() * tot)::int;
      s := 1; acc := w[1];
      while r >= acc loop s := s + 1; acc := acc + w[s]; end loop;
      grid[reel][rw] := s;
      if s = 8 then scat := scat + 1; end if;
    end loop;
  end loop;

  for l in 1 .. p_lines loop
    sym := null; cnt := 0;
    for reel in 1 .. 5 loop
      cell := grid[reel][lines[l][reel] + 1];
      if cell = 8 then exit; end if;                        -- the scatter stops a line
      if cell = 7 then cnt := cnt + 1;                      -- wild
      elsif sym is null then sym := cell; cnt := cnt + 1;
      elsif cell = sym then cnt := cnt + 1;
      else exit; end if;
    end loop;
    if cnt >= 3 then
      if sym is null then sym := 1; end if;                 -- a line of only wilds pays like the top cat
      m := pay[(sym - 1) * 3 + (cnt - 2)];
      sum_m := sum_m + m;
      wins := wins || jsonb_build_object('line', l, 'symbol', sym, 'count', cnt, 'mult', m);
    end if;
  end loop;
  return json_build_object('grid', grid, 'wins', wins, 'line_mult', sum_m, 'scatters', scat);
end $$;

-- Paytable and rules for the screen
create or replace function public.slots_info(p_risk text) returns json
language plpgsql stable security definer set search_path = public as $$
declare pay numeric[]; i int; res jsonb := '{}'::jsonb;
begin
  if p_risk not in ('low', 'medium', 'high') then raise exception 'Risk must be low, medium or high'; end if;
  pay := public._slots_paytable(p_risk);
  for i in 1 .. 6 loop
    res := res || jsonb_build_object(i::text, jsonb_build_array(pay[(i-1)*3+1], pay[(i-1)*3+2], pay[(i-1)*3+3]));
  end loop;
  return json_build_object('pay', res,
    'scatter_pay', json_build_object('3', 1, '4', 5, '5', 25),
    'free_spins', json_build_object('3', 8, '4', 12, '5', 20), 'free_mult', 2, 'max_lines', 20);
end $$;

create or replace function public.play_slots(p_per_line bigint, p_lines int, p_risk text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_total bigint; v_bal bigint; v_base json; v_sp json;
  v_scat int; v_nfree int := 0; v_free jsonb := '[]'::jsonb; v_free_win numeric := 0;
  v_base_win numeric; v_scat_win numeric := 0; v_grand numeric; v_pay bigint; i int; v_fw numeric;
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

  return json_build_object(
    'grid', v_base -> 'grid', 'wins', v_base -> 'wins', 'base_win', round(v_base_win, 2),
    'scatters', v_scat, 'scatter_win', v_scat_win,
    'free_spins', v_nfree, 'free', v_free, 'free_win', round(v_free_win, 2),
    'total_bet', v_total, 'payout', v_pay, 'balance', v_bal);
end $$;

-- =====================================================================================================
-- CAT TOWER: 8 floors. Each floor has tiles and some hide a trap (the spray bottle). Pick a safe tile to climb.
-- multiplier after n floors = 0.99 * (tiles / (tiles - traps)) ^ n.  Cash out after any floor.
-- =====================================================================================================
create table if not exists public.tower_games (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  bet        bigint not null,
  difficulty text not null,
  tiles      smallint not null,
  traps      smallint not null,
  trap_masks int[] not null,                       -- secret until the round ends: one bit mask per floor
  picks      int[] not null default '{}',          -- tile chosen on each cleared floor
  status     text not null default 'active' check (status in ('active', 'won', 'lost')),
  payout     bigint not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists tower_one_active_per_user on public.tower_games (user_id) where status = 'active';
alter table public.tower_games enable row level security;
revoke all on public.tower_games from anon, authenticated;

create or replace function public._tower_rows() returns int language sql immutable as $$ select 8 $$;

create or replace function public._tower_cfg(p_diff text, out tiles int, out traps int)
language sql immutable as $$
  select case p_diff when 'easy' then 4 when 'medium' then 3 when 'hard' then 2 when 'expert' then 3 end,
         case p_diff when 'easy' then 1 when 'medium' then 1 when 'hard' then 1 when 'expert' then 2 end
$$;

create or replace function public._tower_mult(p_tiles int, p_traps int, p_level int) returns numeric
language sql immutable as $$
  select round((1 - public.house_edge()) * power(p_tiles::numeric / (p_tiles - p_traps), p_level), 4)
$$;

-- multiplier for every floor, for the screen
create or replace function public.tower_ladder(p_diff text) returns json
language plpgsql stable security definer set search_path = public as $$
declare c record; i int; res numeric[] := '{}';
begin
  select * into c from public._tower_cfg(p_diff);
  if c.tiles is null then raise exception 'Unknown difficulty'; end if;
  for i in 1 .. public._tower_rows() loop res := res || public._tower_mult(c.tiles, c.traps, i); end loop;
  return json_build_object('tiles', c.tiles, 'traps', c.traps, 'rows', public._tower_rows(), 'multipliers', res);
end $$;

create or replace function public.tower_start(p_bet bigint, p_diff text) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); c record; v_bal bigint; v_masks int[] := '{}'; i int; v_mask int; t int;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into c from public._tower_cfg(p_diff);
  if c.tiles is null then raise exception 'Choose a difficulty'; end if;
  perform 1 from public.profiles where id = v_uid for update;
  if exists (select 1 from public.tower_games where user_id = v_uid and status = 'active') then
    raise exception 'Finish your current tower climb first';
  end if;
  v_bal := public._take_bet(v_uid, p_bet);
  for i in 1 .. public._tower_rows() loop
    v_mask := 0;
    for t in select x from generate_series(0, c.tiles - 1) x order by public.secure_random() limit c.traps loop
      v_mask := v_mask | (1 << t);
    end loop;
    v_masks := v_masks || v_mask;
  end loop;
  insert into public.tower_games (user_id, bet, difficulty, tiles, traps, trap_masks)
    values (v_uid, p_bet, p_diff, c.tiles, c.traps, v_masks);
  return json_build_object('balance', v_bal, 'bet', p_bet, 'tiles', c.tiles, 'traps', c.traps,
                           'rows', public._tower_rows(), 'level', 0,
                           'next_multiplier', public._tower_mult(c.tiles, c.traps, 1));
end $$;

create or replace function public.tower_pick(p_tile int) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); g public.tower_games%rowtype; v_level int; v_mult numeric; v_pay bigint; v_bal bigint;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.tower_games where user_id = v_uid and status = 'active' for update;
  if not found then raise exception 'No active climb'; end if;
  if p_tile is null or p_tile < 0 or p_tile >= g.tiles then raise exception 'Invalid tile'; end if;
  v_level := coalesce(array_length(g.picks, 1), 0);                 -- floors cleared so far (0-based index of this floor)

  if (g.trap_masks[v_level + 1] & (1 << p_tile)) <> 0 then
    update public.tower_games set status = 'lost' where id = g.id;
    select goog into v_bal from public.profiles where id = v_uid;
    return json_build_object('hit', true, 'level', v_level, 'tile', p_tile, 'picks', g.picks,
                             'trap_masks', g.trap_masks, 'balance', v_bal);
  end if;

  v_level := v_level + 1;
  v_mult := public._tower_mult(g.tiles, g.traps, v_level);
  if v_level = public._tower_rows() then                            -- reached the top: automatic cash-out
    v_pay := floor(g.bet * v_mult)::bigint;
    v_bal := public._pay(v_uid, v_pay);
    update public.tower_games set picks = array_append(picks, p_tile), status = 'won', payout = v_pay where id = g.id;
    return json_build_object('hit', false, 'done', true, 'level', v_level, 'picks', array_append(g.picks, p_tile),
                             'multiplier', v_mult, 'payout', v_pay, 'trap_masks', g.trap_masks, 'balance', v_bal);
  end if;
  update public.tower_games set picks = array_append(picks, p_tile) where id = g.id;
  select goog into v_bal from public.profiles where id = v_uid;
  return json_build_object('hit', false, 'done', false, 'level', v_level, 'picks', array_append(g.picks, p_tile),
                           'multiplier', v_mult, 'next_multiplier', public._tower_mult(g.tiles, g.traps, v_level + 1),
                           'balance', v_bal);
end $$;

create or replace function public.tower_cashout() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); g public.tower_games%rowtype; v_level int; v_mult numeric; v_pay bigint; v_bal bigint;
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
  return json_build_object('payout', v_pay, 'multiplier', v_mult, 'level', v_level, 'picks', g.picks,
                           'trap_masks', g.trap_masks, 'balance', v_bal);
end $$;

create or replace function public.tower_active() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); g public.tower_games%rowtype; v_level int;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into g from public.tower_games where user_id = v_uid and status = 'active';
  if not found then return json_build_object('active', false); end if;
  v_level := coalesce(array_length(g.picks, 1), 0);
  return json_build_object('active', true, 'bet', g.bet, 'difficulty', g.difficulty, 'tiles', g.tiles, 'traps', g.traps,
    'rows', public._tower_rows(), 'level', v_level, 'picks', g.picks,
    'multiplier', case when v_level = 0 then 1 else public._tower_mult(g.tiles, g.traps, v_level) end,
    'next_multiplier', public._tower_mult(g.tiles, g.traps, v_level + 1));
end $$;

-- =====================================================================================================
-- CAT ROULETTE: European wheel, one zero (0..36). Place as many bets as you like, then spin once.
-- Bet types: straight (value 0..36, pays 35:1), red, black, even, odd, low (1-18), high (19-36) pay 1:1,
-- dozen (value 1..3) and column (value 1..3) pay 2:1.
-- =====================================================================================================
create or replace function public._roulette_red(n int) returns boolean
language sql immutable as $$ select n = any (array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) $$;

create or replace function public.play_roulette(p_bets jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); b jsonb; v_type text; v_val int; v_amt bigint; v_total bigint := 0;
  v_n int; v_pay bigint := 0; v_one bigint; v_win boolean; v_res jsonb := '[]'::jsonb; v_bal bigint;
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
  return json_build_object('number', v_n,
    'color', case when v_n = 0 then 'green' when public._roulette_red(v_n) then 'red' else 'black' end,
    'results', v_res, 'total_bet', v_total, 'payout', v_pay, 'balance', v_bal);
end $$;

-- =====================================================================================================
-- SCRATCH CARDS: 9 cat tiles. Find 3 of the same cat to win that cat's prize (multiple of the card price).
-- Prices 1, 5, 25 or 100 goog. Return to player 99%, about 1 card in 4.5 wins something.
-- =====================================================================================================
-- cat (symbol), prize multiplier, chance in a million
create or replace function public._scratch_prizes() returns int[]
language sql immutable as $$
  select array[[6,1,100000],[5,2,60000],[4,5,40000],[3,10,20000],[2,50,3500],[1,500,390]]
$$;

create or replace function public.scratch_info() returns json
language plpgsql stable security definer set search_path = public as $$
declare pr int[] := public._scratch_prizes(); i int; res jsonb := '[]'::jsonb;
begin
  for i in 1 .. 6 loop
    res := res || jsonb_build_object('symbol', pr[i][1], 'multiplier', pr[i][2], 'chance', pr[i][3] / 1000000.0);
  end loop;
  return res::json;
end $$;

create or replace function public.play_scratch(p_price bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_bal bigint; pr int[] := public._scratch_prizes(); r int; acc int := 0; i int;
  v_sym int := null; v_mult int := 0; v_cells int[]; v_pool int[]; v_pay bigint := 0;
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
  return json_build_object('cells', v_cells, 'win_symbol', v_sym, 'multiplier', v_mult,
                           'price', p_price, 'payout', v_pay, 'balance', v_bal);
end $$;

-- =====================================================================================================
-- permissions: lock everything, then open only what the site calls (logged-in players only)
-- =====================================================================================================
revoke execute on function
  public._slots_weights(text), public._slots_paytable(text), public._slots_lines(), public._slots_spin(int, text),
  public._tower_rows(), public._tower_cfg(text), public._tower_mult(int, int, int), public._roulette_red(int),
  public._scratch_prizes(),
  public.slots_info(text), public.play_slots(bigint, int, text),
  public.tower_ladder(text), public.tower_start(bigint, text), public.tower_pick(int), public.tower_cashout(), public.tower_active(),
  public.play_roulette(jsonb), public.scratch_info(), public.play_scratch(bigint)
from public, anon, authenticated;

grant execute on function
  public.slots_info(text), public.play_slots(bigint, int, text),
  public.tower_ladder(text), public.tower_start(bigint, text), public.tower_pick(int), public.tower_cashout(), public.tower_active(),
  public.play_roulette(jsonb), public.scratch_info(), public.play_scratch(bigint)
to authenticated;
