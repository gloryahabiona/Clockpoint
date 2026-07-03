-- ============================================================================
-- ClockPoint — Feature additions #3
--   * list_organizations() now returns each admin's user id, so the super admin
--     console can edit / reset / remove individual admins.
-- Run in the SQL Editor after the earlier SQL files. Safe to re-run.
-- ============================================================================

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
          select jsonb_agg(jsonb_build_object('id', au.id, 'email', au.email, 'role', au.role) order by au.created_at)
          from app_users au where au.organization_id = o.id
        ), '[]'::jsonb)
      ) order by o.created_at desc
    )
    from organizations o
  ), '[]'::jsonb);
end;
$$;
grant execute on function list_organizations() to authenticated;
