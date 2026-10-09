-- For projects that already ran the first schema.sql. Adds profile pictures.

alter table public.profiles add column if not exists avatar_version bigint;

create policy "users can update their own row"
  on public.profiles for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

revoke all on public.profiles from anon, authenticated;
grant select (id, username, goog, avatar_version, created_at) on public.profiles to anon, authenticated;
grant update (avatar_version) on public.profiles to authenticated;

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
