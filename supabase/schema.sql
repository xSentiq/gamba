-- Fresh install: run this once in Supabase → SQL Editor.
-- Already ran the first version? Run supabase/migration-002-avatars.sql instead.

-- 1) Profiles: one row per account, holds the goog balance and avatar version
create table public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  username       text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  goog           bigint not null default 100 check (goog >= 0),
  avatar_version bigint,                       -- null = no picture; otherwise a cache-busting timestamp
  created_at     timestamptz not null default now()
);
create unique index profiles_username_lower_idx on public.profiles (lower(username));
create index profiles_goog_idx on public.profiles (goog desc);

-- 2) Row Level Security
alter table public.profiles enable row level security;
create policy "profiles are readable by everyone"
  on public.profiles for select using (true);
create policy "users can update their own row"
  on public.profiles for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

-- Column-level privileges: browsers may read profiles, and may only ever change avatar_version.
-- goog and username can NOT be changed from the browser.
revoke all on public.profiles from anon, authenticated;
grant select (id, username, goog, avatar_version, created_at) on public.profiles to anon, authenticated;
grant update (avatar_version) on public.profiles to authenticated;

-- 3) Create the profile automatically on registration (balance starts at the default of 100)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, username)
  values (new.id, new.raw_user_meta_data ->> 'username');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 4) Profile pictures: public bucket, each user may only write inside their own folder (<user id>/)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

create policy "avatars are publicly readable"
  on storage.objects for select using (bucket_id = 'avatars');
create policy "users upload their own avatar"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "users replace their own avatar"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "users delete their own avatar"
  on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- 5) LATER: ways to earn goog.
-- Always change balances inside server-side functions, never from the browser. Example sketch:
--
-- create or replace function public.award_goog(p_user uuid, p_amount bigint)
-- returns void language sql security definer set search_path = public as $$
--   update public.profiles set goog = goog + p_amount where id = p_user;
-- $$;
-- revoke execute on function public.award_goog from public, anon, authenticated;
--
-- Then expose specific, rule-checked actions (e.g. "claim daily reward", "finish a game") as their own
-- functions and grant execute on those to `authenticated`.
