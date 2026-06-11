// ClockPoint — Edge Function: create-org-admin
// The super admin calls this to onboard an organization and create its admin
// login in one step. It runs with the service-role key (so it can create auth
// users), but it FIRST verifies the caller is a registered platform (super)
// admin, so only you can use it.
//
// Deploy via the Supabase dashboard (Edge Functions -> create "create-org-admin"
// -> paste this -> turn OFF "Verify JWT" because we verify the caller ourselves).
// See supabase/AUTH-SETUP.md.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Admin client (service role) — bypasses RLS, can create users.
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1. Verify the caller's token and that they are a platform (super) admin.
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Missing Authorization token" }, 401);

  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) return json({ error: "Invalid session" }, 401);
  const caller = userData.user;

  const { data: pa } = await admin
    .from("platform_admins").select("user_id").eq("user_id", caller.id).maybeSingle();
  if (!pa) return json({ error: "Not authorized (super admin only)" }, 403);

  // 2. Validate input.
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  const orgName = (body.orgName ?? "").trim();
  const email = (body.email ?? "").trim().toLowerCase();
  const password = body.password ?? "";
  const plan = body.plan === "paid" ? "paid" : "free";
  const role = ["owner", "admin", "viewer"].includes(body.role) ? body.role : "owner";

  if (!orgName) return json({ error: "Organization name is required" }, 400);
  if (!email || !email.includes("@")) return json({ error: "A valid admin email is required" }, 400);
  if (!password || password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);

  // 3. Create the organization (free-slot rule enforced by DB trigger).
  const { data: org, error: orgErr } = await admin
    .from("organizations").insert({ name: orgName, plan }).select().single();
  if (orgErr) return json({ error: orgErr.message }, 400);

  // 4. Create the admin auth user (confirmed, so they can log in immediately).
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
  });
  if (createErr) {
    await admin.from("organizations").delete().eq("id", org.id); // roll back the org
    return json({ error: "Could not create admin user: " + createErr.message }, 400);
  }

  // 5. Link the user to the org as an admin.
  const { error: linkErr } = await admin
    .from("app_users").insert({ id: created.user.id, organization_id: org.id, email, role });
  if (linkErr) {
    await admin.auth.admin.deleteUser(created.user.id);
    await admin.from("organizations").delete().eq("id", org.id);
    return json({ error: "Could not link admin: " + linkErr.message }, 400);
  }

  return json({
    ok: true,
    organization: { id: org.id, name: org.name, plan: org.plan },
    admin: { email, role },
  });
});
