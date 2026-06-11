# ClockPoint — Super admin login & onboarding (setup)

This adds: a **login page**, a **super-admin console** that creates organizations
and their admin logins, and a landing page for org admins. Frontend stays on
GitHub Pages; the privileged "create a user" step runs in one Supabase Edge
Function.

Do these four steps once.

---

## 1. Run the auth schema
Supabase → **SQL Editor** → New query → paste all of
[`auth-schema.sql`](auth-schema.sql) → **Run**.
(Adds `platform_admins`, `whoami()`, `list_organizations()`, `set_org_plan()`.)

> If you haven't run [`schema.sql`](schema.sql) yet, run that first.

## 2. Make yourself the super admin
1. **Authentication → Users → Add user** → enter your email + a password →
   tick "Auto confirm" → create. Copy your new **User UID**.
2. **SQL Editor**, run (paste your UID):
   ```sql
   insert into platform_admins (user_id) values ('<YOUR_USER_UID>');
   ```

## 3. Deploy the create-org-admin function
1. Supabase → **Edge Functions** → **Create a function** (or "Deploy a new function"
   → via Editor). Name it exactly **`create-org-admin`**.
2. Paste the contents of
   [`functions/create-org-admin/index.ts`](functions/create-org-admin/index.ts).
3. **Important:** turn **OFF “Verify JWT”** for this function (a toggle in the
   function's settings). The function verifies the caller itself, and this lets
   the browser's CORS preflight through.
4. Deploy. No secrets to set — `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
   are provided to the function automatically.

## 4. Use it
Open your live login page:

**https://gloryahabiona.github.io/Clockpoint/login.html**

- Sign in with the super-admin email/password from step 2.
- You'll land on the **console**. Fill in an organization name, the admin's
  email, and an initial password → **Create organization & admin**.
- That admin can now sign in at the same login page and lands on their (stub)
  admin page. Building out their staff/sites/log dashboard is the next step.

---

### How the security works
- The **anon key** in `config.js` is public-safe — Row-Level Security limits it to
  reading active staff/sites and calling the clock-in function.
- Creating a login for someone else needs the **service-role key**, which lives
  ONLY inside the Edge Function on Supabase's servers — never in the browser.
- The function refuses to do anything unless the caller is in `platform_admins`,
  so only you can onboard organizations.
- Each org admin is scoped to their own `organization_id`; RLS means they can
  never see another company's data.

### Troubleshooting
- **"Not authorized (super admin only)"** → step 2 wasn't done for the logged-in
  user, or you're signed in as a different account.
- **CORS / preflight error in the console** → "Verify JWT" is still ON for the
  function (step 3.3).
- **"Both free slots are in use"** → the 2-free-org rule fired; create the org as
  `paid`, or move an existing free org to paid first.
