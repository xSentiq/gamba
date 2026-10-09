-- Economy and admin: daily bonus, "draw a cat" rescue, admin panel, bans.
-- Run in Supabase -> SQL Editor AFTER migration-003-games.sql. Safe to re-run.
--
-- Nothing here can be called to hand out goog from the browser except through the rules below.
-- Every function checks auth.uid() on the server; the admin functions check profiles.is_admin.

-- ---------------------------------------------------------------- settings you may want to change
-- Daily login bonus (goog) and the "draw a cat" rescue rules.
create or replace function public.daily_bonus() returns bigint
language sql immutable as $$ select 25::bigint $$;

create or replace function public.rescue_threshold() returns bigint        -- you can draw when you have LESS than this
language sql immutable as $$ select 10::bigint $$;

create or replace function public.rescue_amount() returns bigint
language sql immutable as $$ select 10::bigint $$;

create or replace function public.rescue_cooldown() returns interval       -- how often one player may use the rescue
language sql immutable as $$ select interval '6 hours' $$;

-- ---------------------------------------------------------------- columns on profiles
alter table public.profiles add column if not exists is_admin   boolean not null default false;
alter table public.profiles add column if not exists banned     boolean not null default false;
alter table public.profiles add column if not exists last_daily date;
-- No grants for these columns: the browser can neither read nor change them. (Column privileges from schema.sql
-- only cover the columns listed there.) They are read through my_status() below.

