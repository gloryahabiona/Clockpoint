-- ============================================================================
-- ClockPoint — Stage A database schema (Supabase / PostgreSQL)
-- ----------------------------------------------------------------------------
-- Run this once in your Supabase project: SQL Editor -> New query -> paste -> Run.
-- It is idempotent-ish (uses IF NOT EXISTS) so re-running is safe.
--
-- What this gives you (per clockpoint-backend-spec.md):
--   * Tables for organizations, admins, positions, sites, staff, clock_events
--   * Row-Level Security so each org only ever sees its own data
--   * An APPEND-ONLY audit log (no UPDATE / DELETE of clock events)
--   * A server-side submit_clock_event() function that stamps the time and
--     runs the geofence check on the SERVER, against the staff member's
--     ASSIGNED site — the phone cannot choose the site or fake the verdict.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

create table if not exists organizations (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  plan         text not null default 'free' check (plan in ('free','paid')),
  status       text not null default 'active' check (status in ('active','suspended')),
  free_slot    boolean not null default true,
  api_enabled  boolean not null default false,
  created_at   timestamptz not null default now()
);

-- Admins who log in. id == Supabase auth user id (auth.users.id).
create table if not exists app_users (
  id               uuid primary key references auth.users(id) on delete cascade,
  organization_id  uuid not null references organizations(id) on delete cascade,
  email            text,
  role             text not null default 'admin' check (role in ('owner','admin','viewer')),
  created_at       timestamptz not null default now()
);

create table if not exists positions (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references organizations(id) on delete cascade,
  name             text not null,
  created_at       timestamptz not null default now()
);

create table if not exists sites (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references organizations(id) on delete cascade,
  name             text not null,
  center_lat       double precision not null,
  center_lng       double precision not null,
  radius_m         integer not null check (radius_m > 0),
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);

create table if not exists staff (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  full_name         text not null,
  position          text,
  assigned_site_id  uuid references sites(id) on delete set null,
  employee_code     text,
  reference_photo_url text,
  active            boolean not null default true,
  created_at        timestamptz not null default now()
);

-- The core audit log. Append-only (enforced below).
create table if not exists clock_events (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references organizations(id) on delete cascade,
  staff_id         uuid references staff(id) on delete set null,
  staff_name       text not null,
  position         text,
  site_id          uuid references sites(id) on delete set null,
  site_name        text,
  event_type       text not null check (event_type in ('IN','OUT')),
  server_time      timestamptz not null default now(),   -- source of truth
  device_time      timestamptz,                          -- for comparison only
  lat              double precision,
  lng              double precision,
  gps_accuracy_m   integer,
  distance_m       integer,        -- computed server-side
  within_geofence  boolean,        -- computed server-side
  photo_url        text,
  device_info      jsonb,
  created_at       timestamptz not null default now()
);

create index if not exists clock_events_org_time_idx on clock_events (organization_id, server_time desc);
create index if not exists staff_org_idx on staff (organization_id);
create index if not exists sites_org_idx on sites (organization_id);

-- ---------------------------------------------------------------------------
-- 2. Helper: which org does the calling admin belong to?
-- ---------------------------------------------------------------------------
create or replace function current_org_id()
returns uuid language sql stable security definer set search_path = public as $$
  select organization_id from app_users where id = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- 3. Append-only guard: block any UPDATE or DELETE on clock_events
--    (corrections happen by inserting a new annotated row, per the spec).
-- ---------------------------------------------------------------------------
create or replace function block_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'clock_events is append-only: % is not allowed', tg_op;
end;
$$;

drop trigger if exists clock_events_no_update on clock_events;
create trigger clock_events_no_update before update on clock_events
  for each row execute function block_mutation();

drop trigger if exists clock_events_no_delete on clock_events;
create trigger clock_events_no_delete before delete on clock_events
  for each row execute function block_mutation();

-- ---------------------------------------------------------------------------
-- 4. Row-Level Security — every query auto-scoped to the caller's org
-- ---------------------------------------------------------------------------
alter table organizations enable row level security;
alter table app_users     enable row level security;
alter table positions     enable row level security;
alter table sites         enable row level security;
alter table staff         enable row level security;
alter table clock_events  enable row level security;

-- Admins can read their own org; manage rows within it.
drop policy if exists org_read on organizations;
create policy org_read on organizations for select to authenticated
  using (id = current_org_id());

