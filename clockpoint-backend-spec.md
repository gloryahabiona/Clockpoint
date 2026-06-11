# ClockPoint — Production Backend Specification

A developer-ready spec for turning the clock-in prototype into a deployable staff attendance-audit system. The prototype already defines the look, the capture flow, the geofence logic, and the Excel format; this document describes what has to exist on the server side to make it real, trustworthy, and ownable.

---

## 1. What the backend must guarantee

This is fundamentally an **audit tool**, so three properties matter more than features:

1. **Trustworthy time** — the timestamp on every clock-in is set by the server when the request arrives, never taken from the phone. Staff can change a phone clock; they cannot change the server's.
2. **Tamper-evident records** — clock events are append-only. Once written they cannot be edited or silently deleted. Corrections happen by adding a new annotated record, not by overwriting history.
3. **Controlled access** — staff can only submit; only authenticated admins can read the log; only an owner can manage other admins and sites.

Everything below serves those three properties first and convenience second.

---

## 2. Architecture

Four moving parts:

- **Client (PWA)** — the existing web app, installed to the home screen. Captures name/position/site/GPS/selfie and posts them. It does *not* decide whether a clock-in is valid.
- **API** — receives clock events, stamps the time, runs the geofence check, stores the photo, and writes the record. Serves the admin log and exports.
- **Database** — relational (Postgres recommended) for staff, sites, admins, and the append-only event log.
- **Object storage** — for the selfies (photos do not belong in the database as base64; store the file, keep a reference).

```
[ Staff PWA ] --HTTPS--> [ API ] --> [ Postgres ]  (records, sites, users)
                              \-----> [ Object storage ] (selfie images)
[ Admin dashboard ] --HTTPS--> [ API ] --> reads log, generates Excel
```

---

## 3. Recommended stack

There are two sensible paths depending on how far you want to take this.

**Path A — Fast MVP (recommended to start): Supabase.**
Supabase gives you Postgres, authentication, file storage, row-level security, and auto-generated APIs in one place. Because it is Postgres underneath, you genuinely own the data and can export or self-host it later — no lock-in into a proprietary data model. This is the quickest route to a working, secure system, and it scales comfortably for hundreds of staff.

**Path B — Full control / productizing: custom API.**
A Node (Express/NestJS) or Python (FastAPI/Django) service in front of Postgres, with an S3-compatible bucket for photos, hosted on a VPS or a cloud provider. More work, but maximum control over logic, billing, and multi-tenancy if you sell it to other companies.

A practical plan: build the MVP on Supabase to validate quickly; migrate the heavier business logic to a custom API later *if and when* you commercialize. The database schema below works for either path.

---

## 4. Data model

Designed so it works for your own staff today and can become multi-company (multi-tenant) later by way of the `organization_id` column.

**organizations** — one row per company (only relevant once you sell to others)

| column | type | notes |
|---|---|---|
| id | uuid (PK) | |
| name | text | |
| created_at | timestamptz | |

**app_users** — people who log in to the admin side

| column | type | notes |
|---|---|---|
| id | uuid (PK) | |
| organization_id | uuid (FK) | |
| email | text (unique) | login handled by the auth provider |
| role | text | `owner` \| `admin` \| `viewer` |
| created_at | timestamptz | |

**staff** — the roster (now a managed list the admin maintains; on Clock In a staff member picks their name and the rest is filled from here)

| column | type | notes |
|---|---|---|
| id | uuid (PK) | |
| organization_id | uuid (FK) | |
| full_name | text | |
| position | text | references a value from `positions` |
| assigned_site_id | uuid (FK sites) | the only site this person may clock in at |
| employee_code | text | optional |
| reference_photo_url | text | optional; enables face-match later |
| active | boolean | |
| created_at | timestamptz | |

The `assigned_site_id` is the key field for the new requirement: a staff member's clock-in is checked against this site only, so they cannot clock in at a location they aren't assigned to. Reassigning someone after a move is just an update to this column. (If you later need people who rotate across sites, change this to a `staff_sites` join table; one assignment per person covers the common case.)