-- ---------------------------------------------------------------- tables
create table if not exists public.cat_drawings (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  image       bytea not null,                                   -- PNG
  granted     bigint not null default 0,                        -- goog given for this drawing
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists cat_drawings_user_idx on public.cat_drawings (user_id, created_at desc);
alter table public.cat_drawings enable row level security;        -- no policies and no grants: functions only
revoke all on public.cat_drawings from anon, authenticated;

create table if not exists public.admin_actions (
  id         bigint generated always as identity primary key,
  admin_id   uuid references auth.users(id) on delete set null,
  target_id  uuid,
  action     text not null,
  detail     text,
  created_at timestamptz not null default now()
);
alter table public.admin_actions enable row level security;
revoke all on public.admin_actions from anon, authenticated;

-- Secrets for the optional e-mail notification (see README). Not readable from the browser.
create table if not exists public.app_secrets (key text primary key, value text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

-- ---------------------------------------------------------------- bans: banned players cannot place bets
create or replace function public._take_bet(p_user uuid, p_bet bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_bal bigint; v_banned boolean;
begin
  if p_bet is null or p_bet < 1 then raise exception 'Bet at least 1 goog'; end if;
  select goog, banned into v_bal, v_banned from public.profiles where id = p_user for update;
  if not found then raise exception 'Profile not found'; end if;
  if v_banned then raise exception 'This account is banned from playing'; end if;
  if p_bet > v_bal then raise exception 'Not enough goog'; end if;
  update public.profiles set goog = goog - p_bet where id = p_user returning goog into v_bal;
  return v_bal;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function public._is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

create or replace function public._require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public._is_admin() then raise exception 'Admins only'; end if;
end $$;

create or replace function public._berlin_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Berlin')::date $$;

-- ---------------------------------------------------------------- status of the logged-in player
create or replace function public.my_status() returns json
language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype; v_last timestamptz;
begin
  if auth.uid() is null then raise exception 'Log in first'; end if;
  select * into p from public.profiles where id = auth.uid();
  if not found then raise exception 'Profile not found'; end if;
  select max(created_at) into v_last from public.cat_drawings where user_id = p.id;
  return json_build_object(
    'goog', p.goog,
    'is_admin', p.is_admin,
    'banned', p.banned,
    'daily_available', (not p.banned) and (p.last_daily is distinct from public._berlin_today()),
    'daily_amount', public.daily_bonus(),
    'rescue_available', (not p.banned) and p.goog < public.rescue_threshold()
                         and (v_last is null or v_last + public.rescue_cooldown() <= now()),
    'rescue_below', public.rescue_threshold(),
    'rescue_amount', public.rescue_amount(),
    'rescue_next_at', case when v_last is null then null else v_last + public.rescue_cooldown() end);
end $$;

-- ---------------------------------------------------------------- daily login bonus (one per calendar day, Berlin time)
create or replace function public.claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p public.profiles%rowtype; v_bal bigint;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into p from public.profiles where id = v_uid for update;
  if not found then raise exception 'Profile not found'; end if;
  if p.banned then raise exception 'This account is banned'; end if;
  if p.last_daily = public._berlin_today() then
    return json_build_object('claimed', false, 'balance', p.goog);
  end if;
  update public.profiles set goog = goog + public.daily_bonus(), last_daily = public._berlin_today()
    where id = v_uid returning goog into v_bal;
  return json_build_object('claimed', true, 'amount', public.daily_bonus(), 'balance', v_bal);
end $$;

-- ---------------------------------------------------------------- "draw a cat" rescue
-- Below 10 goog a player may submit a drawing and receives 10 goog right away. The drawing is stored for the admin
-- and (optionally) e-mailed. An admin can reject it, which takes the goog back (down to 0 at most).
create or replace function public.submit_cat_drawing(p_png_base64 text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid(); p public.profiles%rowtype; v_img bytea; v_last timestamptz;
  v_id bigint; v_bal bigint;
begin
  if v_uid is null then raise exception 'Log in first'; end if;
  select * into p from public.profiles where id = v_uid for update;
  if not found then raise exception 'Profile not found'; end if;
  if p.banned then raise exception 'This account is banned'; end if;
  if p.goog >= public.rescue_threshold() then
    raise exception 'You can only draw a cat when you have less than % goog', public.rescue_threshold();
  end if;
  select max(created_at) into v_last from public.cat_drawings where user_id = v_uid;
  if v_last is not null and v_last + public.rescue_cooldown() > now() then
    raise exception 'You already drew a cat recently. Try again later.';
  end if;

  if p_png_base64 is null or length(p_png_base64) > 300000 then raise exception 'That drawing is too large'; end if;
  begin
    v_img := decode(regexp_replace(p_png_base64, '^data:image/png;base64,', ''), 'base64');
  exception when others then
    raise exception 'That drawing could not be read';
  end;
  if length(v_img) < 600 or substring(v_img from 1 for 8) <> '\x89504e470d0a1a0a'::bytea then
    raise exception 'That drawing could not be read';
  end if;

  insert into public.cat_drawings (user_id, image, granted) values (v_uid, v_img, public.rescue_amount())
    returning id into v_id;
  update public.profiles set goog = goog + public.rescue_amount() where id = v_uid returning goog into v_bal;
  return json_build_object('id', v_id, 'amount', public.rescue_amount(), 'balance', v_bal);
end $$;

-- E-mail the drawing (optional). Needs the pg_net extension and a Resend API key in app_secrets; see README.
-- It can never block or break the drawing: any problem is swallowed.
create or replace function public._email_drawing() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_key text; v_to text; v_from text; v_name text;
begin
  begin
    select value into v_key  from public.app_secrets where key = 'resend_api_key';
    select value into v_to   from public.app_secrets where key = 'drawing_email_to';
    select value into v_from from public.app_secrets where key = 'drawing_email_from';
    if v_key is null or to_regproc('net.http_post') is null then return new; end if;
    select username into v_name from public.profiles where id = new.user_id;
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
      body := jsonb_build_object(
        'from', coalesce(v_from, 'goog <onboarding@resend.dev>'),
        'to', jsonb_build_array(coalesce(v_to, 'xsentiq@gmail.com')),
        'subject', 'New goog cat drawing from ' || coalesce(v_name, 'unknown'),
        'text', 'Player ' || coalesce(v_name, 'unknown') || ' drew a cat and received ' || new.granted
                || ' goog. Open the admin panel to approve it, or reject it to take the goog back. Drawing id: ' || new.id,
        'attachments', jsonb_build_array(jsonb_build_object(
          'filename', 'cat-' || new.id || '.png',
          'content', replace(encode(new.image, 'base64'), E'\n', '')))),
      timeout_milliseconds := 5000);
  exception when others then
    null;
  end;
  return new;
end $$;

drop trigger if exists email_new_drawing on public.cat_drawings;
create trigger email_new_drawing after insert on public.cat_drawings
  for each row execute function public._email_drawing();

-- ---------------------------------------------------------------- admin functions
create or replace function public.admin_overview() returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  return json_build_object(
    'players', (select count(*) from public.profiles),
    'total_goog', (select coalesce(sum(goog), 0) from public.profiles),
    'banned', (select count(*) from public.profiles where banned),
    'pending_drawings', (select count(*) from public.cat_drawings where status = 'pending'));
end $$;

create or replace function public.admin_list_users(p_search text default null, p_limit int default 50, p_offset int default 0)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select json_agg(row_to_json(t)) from (
    select id, username, goog, banned, is_admin, created_at
    from public.profiles
    where p_search is null or p_search = '' or username ilike '%' || replace(replace(p_search, '%', ''), '_', '\_') || '%'
    order by goog desc, created_at
    limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) t), '[]'::json);
end $$;

-- p_delta may be negative. A removal never takes a balance below 0; the returned "applied" is what really changed.
create or replace function public.admin_adjust_goog(p_user uuid, p_delta bigint, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_old bigint; v_new bigint;
begin
  perform public._require_admin();
  if p_delta is null or p_delta = 0 then raise exception 'Enter an amount'; end if;
  select goog into v_old from public.profiles where id = p_user for update;
  if not found then raise exception 'Player not found'; end if;
  v_new := greatest(0, v_old + p_delta);
  update public.profiles set goog = v_new where id = p_user;
  insert into public.admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), p_user, 'adjust_goog', (v_new - v_old) || ' goog; ' || coalesce(p_note, ''));
  return json_build_object('balance', v_new, 'applied', v_new - v_old);
end $$;

