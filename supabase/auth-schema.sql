-- ============================================================================
-- ClockPoint — Auth additions: super admin identity + console helpers
-- Run this in the Supabase SQL Editor AFTER schema.sql. Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Platform (super) admins — the identity that spans all organizations.
--    NOTE: the super admin does NOT own an organization. They are listed here
--    only, and never consume a free/paid slot.
-- ---------------------------------------------------------------------------
create table if not exists platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table platform_admins enable row level security;

drop policy if exists platform_admins_self on platform_admins;
create policy platform_admins_self on platform_admins for select to authenticated
  using (user_id = auth.uid());

create or replace function is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from platform_admins where user_id = auth.uid())
$$;

-- ---------------------------------------------------------------------------
-- 2. whoami() — the frontend calls this right after login to route the user.
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
-- 3. Free-slot status — so the console can SHOW how many free slots remain.
--    The limit is 2 (matches the enforce_free_slots() trigger in schema.sql).
-- ---------------------------------------------------------------------------
create or replace function free_slot_status()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'used',  (select count(*) from organizations where plan = 'free' and status = 'active'),
    'limit', 2
  )
$$;
grant execute on function free_slot_status() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. create_organization() — super admin creates an ORG (no admin yet).
--    Free is allowed only while under the 2-slot limit; otherwise use paid.
--    (No service-role needed — runs as definer after an is_platform_admin check.)
-- ---------------------------------------------------------------------------
create or replace function create_organization(p_name text, p_plan text default 'free')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_plan    text;
  free_used integer;
  new_org   organizations%rowtype;
begin
  if not is_platform_admin() then raise exception 'not authorized'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Organization name is required'; end if;

  v_plan := case when p_plan = 'paid' then 'paid' else 'free' end;

  select count(*) into free_used from organizations where plan = 'free' and status = 'active';
  if v_plan = 'free' and free_used >= 2 then
    raise exception 'No free slots left (2 of 2 used). Create this organization as Paid, or move an existing free org to Paid first.';
  end if;

  insert into organizations (name, plan) values (trim(p_name), v_plan)
  returning * into new_org;
  return to_jsonb(new_org);
end;
$$;
grant execute on function create_organization(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. list_organizations() — data for the super admin console.
-- ---------------------------------------------------------------------------
create or replace function list_organizations()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'not authorized'; end if;
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', o.id, 'name', o.name, 'plan', o.plan, 'status', o.status,
        'api_enabled', o.api_enabled, 'created_at', o.created_at,
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
-- 6. set_org_plan() — flip an org free<->paid from the console.
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

-- ---------------------------------------------------------------------------
-- 7. Max 5 admin logins per organization.
-- ---------------------------------------------------------------------------
create or replace function enforce_admin_limit()
returns trigger language plpgsql as $$
begin
  if (select count(*) from app_users where organization_id = new.organization_id) >= 5 then
    raise exception 'This organization already has the maximum of 5 admins';
  end if;
  return new;
end;
$$;

drop trigger if exists app_users_admin_limit on app_users;
create trigger app_users_admin_limit before insert on app_users
  for each row execute function enforce_admin_limit();
