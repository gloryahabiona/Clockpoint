# ClockPoint — Super admin login & onboarding (setup)

The super admin signs in, **creates organizations**, then **adds admin logins to
each organization** (up to 5 per org). Frontend stays on GitHub Pages; the one
privileged step (creating a login for someone else) runs in a Supabase Edge
Function.

> **Key point that fixes the "free slots used up" problem:** the super admin does
> **NOT** own an organization and never uses a slot. There are exactly **2 free
> organization slots** on the whole platform; the first two orgs you create can be
> Free, and every org after that must be Paid. If you hit "no free slots" with no
> real orgs yet, you have leftover test orgs — clear them in step 0.

---

## 0. Reset leftover test data (do this once)
Earlier setup examples created a throwaway `ABCompany` organization, which ate
your free slots. Clear all test orgs so you start clean (this also removes any
test staff/sites/admins linked to them — safe while you have no real data; it
does **not** touch your super-admin account):

```sql
delete from organizations;   -- frees both slots; cascades to test app_users/staff/sites
```

## 1. Run the schema
In **SQL Editor**, run [`schema.sql`](schema.sql) (if not already), then
[`auth-schema.sql`](auth-schema.sql). Both are safe to re-run — do this again now
since the auth functions changed (org creation, slot status, 5-admin limit).

## 2. Make yourself the super admin (no organization needed)
1. **Authentication → Users → Add user** → your email + a password → tick
   "Auto confirm" → create. Copy your **User UID**.
2. **SQL Editor**:
   ```sql
   insert into platform_admins (user_id) values ('<YOUR_USER_UID>')
   on conflict do nothing;
   ```
   That's all the super admin needs — no `organizations` row, no `app_users` row.

## 3. Deploy the create-org-admin function
1. **Edge Functions → Create a function**, name it exactly **`create-org-admin`**.
2. Paste [`functions/create-org-admin/index.ts`](functions/create-org-admin/index.ts).
3. Turn **OFF “Verify JWT”** for the function (it verifies the caller itself, and
   this lets the browser's CORS preflight through).
4. Deploy. No secrets to set.

## 4. Use it
Open **https://gloryahabiona.github.io/Clockpoint/login.html** and sign in as the
super admin. In the console:
- **Step 1 — Create an organization:** type a name, pick Free/Paid (Free auto-
  disables once both slots are used), click **Create organization**.
- **Step 2 — Add admins:** on the org's card click **+ Add admin**, enter the
  admin's email + an initial password, pick a role, **Create admin login**. Repeat
  for up to 5 admins per org.
- Each admin can now sign in at the same login page and lands on their (stub)
  admin page. Their full staff/sites/log dashboard is the next build.

---

### The free / paid model in one line
2 free org slots total → first two orgs Free, the rest Paid. Moving an org to Paid
frees a slot. The console always shows "X / 2 free slots used" so it's never a
guess. Enforced in the database, so it holds even outside the UI.

### Troubleshooting
- **"No free slots left"** with few orgs → you still have leftover free orgs; re-run
  step 0, or create the org as **Paid**.
- **"Not authorized (super admin only)"** → step 2 wasn't done for the logged-in user.
- **CORS / preflight error** → "Verify JWT" is still ON for the function (step 3.3).
- **"maximum of 5 admins"** → that org is full; remove one or use another org.