create or replace function public.admin_set_goog(p_user uuid, p_amount bigint, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_old bigint;
begin
  perform public._require_admin();
  if p_amount is null or p_amount < 0 then raise exception 'Amount must be 0 or more'; end if;
  select goog into v_old from public.profiles where id = p_user for update;
  if not found then raise exception 'Player not found'; end if;
  update public.profiles set goog = p_amount where id = p_user;
  insert into public.admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), p_user, 'set_goog', v_old || ' -> ' || p_amount || '; ' || coalesce(p_note, ''));
  return json_build_object('balance', p_amount);
end $$;

create or replace function public.admin_set_banned(p_user uuid, p_banned boolean)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_user = auth.uid() then raise exception 'You cannot ban yourself'; end if;
  update public.profiles set banned = coalesce(p_banned, false) where id = p_user;
  if not found then raise exception 'Player not found'; end if;
  insert into public.admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), p_user, case when p_banned then 'ban' else 'unban' end, null);
  return json_build_object('banned', coalesce(p_banned, false));
end $$;

create or replace function public.admin_give_everyone(p_amount bigint, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_n bigint;
begin
  perform public._require_admin();
  if p_amount is null or p_amount < 1 or p_amount > 100000 then raise exception 'Amount must be 1 to 100000'; end if;
  update public.profiles set goog = goog + p_amount where not banned;
  get diagnostics v_n = row_count;
  insert into public.admin_actions (admin_id, action, detail)
    values (auth.uid(), 'give_everyone', p_amount || ' goog to ' || v_n || ' players; ' || coalesce(p_note, ''));
  return json_build_object('players', v_n);
end $$;

create or replace function public.admin_list_drawings(p_status text default 'pending', p_limit int default 20)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select json_agg(row_to_json(t)) from (
    select d.id, d.user_id, p.username, d.granted, d.status, d.created_at,
           replace(encode(d.image, 'base64'), E'\n', '') as image
    from public.cat_drawings d left join public.profiles p on p.id = d.user_id
    where p_status is null or p_status = 'all' or d.status = p_status
    order by d.created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 50)) t), '[]'::json);
end $$;

-- approve = keep the goog; reject = take the goog back (as far as the balance allows)
create or replace function public.admin_review_drawing(p_id bigint, p_approve boolean)
returns json language plpgsql security definer set search_path = public as $$
declare d public.cat_drawings%rowtype; v_back bigint := 0; v_bal bigint;
begin
  perform public._require_admin();
  select * into d from public.cat_drawings where id = p_id for update;
  if not found then raise exception 'Drawing not found'; end if;
  if d.status <> 'pending' then raise exception 'This drawing was already reviewed'; end if;
  if p_approve then
    update public.cat_drawings set status = 'approved', reviewed_at = now() where id = p_id;
    select goog into v_bal from public.profiles where id = d.user_id;
  else
    select least(goog, d.granted) into v_back from public.profiles where id = d.user_id for update;
    v_back := coalesce(v_back, 0);
    update public.profiles set goog = goog - v_back where id = d.user_id returning goog into v_bal;
    update public.cat_drawings set status = 'rejected', reviewed_at = now() where id = p_id;
  end if;
  insert into public.admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), d.user_id, case when p_approve then 'approve_drawing' else 'reject_drawing' end,
            'drawing ' || p_id || '; taken back ' || v_back);
  return json_build_object('status', case when p_approve then 'approved' else 'rejected' end,
                           'taken_back', v_back, 'player_balance', v_bal);
end $$;

create or replace function public.admin_recent_actions(p_limit int default 30)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  return coalesce((select json_agg(row_to_json(t)) from (
    select a.id, a.action, a.detail, a.created_at,
           (select username from public.profiles where id = a.admin_id) as admin,
           (select username from public.profiles where id = a.target_id) as target
    from public.admin_actions a order by a.id desc
    limit least(greatest(coalesce(p_limit, 30), 1), 100)) t), '[]'::json);
end $$;

-- ---------------------------------------------------------------- permissions
-- Lock everything first, then open only what the site calls (and only to logged-in players).
revoke execute on function
  public._take_bet(uuid, bigint), public._is_admin(), public._require_admin(), public._email_drawing(),
  public.my_status(), public.claim_daily(), public.submit_cat_drawing(text),
  public.admin_overview(), public.admin_list_users(text, int, int), public.admin_adjust_goog(uuid, bigint, text),
  public.admin_set_goog(uuid, bigint, text), public.admin_set_banned(uuid, boolean), public.admin_give_everyone(bigint, text),
  public.admin_list_drawings(text, int), public.admin_review_drawing(bigint, boolean), public.admin_recent_actions(int)
from public, anon, authenticated;

grant execute on function
  public.my_status(), public.claim_daily(), public.submit_cat_drawing(text),
  public.admin_overview(), public.admin_list_users(text, int, int), public.admin_adjust_goog(uuid, bigint, text),
  public.admin_set_goog(uuid, bigint, text), public.admin_set_banned(uuid, boolean), public.admin_give_everyone(bigint, text),
  public.admin_list_drawings(text, int), public.admin_review_drawing(bigint, boolean), public.admin_recent_actions(int)
to authenticated;
