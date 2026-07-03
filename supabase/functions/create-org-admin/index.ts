// ClockPoint — Edge Function: create-org-admin
// Super-admin-only management of organization admin logins. One function, several
// actions (chosen by body.action):
//   create (default) : add an admin to an org (max 5)   {orgId,email,password,role}
//   reset_password   : set a new password               {userId,password}
//   set_role         : change an admin's role           {userId,role}
//   set_email        : change an admin's email          {userId,email}
//   delete           : remove an admin login            {userId}
// Runs with the service-role key, but only after verifying the caller is a
// registered super admin. Deploy via the dashboard with "Verify JWT" OFF.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MAX_ADMINS = 5;
const ROLES = ["owner", "admin", "viewer"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1. Verify the caller is a platform (super) admin.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Missing Authorization token" }, 401);
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) return json({ error: "Invalid session" }, 401);
  const { data: pa } = await admin
    .from("platform_admins").select("user_id").eq("user_id", userData.user.id).maybeSingle();
  if (!pa) return json({ error: "Not authorized (super admin only)" }, 403);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  const action = body.action || "create";

  // Helper: the target must be an existing org admin (never a platform admin).
  async function requireAdmin(userId: string) {
    if (!userId) return null;
    const { data } = await admin.from("app_users").select("id, organization_id, email").eq("id", userId).maybeSingle();
    return data;
  }

  // ---- management actions ----
  if (action === "reset_password") {
    const target = await requireAdmin(body.userId);
    if (!target) return json({ error: "Admin not found" }, 404);
    const password = body.password ?? "";
    if (password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);
    const { error } = await admin.auth.admin.updateUserById(target.id, { password });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  if (action === "set_role") {
    const target = await requireAdmin(body.userId);
    if (!target) return json({ error: "Admin not found" }, 404);
    if (!ROLES.includes(body.role)) return json({ error: "Invalid role" }, 400);
    const { error } = await admin.from("app_users").update({ role: body.role }).eq("id", target.id);
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  if (action === "set_email") {
    const target = await requireAdmin(body.userId);
    if (!target) return json({ error: "Admin not found" }, 404);
    const email = (body.email ?? "").trim().toLowerCase();
    if (!email || !email.includes("@")) return json({ error: "A valid email is required" }, 400);
    const { error: e1 } = await admin.auth.admin.updateUserById(target.id, { email, email_confirm: true });
    if (e1) return json({ error: e1.message }, 400);
    await admin.from("app_users").update({ email }).eq("id", target.id);
    return json({ ok: true, admin: { email } });
  }

  if (action === "delete") {
    const target = await requireAdmin(body.userId);
    if (!target) return json({ error: "Admin not found" }, 404);
    const { error } = await admin.auth.admin.deleteUser(target.id); // cascades app_users row
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  // ---- default: create a new admin ----
  const orgId = (body.orgId ?? "").trim();
  const email = (body.email ?? "").trim().toLowerCase();
  const password = body.password ?? "";
  const role = ROLES.includes(body.role) ? body.role : "admin";

  if (!orgId) return json({ error: "orgId is required" }, 400);
  if (!email || !email.includes("@")) return json({ error: "A valid admin email is required" }, 400);
  if (!password || password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);

  const { data: org, error: orgErr } = await admin
    .from("organizations").select("id, name").eq("id", orgId).maybeSingle();
  if (orgErr || !org) return json({ error: "Organization not found" }, 404);

  const { count } = await admin
    .from("app_users").select("id", { count: "exact", head: true }).eq("organization_id", orgId);
  if ((count ?? 0) >= MAX_ADMINS) {
    return json({ error: `This organization already has the maximum of ${MAX_ADMINS} admins` }, 400);
  }

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
  });
  if (createErr) return json({ error: "Could not create admin user: " + createErr.message }, 400);

  const { error: linkErr } = await admin
    .from("app_users").insert({ id: created.user.id, organization_id: orgId, email, role });
  if (linkErr) {
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: "Could not link admin: " + linkErr.message }, 400);
  }

  return json({ ok: true, organization: { id: org.id, name: org.name }, admin: { email, role } });
});
