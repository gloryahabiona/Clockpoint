# ClockPoint — Weekly attendance email (setup)

Each organization's admin sets a recipient email + toggle on the **Settings** tab
of their dashboard. A weekly job then emails that org a CSV of the past 7 days.
The admin-console part already works once you run `features.sql`; this doc wires
the actual sending. Three one-time pieces:

## 1. Run the schema
SQL Editor → run [`features.sql`](features.sql) (adds slugs, brand color, report
settings, and `weekly_report_data()`).

## 2. Get an email provider (Resend — free tier)
1. Sign up at <https://resend.com>.
2. For real use, add & verify your sending domain (so mail comes from
   `reports@yourcompany.com`). For quick testing you can send from
   `onboarding@resend.dev` to your own address without a domain.
3. Create an **API key** and copy it.

## 3. Deploy the weekly-report function
1. Edge Functions → **Create a function** named exactly **`weekly-report`**.
2. Paste [`functions/weekly-report/index.ts`](functions/weekly-report/index.ts).
3. Leave **Verify JWT ON** (it's called server-to-server, not from a browser).
4. In the function's **Secrets**, add:
   - `RESEND_API_KEY` — your Resend key
   - `REPORT_FROM` — e.g. `ClockPoint <reports@yourdomain.com>` (or `onboarding@resend.dev`)
   - `CRON_SECRET` — any long random string (used in step 4)
5. Deploy.

You can test immediately by enabling the report for an org (Settings tab, tick
"Enable weekly email", Save) and then invoking the function once from the
dashboard's function tester with header `x-cron-secret: <your CRON_SECRET>`.

## 4. Schedule it weekly (pg_cron + pg_net)
In the SQL Editor:
```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- runs every Monday 06:00 UTC; replace <REF> and <CRON_SECRET>
select cron.schedule(
  'clockpoint-weekly-report',
  '0 6 * * 1',
  $$
  select net.http_post(
    url     := 'https://<REF>.functions.supabase.co/weekly-report',
    headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>', 'Content-Type', 'application/json'),
    body    := '{}'::jsonb
  );
  $$
);
```
`<REF>` is your project ref (the `ugowcusxebtkwrlvdpvc` part of your URL).
To change the time, edit the cron expression. To stop it:
`select cron.unschedule('clockpoint-weekly-report');`

## Notes
- Only orgs with **Enable weekly email** on and a recipient set receive mail.
- The CSV covers the last 7 days of that org's `clock_events`.
- Free email/cron tiers are fine at this scale; upgrade later if volume grows.
