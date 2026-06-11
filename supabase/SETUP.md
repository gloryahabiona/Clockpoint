# ClockPoint — Stage A backend setup (Supabase)

This turns the demo into a **real, shared system**: one central database, a real
admin login, server-stamped time, and a server-side geofence check. The frontend
can stay on GitHub Pages — it just talks to Supabase.

You only need to do steps 1–6 once. After that, tell me your **Project URL** and
**anon key** (step 5) and I'll wire the frontend to it.

---

## 1. Create a Supabase project
1. Go to <https://supabase.com> → sign in (GitHub login works) → **New project**.
2. Name it `clockpoint`, choose a region close to you (e.g. London/Frankfurt for
   Nigeria), set a database password (save it somewhere safe), and create it.
3. Wait ~2 minutes for it to provision. **Free tier is fine to start.**

## 2. Create the database schema
1. In the project, open **SQL Editor** → **New query**.
2. Open [`schema.sql`](schema.sql) from this folder, copy **all** of it, paste, **Run**.
3. You should see "Success. No rows returned." That created every table, the
   security rules, the append-only guard, and the server-side clock-in function.

## 3. Create a storage bucket for selfies
1. Go to **Storage** → **New bucket** → name it `selfies` → keep it **Private** → create.
2. Open the bucket's **Policies** → add a policy:
   - Allow **INSERT** (upload) for the `anon` role (staff screen is not logged in).
   - Allow **SELECT** for `authenticated` (admins view photos via signed URLs).
   (I can give you exact policy SQL when we wire this up.)

## 4. Create your organization + admin login
Run this in the SQL Editor, editing the email/name to yours:

```sql
-- a) create your organization, capture its id
insert into organizations (name, plan) values ('ABCompany', 'free')
returning id;   -- copy this uuid for step (c)

-- b) create your admin auth user:
--    Authentication -> Users -> "Add user" -> email + password (confirm it).
--    Then copy that user's UID from the Users list.

-- c) link the auth user to your org as the owner
--    (replace both uuids with the ones from above)
insert into app_users (id, organization_id, email, role)
values ('<AUTH_USER_UID>', '<ORG_ID>', 'you@example.com', 'owner');
```

## 5. Get your project keys (this is what I need next)
**Project Settings → API**, copy:
- **Project URL** — e.g. `https://abcdxyz.supabase.co`
- **anon public** key — a long JWT starting with `eyJ...`

These two are safe to put in client-side code (the anon key only grants what the
Row-Level Security rules allow). **Do not** share the `service_role` key.

## 6. Seed your real sites & staff
Once you log in to the (wired-up) admin dashboard you'll add these through the UI.
To pre-load a couple for testing, run in SQL Editor (using your `<ORG_ID>`):

```sql
insert into sites (organization_id, name, center_lat, center_lng, radius_m)
values ('<ORG_ID>', 'Head Office', 6.6018, 3.3515, 120);

insert into staff (organization_id, full_name, position, assigned_site_id)
select '<ORG_ID>', 'Test Staff', 'Security', id from sites
where organization_id = '<ORG_ID>' limit 1;
```

---

## What happens after this
Once you give me the **Project URL** + **anon key**, I will:
1. Add a small `config.js` (holds those two values) and load `supabase-js` in the page.
2. Swap the demo's `localStorage` calls for Supabase:
   - staff picker & site list → read from the database
   - **Clock In** → calls `submit_clock_event()` (server time + server geofence)
   - selfie → uploaded to the `selfies` bucket, reference stored on the event
   - admin **Log** → reads the shared `clock_events`, behind a real login
   - admin **Sites/Staff** → real CRUD against the database
3. Keep the export and the whole look-and-feel exactly as they are.

The result: staff clock in from their own phones, and **you see every record in
one shared log** — with a timestamp and geofence verdict they can't fake.

## Security notes for the MVP
- The staff clock-in screen is intentionally unauthenticated (staff identify by
  picking their name), matching the spec's MVP. The `anon` role can only read the
  active staff/site lists and call `submit_clock_event` — it cannot read the log.
- The admin dashboard requires a real Supabase login (no more demo PINs).
- Row-Level Security means once you sell to other companies, one org can never
  see another's data — enforced by the database, not just the app.