**positions** — the editable list of roles (so admins aren't stuck with hardcoded ones)

| column | type | notes |
|---|---|---|
| id | uuid (PK) | |
| organization_id | uuid (FK) | |
| name | text | e.g. Security, Warehouse Manager |
| created_at | timestamptz | |

**sites** — the geofence definitions (what the Sites tab manages)

| column | type | notes |
|---|---|---|
| id | uuid (PK) | |
| organization_id | uuid (FK) | |
| name | text | |
| center_lat | double precision | |
| center_lng | double precision | |
| radius_m | integer | |
| active | boolean | |
| created_at | timestamptz | |

**clock_events** — the core append-only audit log

| column | type | notes |
|---|---|---|
| id | uuid (PK) | |
| organization_id | uuid (FK) | |
| staff_id | uuid (FK, nullable) | links to roster if used |
| staff_name | text | captured name (kept even if roster absent) |
| position | text | |
| site_id | uuid (FK, nullable) | |
| event_type | text | `IN` \| `OUT` |
| server_time | timestamptz | **set by the server — the source of truth** |
| device_time | timestamptz | what the phone reported (for comparison) |
| lat | double precision | |
| lng | double precision | |
| gps_accuracy_m | integer | |
| distance_m | integer | computed server-side |
| within_geofence | boolean | computed server-side |
| photo_url | text | reference to the stored selfie |
| device_info | jsonb | user agent, mock-location flag, etc. |
| created_at | timestamptz | |

**Integrity rule:** `clock_events` is append-only. Database permissions grant `INSERT` and `SELECT` but **not** `UPDATE` or `DELETE` to the application role. If a correction is ever needed, it is a new row referencing the original, made by an admin and itself logged.

---

## 5. Key API endpoints

| method | path | who | purpose |
|---|---|---|---|
| POST | `/auth/login` | admins | obtain session (provider-handled) |
| GET | `/sites` | staff + admin | list active sites for the picker |
| POST / PATCH / DELETE | `/sites` | admin | manage geofences |
| GET / POST | `/staff` | admin | manage roster |
| POST | `/clock-events` | staff | submit a clock-in (see flow below) |
| GET | `/clock-events?date=&site_id=&staff_id=` | admin | filtered log |
| GET | `/export?date=` | admin | download the daily `.xlsx` |
| GET / POST / DELETE | `/admins` | owner | manage other admins |

### The clock-in submission flow (the important one)

When `POST /clock-events` arrives with `{ staff_name, position, site_id, event_type, lat, lng, gps_accuracy_m, device_time, photo }`, the server:

1. Authenticates the request and resolves the organization.
2. **Generates `server_time = now()`** — ignores any client time except to store it as `device_time` for comparison.
3. Looks up the staff member, takes their **assigned site** (the client doesn't get to choose it), computes the Haversine distance to that site's centre, and sets `distance_m` and `within_geofence` (within if `distance_m <= radius_m`). The client's verdict is treated as a hint only. Because the site comes from the assignment, a staff member physically cannot clock in against a site they aren't assigned to.
4. Uploads the selfie to object storage and keeps the returned reference in `photo_url`.
5. Inserts one immutable row into `clock_events`.
6. Returns success plus the in/out-of-zone result.

The phone is never trusted to decide validity — it only supplies raw inputs.

---

## 6. Geofencing on the server

The math is identical to the prototype (Haversine distance vs. site radius); it simply runs in the API instead of the browser. Two refinements worth adding:

- **Accuracy-aware verdict.** A clock-in is only confidently in-zone if `distance_m <= radius_m` *and* `gps_accuracy_m` is below a threshold (e.g. 50 m). Poor-accuracy readings get marked "uncertain" for review rather than a hard yes/no.
- **Flag, don't block (at first).** Keep recording out-of-zone events with the flag set. For an audit tool, a recorded failed attempt is more valuable than a refusal that leaves no trace. A hard block can be a per-site option you switch on later.
- **Assignment-bound, not free choice.** The site checked is always the staff member's `assigned_site_id`, resolved server-side — never a site the client supplies. This is what enforces "a person can only clock in where they're assigned." Editing the assignment (a move) takes effect on their next clock-in with no app change.

---

## 7. Photo handling

Store selfies as files in object storage, not as base64 in the database. Keep them downscaled (the prototype already compresses to ~360 px JPEG, which is plenty for verification and keeps storage cheap). Serve them to admins via short-lived **signed URLs** so images aren't publicly reachable. Set a retention policy (see privacy below).

---

## 8. Authentication and roles

There are two levels of access: the **platform** level (you) and the **organization** level (each customer).

**Platform level**
- **super admin (you)** — sees all organizations, manages the free/paid slots, moves any organization between free and paid, issues API keys, and receives the "free slots full" notification. It needs no access to any organization's day-to-day attendance data, and it's good practice not to grant that by default.

**Organization level** (scoped to one company)
- **owner** — the customer's top admin; manages their own admins, sites, and staff.
- **admin** — views the log, exports, manages sites and staff.
- **viewer** — read-only access to the log and exports.

Staff submitting clock-ins do **not** need accounts in the MVP (they identify by name/roster). If you later want each staff member authenticated, add a lightweight staff login or per-site PIN.

Use **row-level security** so every query is automatically scoped to the requester's `organization_id`. This is what makes multi-company selling safe — one company can never see another's records, enforced at the database, not just the app. The super admin is the single identity that spans organizations, and even then only for management data (plans, slots, billing), not attendance records.

---

## 8a. Platform tenancy, plans & billing (the part you sell)

This is the layer that turns the tool into a product. It sits above the per-organization data and is owned entirely by the super admin. The same logic is demonstrated in the prototype's Organizations console; production enforces it server-side and ties it to real billing.

### The free-slot model
- The platform offers **2 free organization slots**. The first two organizations onboarded can run on the **free** plan.
- Once both free slots are occupied, any further organization must be on a **paid** plan to operate.
- The super admin can **move any organization from free to paid at any time**, which immediately frees a slot for another organization (and the reverse, if a free slot is available).
- The super admin is **notified when the free slots become full**, so they know the free tier is exhausted and new signups should convert to paid.

### Data model additions
Extend `organizations` and add two supporting tables:

**organizations** (extended)

| column | type | notes |
|---|---|---|
| plan | text | `free` \| `paid` |
| status | text | `active` \| `suspended` |
| free_slot | boolean | true while occupying one of the 2 free slots |
| api_enabled | boolean | paid feature toggle |

**plan_events** — audit trail of plan changes (who moved whom, when): `id`, `organization_id`, `from_plan`, `to_plan`, `changed_by` (super admin), `created_at`.

**api_keys** — for paid organizations integrating into their own systems: `id`, `organization_id`, `key_hash` (store a hash, never the raw key), `label`, `last_used_at`, `revoked`, `created_at`.

### Enforcing the slot rule
A single server-side check, run whenever an organization is created or its plan changes:

- `free_slots_used = count(organizations where plan='free' and status='active')`
- A new organization may take `plan='free'` only if `free_slots_used < 2`; otherwise it must be `paid`.
- Run this inside a transaction (or with a locking/uniqueness strategy) so two simultaneous signups can't both claim the last free slot.

### Notifying the super admin
When an action causes `free_slots_used` to reach 2, fire a notification (email and/or an in-dashboard banner — the prototype shows the banner). Keep it idempotent: notify on the transition to full, not on every later write.

### Billing for paid organizations
Integrate a payment provider rather than building billing yourself. In Nigeria, **Paystack** and **Flutterwave** are the common choices and support recurring/subscription billing; **Stripe** is the equivalent for selling internationally. The flow: the organization is set to `paid`; the provider handles the subscription and sends **webhooks** on payment success, failure, and cancellation; your server updates `organizations.status` from those webhooks (suspend on failed renewal, reactivate on payment). Trust only the provider's webhooks for payment state, never the client.

### API integration for customers
Paid organizations can be issued an **API key** (`api_enabled = true`) so they can pull their attendance data into their own HR/payroll systems:

- Authenticate API requests with the key as a bearer token, resolve it to an `organization_id`, and apply the same row-level scoping — a key can only ever read its own organization's data.
- Expose read endpoints such as `GET /api/v1/clock-events?date=` returning JSON, and optionally a webhook so the customer is notified of new clock-ins in real time.
- Rate-limit per key, record `last_used_at`, and let the customer's owner rotate or revoke keys.
- Gate it as a paid feature: disabled on free plans, enabled on paid.

---

## 9. The daily Excel export

Two options:

- **Client-side (already built):** the dashboard pulls the day's JSON and generates the `.xlsx` with SheetJS in the browser. Fine for modest volumes and the simplest to ship.
- **Server-side (recommended as you grow):** a `/export` endpoint queries the day's events and streams an `.xlsx` (libraries: `exceljs` for Node, `openpyxl` for Python). This handles large datasets, lets you embed photo thumbnails if wanted, and enables a **scheduled job** that emails the daily log to you automatically each evening — which fits the "daily log" goal nicely.

Columns mirror the prototype: Record ID, Date, Server Time, Name, Position, Action, Site, Distance to centre, Zone status, Latitude, Longitude, GPS accuracy, Map link, Photo link.

---

## 10. Security and privacy

You're capturing staff faces and locations, so treat this as sensitive personal data:

- HTTPS everywhere; signed URLs for photos; row-level security per organization.
- A clear **retention policy** — decide how long photos and location records are kept (e.g. 12 months) and delete on schedule.
- **Consent and notice** — staff should be told what's collected and why. In Nigeria this falls under the Nigeria Data Protection Act / NDPR; if you sell to others, each customer becomes a data controller with their own obligations. This is a flag, not legal advice — confirm specifics with a qualified advisor, especially before commercializing.
- Because you want to **own the data**, Postgres (self-hostable) plus your own object storage keeps you in control and lets you offer customers data export.

---

## 11. Anti-spoofing roadmap

Honest framing: server-side geofencing raises the bar but a determined user can fake GPS with mock-location apps. Layered defences, in rough order of effort:

1. **Server geofence + selfie** (MVP) — faking coordinates is easy; faking a live photo on-site is hard. The selfie is your strongest cheap defence.
2. **Mock-location detection** — Android exposes whether a location is mocked; capture and flag it in `device_info`.
3. **Device integrity attestation** — Play Integrity (Android) / App Attest (iOS) if you ship a native wrapper, to confirm the app and device aren't tampered.
4. **Anomaly checks** — same staff clocking in at two distant sites minutes apart, impossible travel speeds, repeated accuracy outliers.
5. **Selfie liveness / face match** — compare against the stored reference photo; add liveness detection. Higher effort, add only if abuse warrants it.

Don't build past step 1–2 until real usage shows you need to.

---

## 12. Build phases

**Phase 1 — MVP (make it real and trustworthy)**
Auth + roles; sites CRUD; clock-event capture with server timestamp, server geofence, and photo upload; admin log view with date filter; Excel export. This is the smallest thing that is genuinely an audit tool.

**Phase 2 — operational depth**
Staff roster; multi-admin management; dashboard filters by site/staff; scheduled daily export emailed to you; clock-out pairing to compute hours worked.

**Phase 3 — hardening and productizing**
Optional hard-block geofencing per site; mock-location and anomaly flags; the platform layer for selling (multi-tenant onboarding, the 2-free-slot rule with super-admin notification, paid plans wired to Paystack/Flutterwave/Stripe, and per-customer API keys); native app wrapper if app-store presence matters; face-match if needed.

---

## 13. Hosting and effort

- **Hosting:** Supabase has a free tier to prototype and a low monthly paid tier for production; a small VPS plus managed Postgres is a comparable custom-path cost. Object storage for compressed selfies is inexpensive at this scale. Expect modest monthly running costs at the hundreds-of-staff level.
- **Effort:** for a competent full-stack developer, Phase 1 is roughly a few weeks of work on the Supabase path, longer for a fully custom API. Phases 2–3 add incrementally. Actual cost depends heavily on developer rates and how much of the existing prototype's frontend is reused (most of it can be).

These are planning estimates, not quotes — scope and rates vary.

---

## 14. What's already done in the prototype

To avoid rebuilding: the prototype already provides the entire client-side UX — the capture form, position list, site picker, GPS capture with manual fallback, selfie compression, the in/out-of-zone logic and display, the admin log view, the site-management screen, and the Excel export format. The production work is mostly *moving the trust-critical logic (time, geofence, storage, access) to the server* and swapping the demo key-value store for Postgres + object storage behind a real login.
