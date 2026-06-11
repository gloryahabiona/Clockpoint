-- ============================================================================
-- ClockPoint — Auth additions: super admin identity + console helpers
-- Run this in the Supabase SQL Editor AFTER schema.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Platform (super) admins — the identity that spans all organizations.
--    A user listed here can onboard organizations and create their admins.
-- ---------------------------------------------------------------------------
create table if not exists platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table platform_admins enable row level security;

-- A user may read their OWN platform_admins row (to discover they are super).
drop policy if exists platform_admins_self on platform_admins;
create policy platform_admins_self on platform_admins for select to authenticated
  using (user_id = auth.uid());

create or replace function is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from platform_admins where user_id = auth.uid())
$$;

-- ---------------------------------------------------------------------------
-- 2. whoami() — the frontend calls this right after login to route the user.
--    Returns: { user_id, is_super, app_user: {organization_id, role, ...} }
-- ---------------------------------------------------------------------------
create or replace function whoami()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id',  auth.uid(),
    'is_super', exists(select 1 from platform_admins where user_id = auth.uid()),
    'app_user', (select to_jsonb(a) from app_users a where a.id = auth.uid())
  )
$$;
grant execute on function whoami() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. list_organizations() — data for the super admin console (orgs + admins).
--    Only platform admins may call it.
-- ---------------------------------------------------------------------------
create or replace function list_organizations()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then
    raise exception 'not authorized';
  end if;
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', o.id, 'name', o.name, 'plan', o.plan, 'status', o.status,
        'api_enabled', o.api_enabled, 'created_at', o.created_at,
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
-- 4. set_org_plan() — let the super admin flip an org free<->paid from the console.
-- ---------------------------------------------------------------------------
create or replace function set_org_plan(p_org_id uuid, p_plan text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'not authorized'; end if;
  if p_plan not in ('free','paid') then raise exception 'plan must be free or paid'; end if;
  update organizations set plan = p_plan where id = p_org_id;  -- free-slot trigger still applies
end;
$$;
grant execute on function set_org_plan(uuid, text) to authenticated;
