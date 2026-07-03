-- ============================================================================
-- ClockPoint — Geotagging (by position, built into clock-in)
--   * positions.geotag: admin flags which positions ("classes of staff") geotag
--   * clock-in for a geotag position AUTO-DETECTS which mapped site the staff is
--     inside (nearest within radius) and labels it; if inside none -> flagged
--     red (within_geofence=false), visible only in the admin log.
--   * Non-geotag positions keep the existing assigned-site behaviour.
-- Run in the SQL Editor after the earlier files. Safe to re-run.
-- ============================================================================

alter table positions add column if not exists geotag boolean not null default false;

-- Distance helper is inline; here's the updated submit function.
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
  srow     sites%rowtype;
  best     sites%rowtype;
  d_m      integer;
  best_d   integer;
  inside   boolean;
  is_geo   boolean;
  result   clock_events;
begin
  if p_event_type not in ('IN','OUT') then raise exception 'event_type must be IN or OUT'; end if;

  select * into s from staff where id = p_staff_id and active = true;
  if not found then raise exception 'unknown or inactive staff member'; end if;

  -- Is this staff member's position flagged for geotagging?
  select coalesce(bool_or(p.geotag), false) into is_geo
    from positions p where p.organization_id = s.organization_id and p.name = s.position;

  if is_geo and p_lat is not null and p_lng is not null then
    -- Auto-detect: the nearest active site the staff is within radius of.
    best_d := null;
    for srow in select * from sites where organization_id = s.organization_id and active loop
      d_m := round(2 * 6371000 * asin(sqrt(
               power(sin(radians(srow.center_lat - p_lat) / 2), 2) +
               cos(radians(p_lat)) * cos(radians(srow.center_lat)) *
               power(sin(radians(srow.center_lng - p_lng) / 2), 2))))::integer;
      if d_m <= srow.radius_m and (best_d is null or d_m < best_d) then
        best_d := d_m; best := srow;
      end if;
    end loop;
    if best_d is not null then
      site := best; d_m := best_d; inside := true;
    else
      site := null; d_m := null; inside := false;   -- outside every site -> flagged red
    end if;
  else
    -- Assigned-site behaviour (unchanged).
    select * into site from sites where id = s.assigned_site_id;
    if site.id is not null and p_lat is not null and p_lng is not null then
      d_m := round(2 * 6371000 * asin(sqrt(
               power(sin(radians(site.center_lat - p_lat) / 2), 2) +
               cos(radians(p_lat)) * cos(radians(site.center_lat)) *
               power(sin(radians(site.center_lng - p_lng) / 2), 2))))::integer;
      inside := d_m <= site.radius_m;
    else
      d_m := null; inside := null;
    end if;
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
grant execute on function submit_clock_event(
  uuid, text, double precision, double precision, integer, timestamptz, text, jsonb
) to anon, authenticated;

-- Tell the staff screen which staff geotag (so the live hint matches the server).
create or replace function clock_in_context(p_org text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare org_row organizations%rowtype;
begin
  select * into org_row from organizations
   where (slug = p_org or id::text = p_org) and status = 'active' limit 1;
  if not found then return jsonb_build_object('error', 'Organization not found'); end if;
  return jsonb_build_object(
    'org', jsonb_build_object('id', org_row.id, 'name', org_row.name, 'slug', org_row.slug,
             'brand_color', org_row.brand_color, 'logo_url', org_row.logo_url),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name,
               'lat', s.center_lat, 'lng', s.center_lng, 'radius', s.radius_m) order by s.name)
      from sites s where s.organization_id = org_row.id and s.active), '[]'::jsonb),
    'staff', coalesce((
      select jsonb_agg(jsonb_build_object('id', st.id, 'name', st.full_name,
               'position', st.position, 'siteId', st.assigned_site_id,
               'geotag', coalesce((select bool_or(p.geotag) from positions p
                          where p.organization_id = org_row.id and p.name = st.position), false)
             ) order by st.full_name)
      from staff st where st.organization_id = org_row.id and st.active), '[]'::jsonb)
  );
end;
$$;
grant execute on function clock_in_context(text) to anon, authenticated;
