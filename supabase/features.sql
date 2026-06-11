-- ============================================================================
-- ClockPoint — Feature additions: org slugs, per-org brand color (set once),
-- and weekly-report settings. Run in the SQL Editor AFTER auth-schema.sql.
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New columns on organizations
-- ---------------------------------------------------------------------------
alter table organizations add column if not exists slug           text;
alter table organizations add column if not exists brand_color    text;          -- #RRGGBB, set once by the org admin
alter table organizations add column if not exists theme_locked   boolean not null default false;
alter table organizations add column if not exists report_email   text;          -- weekly export recipient
alter table organizations add column if not exists report_enabled boolean not null default false;

-- Backfill slugs for existing orgs, then guarantee uniqueness.
update organizations
   set slug = nullif(trim(both '-' from regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g')), '')
 where slug is null;
update organizations set slug = 'org' where slug is null or slug = '';
update organizations o set slug = o.slug || '-' || left(o.id::text, 4)
 where (select count(*) from organizations o2 where o2.slug = o.slug) > 1;
create unique index if not exists organizations_slug_idx on organizations(slug);

-- ---------------------------------------------------------------------------
-- 2. create_organization() — now also assigns a unique slug from the name.
-- ---------------------------------------------------------------------------
create or replace function create_organization(p_name text, p_plan text default 'free')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_plan text; free_used integer; v_slug text; v_base text; i integer := 1;
  new_org organizations%rowtype;
begin
  if not is_platform_admin() then raise exception 'not authorized'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Organization name is required'; end if;
  v_plan := case when p_plan = 'paid' then 'paid' else 'free' end;

  select count(*) into free_used from organizations where plan = 'free' and status = 'active';
  if v_plan = 'free' and free_used >= 2 then
    raise exception 'No free slots left (2 of 2 used). Create this organization as Paid, or move an existing free org to Paid first.';
  end if;

  v_base := nullif(trim(both '-' from regexp_replace(lower(trim(p_name)), '[^a-z0-9]+', '-', 'g')), '');
  v_base := coalesce(v_base, 'org');
  v_slug := v_base;
  while exists(select 1 from organizations where slug = v_slug) loop
    v_slug := v_base || '-' || i; i := i + 1;
  end loop;

  insert into organizations (name, plan, slug) values (trim(p_name), v_plan, v_slug)
  returning * into new_org;
  return to_jsonb(new_org);
end;
$$;
grant execute on function create_organization(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. clock_in_context() — accept slug OR uuid, and return the brand color so
--    the staff screen themes itself. (Replaces the uuid-only version.)
-- ---------------------------------------------------------------------------
drop function if exists clock_in_context(uuid);
create or replace function clock_in_context(p_org text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare org_row organizations%rowtype;
begin
  select * into org_row from organizations
   where (slug = p_org or id::text = p_org) and status = 'active' limit 1;
  if not found then return jsonb_build_object('error', 'Organization not found'); end if;
  return jsonb_build_object(
    'org', jsonb_build_object('id', org_row.id, 'name', org_row.name,
             'slug', org_row.slug, 'brand_color', org_row.brand_color),
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

-- ---------------------------------------------------------------------------
-- 4. my_org() — the org admin reads their own org (slug, color, report config).
-- ---------------------------------------------------------------------------
create or replace function my_org()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(o)
  from organizations o
  join app_users a on a.organization_id = o.id
  where a.id = auth.uid()
$$;
grant execute on function my_org() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. set_org_theme() — org admin sets the brand color ONCE (then locked).
-- ---------------------------------------------------------------------------
create or replace function set_org_theme(p_color text)
returns void language plpgsql security definer set search_path = public as $$
declare orgid uuid; locked boolean;
begin
  select organization_id into orgid from app_users where id = auth.uid();
  if orgid is null then raise exception 'not an organization admin'; end if;
  if p_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Color must be a #RRGGBB hex value'; end if;
  select theme_locked into locked from organizations where id = orgid;
  if locked then raise exception 'The brand color is already set and can only be chosen once'; end if;
  update organizations set brand_color = upper(p_color), theme_locked = true where id = orgid;
end;
$$;
grant execute on function set_org_theme(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. set_report_settings() — org admin configures the weekly export email.
-- ---------------------------------------------------------------------------
create or replace function set_report_settings(p_email text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare orgid uuid;
begin
  select organization_id into orgid from app_users where id = auth.uid();
  if orgid is null then raise exception 'not an organization admin'; end if;
  if p_enabled and coalesce(p_email,'') = '' then raise exception 'Enter a recipient email to enable the weekly report'; end if;
  if coalesce(p_email,'') <> '' and p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email'; end if;
  update organizations set report_email = nullif(trim(p_email),''), report_enabled = p_enabled where id = orgid;
end;
$$;
grant execute on function set_report_settings(text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. list_organizations() — include slug, color and report config for the console.
-- ---------------------------------------------------------------------------
create or replace function list_organizations()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'not authorized'; end if;
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', o.id, 'name', o.name, 'slug', o.slug, 'plan', o.plan, 'status', o.status,
        'brand_color', o.brand_color, 'theme_locked', o.theme_locked,
        'report_email', o.report_email, 'report_enabled', o.report_enabled,
        'created_at', o.created_at,
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

-- ---------------------------------------------------------------------------
-- 8. Weekly report data (used by the weekly-report Edge Function).
--    Returns last-7-days events for every org that has the report enabled.
--    SECURITY DEFINER + restricted: only callable with the service role.
-- ---------------------------------------------------------------------------
create or replace function weekly_report_data()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(org), '[]'::jsonb) from (
    select jsonb_build_object(
      'org_id', o.id, 'org_name', o.name, 'email', o.report_email,
      'events', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', e.id, 'name', e.staff_name, 'position', e.position, 'site', e.site_name,
          'type', e.event_type, 'server_time', e.server_time, 'distance_m', e.distance_m,
          'within_geofence', e.within_geofence, 'lat', e.lat, 'lng', e.lng, 'gps_accuracy_m', e.gps_accuracy_m
        ) order by e.server_time desc)
        from clock_events e
        where e.organization_id = o.id and e.server_time >= now() - interval '7 days'
      ), '[]'::jsonb)
    ) as org
    from organizations o
    where o.report_enabled and o.report_email is not null and o.status = 'active'
  ) t;
$$;
revoke all on function weekly_report_data() from anon, authenticated;
-- (service_role retains execute; the Edge Function calls it with the service key.)