drop policy if exists me_read on app_users;
create policy me_read on app_users for select to authenticated
  using (organization_id = current_org_id());

-- positions / sites / staff: full management within own org.
do $$
declare t text;
begin
  foreach t in array array['positions','sites','staff'] loop
    execute format('drop policy if exists %1$s_all on %1$s', t);
    execute format(
      'create policy %1$s_all on %1$s for all to authenticated
         using (organization_id = current_org_id())
         with check (organization_id = current_org_id())', t);
  end loop;
end $$;

-- clock_events: admins may READ their org's events. No insert/update/delete
-- policy for authenticated => those are denied. Inserts happen only through
-- submit_clock_event() (security definer) below.
drop policy if exists events_read on clock_events;
create policy events_read on clock_events for select to authenticated
  using (organization_id = current_org_id());

-- The staff picker & site list need to be readable by the (unauthenticated)
-- clock-in screen. Expose ONLY active rows to the anon role, read-only.
drop policy if exists staff_anon_read on staff;
create policy staff_anon_read on staff for select to anon
  using (active = true);

drop policy if exists sites_anon_read on sites;
create policy sites_anon_read on sites for select to anon
  using (active = true);

-- ---------------------------------------------------------------------------
-- 5. The clock-in submission — server time + server geofence (THE important bit)
--    Called by the staff screen. Resolves the staff member's ASSIGNED site
--    server-side; the client never chooses the site or the verdict.
-- ---------------------------------------------------------------------------
create or replace function submit_clock_event(
  p_staff_id        uuid,
  p_event_type      text,
  p_lat             double precision,
  p_lng             double precision,
  p_gps_accuracy_m  integer default null,
  p_device_time     timestamptz default null,
  p_photo_url       text default null,
  p_device_info     jsonb default '{}'::jsonb
)
returns clock_events
language plpgsql security definer set search_path = public as $$
declare
  s        staff%rowtype;
  site     sites%rowtype;
  d_m      integer;
  inside   boolean;
  result   clock_events;
begin
  if p_event_type not in ('IN','OUT') then
    raise exception 'event_type must be IN or OUT';
  end if;

  select * into s from staff where id = p_staff_id and active = true;
  if not found then
    raise exception 'unknown or inactive staff member';
  end if;

  -- Assigned site (may be null if unassigned)
  select * into site from sites where id = s.assigned_site_id;

  if site.id is not null and p_lat is not null and p_lng is not null then
    d_m := round(
      2 * 6371000 * asin(sqrt(
        power(sin(radians(site.center_lat - p_lat) / 2), 2) +
        cos(radians(p_lat)) * cos(radians(site.center_lat)) *
        power(sin(radians(site.center_lng - p_lng) / 2), 2)
      ))
    );
    inside := d_m <= site.radius_m;
  else
    d_m := null;
    inside := null;
  end if;

  insert into clock_events (
    organization_id, staff_id, staff_name, position, site_id, site_name,
    event_type, server_time, device_time, lat, lng, gps_accuracy_m,
    distance_m, within_geofence, photo_url, device_info
  ) values (
    s.organization_id, s.id, s.full_name, s.position, site.id, site.name,
    p_event_type, now(), p_device_time, p_lat, p_lng, p_gps_accuracy_m,
    d_m, inside, p_photo_url, coalesce(p_device_info, '{}'::jsonb)
  )
  returning * into result;

  return result;
end;
$$;

-- The staff screen is unauthenticated in the MVP, so allow anon + authenticated
-- to call the submit function (it still resolves org/site server-side).
grant execute on function submit_clock_event(
  uuid, text, double precision, double precision, integer, timestamptz, text, jsonb
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Free-slot rule for organizations (platform layer — used later when selling)
--    At most 2 active 'free' organizations. Enforced in a trigger.
-- ---------------------------------------------------------------------------
create or replace function enforce_free_slots()
returns trigger language plpgsql as $$
begin
  if new.plan = 'free' and new.status = 'active' then
    if (select count(*) from organizations
          where plan = 'free' and status = 'active'
            and id <> new.id) >= 2 then
      raise exception 'Both free slots are in use — new organizations must be on a paid plan';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists organizations_free_slots on organizations;
create trigger organizations_free_slots before insert or update on organizations
  for each row execute function enforce_free_slots();
