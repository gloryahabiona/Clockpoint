-- ============================================================================
-- ClockPoint — Storage for company logos
-- Creates a PUBLIC "branding" bucket so uploaded logos get a clean, always-
-- loadable public URL (no Google Drive / hotlink problems). Run once in the
-- SQL Editor. Safe to re-run.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('branding', 'branding', true)
on conflict (id) do update set public = excluded.public;

-- Signed-in admins (org admins + super admin) may upload / replace logos.
drop policy if exists "branding insert" on storage.objects;
create policy "branding insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'branding');

drop policy if exists "branding update" on storage.objects;
create policy "branding update" on storage.objects for update to authenticated
  using (bucket_id = 'branding') with check (bucket_id = 'branding');

-- Logos are public assets — anyone can read them (the bucket is public).
drop policy if exists "branding read" on storage.objects;
create policy "branding read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'branding');
