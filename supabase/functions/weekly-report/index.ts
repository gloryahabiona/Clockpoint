// ClockPoint — Edge Function: weekly-report
// Builds a CSV of the last 7 days of attendance for every organization that has
// the weekly report enabled, and emails it to that org's chosen recipient.
// Triggered weekly by pg_cron (see supabase/REPORT-SETUP.md).
//
// Required secrets (Edge Function settings -> Secrets):
//   RESEND_API_KEY  — from https://resend.com
//   REPORT_FROM     — verified sender, e.g. "ClockPoint <reports@yourdomain>"
//                     (for quick testing you can use "onboarding@resend.dev")
//   CRON_SECRET     — any long random string; the cron job must send it
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function csv(rows: any[]): string {
  const cols = ["server_time","name","position","site","type","within_geofence","distance_m","lat","lng","gps_accuracy_m","id"];
  const head = ["Server Time","Name","Position","Site","Action","In Zone","Distance (m)","Latitude","Longitude","GPS Accuracy (m)","Record ID"];
  const cell = (v: any) => {
    if (v === null || v === undefined) return "";
    const s = String(v).replace(/"/g, '""');
    return /[",\n]/.test(s) ? `"${s}"` : s;
  };
  const lines = [head.join(",")];
  for (const r of rows) {
    lines.push(cols.map(c => {
      if (c === "type") return r.type === "IN" ? "Clock In" : "Clock Out";
      if (c === "within_geofence") return r.within_geofence === null ? "—" : (r.within_geofence ? "Yes" : "OUT OF ZONE");
      return cell(r[c]);
    }).join(","));
  }
  return lines.join("\n");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const CRON_SECRET = Deno.env.get("CRON_SECRET");
  if (CRON_SECRET && req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return new Response("Forbidden", { status: 403 });
  }

  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
  const FROM = Deno.env.get("REPORT_FROM") ?? "onboarding@resend.dev";

  const { data, error } = await supa.rpc("weekly_report_data");
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  const orgs = (data ?? []) as any[];
  const results: any[] = [];
  const today = new Date().toISOString().slice(0, 10);

  for (const o of orgs) {
    const body = csv(o.events ?? []);
    const b64 = btoa(unescape(encodeURIComponent(body)));
    const subject = `ClockPoint weekly attendance — ${o.org_name} (${o.events?.length ?? 0} records)`;
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: FROM, to: o.email, subject,
        text: `Attached is the attendance log for ${o.org_name} for the last 7 days (${o.events?.length ?? 0} records).`,
        attachments: [{ filename: `attendance_${o.org_name}_${today}.csv`, content: b64 }],
      }),
    });
    results.push({ org: o.org_name, to: o.email, status: res.status });
  }

  return new Response(JSON.stringify({ ok: true, sent: results }), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
});
