// ClockPoint — Edge Function: create-org-admin
// Adds an admin login to an EXISTING organization (max 5 per org). The super
// admin creates the organization first (via the create_organization RPC), then
// calls this to add each admin. Runs with the service-role key (needed to create
// auth users) but only after verifying the caller is a registered super admin.
//
// Deploy via the Supabase dashboard (Edge Functions -> "create-org-admin" ->
// paste this -> turn OFF "Verify JWT"). See supabase/AUTH-SETUP.md.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MAX_ADMINS = 5;

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

  // 2. Validate input.
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  const orgId = (body.orgId ?? "").trim();
  const email = (body.email ?? "").trim().toLowerCase();
  const password = body.password ?? "";
  const role = ["owner", "admin", "viewer"].includes(body.role) ? body.role : "admin";

  if (!orgId) return json({ error: "orgId is required" }, 400);
  if (!email || !email.includes("@")) return json({ error: "A valid admin email is required" }, 400);
  if (!password || password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);

  // 3. Org must exist; enforce the 5-admin cap up front.
  const { data: org, error: orgErr } = await admin
    .from("organizations").select("id, name").eq("id", orgId).maybeSingle();
  if (orgErr || !org) return json({ error: "Organization not found" }, 404);

  const { count } = await admin
    .from("app_users").select("id", { count: "exact", head: true }).eq("organization_id", orgId);
  if ((count ?? 0) >= MAX_ADMINS) {
    return json({ error: `This organization already has the maximum of ${MAX_ADMINS} admins` }, 400);
  }

  // 4. Create the admin auth user (confirmed, can log in immediately).
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
  });
  if (createErr) return json({ error: "Could not create admin user: " + createErr.message }, 400);

  // 5. Link to the org (the DB trigger is the backstop for the 5-admin cap).
  const { error: linkErr } = await admin
    .from("app_users").insert({ id: created.user.id, organization_id: orgId, email, role });
  if (linkErr) {
    await admin.auth.admin.deleteUser(created.user.id); // roll back the orphan user
    return json({ error: "Could not link admin: " + linkErr.message }, 400);
  }

  return json({ ok: true, organization: { id: org.id, name: org.name }, admin: { email, role } });
});
