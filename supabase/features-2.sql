-- ============================================================================
-- ClockPoint — Feature additions #2
--   * Fix: allow deleting sites/staff (the append-only log blocked the cascade)
--   * Org admins can change their brand color as often as they like (no lock)
--   * Per-org company logo, set by the super admin (with safe fallback)
-- Run in the SQL Editor AFTER features.sql. Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Append-only guard, refined.
--    Deleting a site/staff cascades a "set site_id/staff_id = NULL" onto the
--    historical clock_events. That's benign (the site_name / staff_name text
--    snapshots remain), so we ALLOW that specific update and keep blocking
--    every real edit or delete of attendance facts.
-- ---------------------------------------------------------------------------
create or replace function block_mutation()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'clock_events is append-only: attendance records cannot be deleted';
  end if;
  -- UPDATE: block unless ONLY site_id / staff_id changed (the FK cascade to NULL)
  if  new.id              is distinct from old.id
   or new.organization_id is distinct from old.organization_id
   or new.staff_name      is distinct from old.staff_name
   or new.position        is distinct from old.position
   or new.site_name       is distinct from old.site_name
   or new.event_type      is distinct from old.event_type
   or new.server_time     is distinct from old.server_time
   or new.device_time     is distinct from old.device_time
   or new.lat             is distinct from old.lat
   or new.lng             is distinct from old.lng
   or new.gps_accuracy_m  is distinct from old.gps_accuracy_m
   or new.distance_m      is distinct from old.distance_m
   or new.within_geofence is distinct from old.within_geofence
   or new.photo_url       is distinct from old.photo_url
   or new.created_at      is distinct from old.created_at
  then
    raise exception 'clock_events is append-only: attendance records cannot be edited';
  end if;
  return new;  -- only site_id / staff_id changed -> allow the referential cleanup
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Org admins may change the brand color any number of times (remove the lock).
-- ---------------------------------------------------------------------------
create or replace function set_org_theme(p_color text)
returns void language plpgsql security definer set search_path = public as $$
declare orgid uuid;
begin
  select organization_id into orgid from app_users where id = auth.uid();
  if orgid is null then raise exception 'not an organization admin'; end if;
  if p_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Color must be a #RRGGBB hex value'; end if;
  update organizations set brand_color = upper(p_color), theme_locked = false where id = orgid;
end;
$$;
grant execute on function set_org_theme(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Company logo per organization (a URL). Set by the super admin on the org's
--    behalf. Optional — pages fall back to the default mark when it's empty.
-- ---------------------------------------------------------------------------
alter table organizations add column if not exists logo_url text;

-- Super admin sets branding (color and/or logo) for any organization.
create or replace function set_org_branding(p_org uuid, p_color text default null, p_logo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'not authorized'; end if;
  if p_color is not null and p_color <> '' and p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'Color must be a #RRGGBB hex value';
  end if;
  update organizations set
    brand_color = case when p_color is null then brand_color
                       when p_color = ''    then null
                       else upper(p_color) end,
    logo_url    = case when p_logo  is null then logo_url
                       when p_logo  = ''    then null
                       else p_logo end
  where id = p_org;
end;
$$;
grant execute on function set_org_branding(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Surface logo_url where the frontend reads org data.
-- ---------------------------------------------------------------------------
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
               'position', st.position, 'siteId', st.assigned_site_id) order by st.full_name)
      from staff st where st.organization_id = org_row.id and st.active), '[]'::jsonb)
  );
end;
$$;
grant execute on function clock_in_context(text) to anon, authenticated;

create or replace function list_organizations()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'not authorized'; end if;
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', o.id, 'name', o.name, 'slug', o.slug, 'plan', o.plan, 'status', o.status,
        'brand_color', o.brand_color, 'logo_url', o.logo_url, 'theme_locked', o.theme_locked,
        'report_email', o.report_email, 'report_enabled', o.report_enabled, 'created_at', o.created_at,
        'admin_count', (select count(*) from app_users au where au.organization_id = o.id),
        'admins', coalesce((
          select jsonb_agg(jsonb_build_object('email', au.email, 'role', au.role) order by au.created_at)
          from app_users au where au.organization_id = o.id
        ), '[]'::jsonb)
      ) order by o.created_at desc
    )
    from organizations o
  ), '[]'::jsonb);
end;
$$;
grant execute on function list_organizations() to authenticated;

-- my_org() already returns to_jsonb(o), so it now includes logo_url automatically.
