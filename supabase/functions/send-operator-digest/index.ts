// send-operator-digest
//
// Emails pending operator digests (platform_digests.delivery_status =
// 'pending') to the recipients recorded on each row, using the operator's
// branding, then marks them sent/failed via mark_platform_digest_delivered().
//
// The digest itself is BUILT in SQL by pg_cron (platform_run_operator_digest,
// 04:00 UTC daily) so the in-app copy never depends on this function or on
// Resend being configured. This function is the email leg only. Invoke it
// on a schedule right after the SQL job, e.g. with the Supabase dashboard's
// function scheduler or an external cron:
//
//   curl -X POST "$SUPABASE_URL/functions/v1/send-operator-digest" \
//        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
//
// Auth: service-role bearer only (this is not a browser endpoint). With no
// RESEND_API_KEY / RESEND_FROM_EMAIL configured it marks rows 'skipped'
// with a reason instead of failing, so the history panel explains itself.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { escapeHtml, loadBranding, renderEmail, sendEmail, type Branding } from '../_shared/branding.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const RESEND_FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') ?? '';
// Where "open in console" links point. Falls back to the first allowed origin.
const APP_URL = (Deno.env.get('APP_URL') ?? (Deno.env.get('ALLOWED_ORIGINS') ?? 'http://localhost:5173').split(',')[0]).replace(/\/$/, '');

interface Ref { id: string; name: string; contact_email?: string | null }
interface Payload {
  totals: { companies: number; active: number; pending: number; suspended: number; live: number; users: number };
  new_companies: (Ref & { plan: string; status: string; created_at: string })[];
  new_users: number;
  stalled: (Ref & { stage_key: string; next_step: string | null; days_in_stage: number })[];
  quiet: (Ref & { plan: string; days_quiet: number })[];
  trials_ending: (Ref & { trial_ends_at: string; days_left: number; stage_key: string })[];
  pending_over_threshold: (Ref & { stage_key: string; days_pending: number })[];
  open_impersonations: { admin_email: string | null; tenant_name: string; started_at: string; reason: string | null }[];
  admins_without_mfa: string[];
  attention_count: number;
  settings?: { pending_company_threshold_days: number };
}
interface DigestRow {
  id: string;
  period_start: string;
  period_end: string;
  generated_at: string;
  attention_count: number;
  payload: Payload;
  recipients: string[];
}

const STAGE: Record<string, string> = {
  created: 'Created', admin_invited: 'Admin invited', admin_joined: 'Admin joined', modules_enabled: 'Modules on',
  team_invited: 'Team invited', first_activity: 'Used, not live', live: 'Live',
};

function companyLink(c: Ref): string {
  return `<a href="${APP_URL}/admin/companies/${encodeURIComponent(c.id)}" style="color:#1B5560;font-weight:600">${escapeHtml(c.name)}</a>`;
}

function section(title: string, color: string, items: string[]): string {
  if (!items.length) return '';
  return `<h2 style="margin:18px 0 6px;font-size:14px;color:${color}">${escapeHtml(title)} (${items.length})</h2>
<ul style="margin:0;padding-left:18px">${items.map((i) => `<li style="margin:3px 0">${i}</li>`).join('')}</ul>`;
}

export function renderDigest(b: Branding, row: DigestRow, summary: string): { subject: string; html: string } {
  const p = row.payload;
  const subject = p.attention_count > 0
    ? `[${b.platformName}] Operator digest: ${p.attention_count} item(s) need attention`
    : `[${b.platformName}] Operator digest: all clear`;

  const totals = `<p style="margin:0 0 12px;color:#5B6C71">${p.totals.companies} companies &middot; ${p.totals.live} live &middot; ${p.totals.pending} pending &middot; ${p.totals.users} users`
    + (p.new_users ? ` &middot; <strong style="color:#1E2A2E">+${p.new_users} new users</strong>` : '') + `</p>`;

  const body = [
    `<p style="margin:0 0 8px"><strong>${escapeHtml(summary)}</strong></p>`,
    totals,
    section('New companies', '#1B5560', p.new_companies.map((c) => `${companyLink(c)} &mdash; ${escapeHtml(c.plan)}, ${escapeHtml(c.status)}`)),
    section('Trials ending within 7 days', '#B3261E', p.trials_ending.map((c) => `${companyLink(c)} &mdash; ${c.days_left === 0 ? 'ends today' : `${c.days_left} day(s) left`}, ${escapeHtml(STAGE[c.stage_key] ?? c.stage_key)}${c.contact_email ? `, ${escapeHtml(c.contact_email)}` : ''}`)),
    section('Stalled in setup (7+ days)', '#8F5D14', p.stalled.map((c) => `${companyLink(c)} &mdash; ${c.days_in_stage}d at &ldquo;${escapeHtml(STAGE[c.stage_key] ?? c.stage_key)}&rdquo;: ${escapeHtml(c.next_step ?? '')}`)),
    section(`Pending longer than ${p.settings?.pending_company_threshold_days ?? 2} days`, '#8F5D14', p.pending_over_threshold.map((c) => `${companyLink(c)} &mdash; ${c.days_pending} day(s)`)),
    section('Gone quiet (30+ days)', '#8F5D14', p.quiet.map((c) => `${companyLink(c)} &mdash; ${escapeHtml(c.plan)}, quiet ${c.days_quiet} day(s)${c.contact_email ? `, ${escapeHtml(c.contact_email)}` : ''}`)),
    section('Platform admins without MFA', '#B3261E', p.admins_without_mfa.map((e) => escapeHtml(e))),
    section('Open View-as sessions', '#5B6C71', p.open_impersonations.map((s) => `${escapeHtml(s.admin_email ?? 'unknown')} &rarr; ${escapeHtml(s.tenant_name)}${s.reason ? ` (${escapeHtml(s.reason)})` : ''}`)),
    p.attention_count === 0 ? `<p style="margin:12px 0 0;color:#2E7D32"><strong>All clear.</strong> Nothing needed attention in this period.</p>` : '',
    `<p style="margin:20px 0 0"><a href="${APP_URL}/admin" style="display:inline-block;background:${b.primaryColor};color:#fff;text-decoration:none;padding:10px 16px;border-radius:8px;font-weight:600">Open the console</a></p>`,
  ].join('\n');

  const html = renderEmail(b, {
    title: 'Operator digest',
    preheader: summary,
    bodyHtml: body,
    footerNote: `Period ${new Date(row.period_start).toUTCString()} to ${new Date(row.period_end).toUTCString()}. Manage recipients under Admin > Settings > Notifications.`,
  });
  return { subject, html };
}

serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const auth = req.headers.get('Authorization') ?? '';
  if (auth !== `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`) {
    return new Response(JSON.stringify({ error: 'service role required' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const branding = await loadBranding(admin);

  const { data, error } = await admin
    .from('platform_digests')
    .select('id, period_start, period_end, generated_at, attention_count, payload, recipients')
    .eq('delivery_status', 'pending')
    .order('generated_at', { ascending: true })
    .limit(20);
  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }

  const results: { id: string; status: string; error?: string }[] = [];
  for (const row of (data ?? []) as DigestRow[]) {
    if (!row.recipients?.length) {
      await admin.rpc('mark_platform_digest_delivered', { p_id: row.id, p_status: 'skipped', p_error: 'no recipients' });
      results.push({ id: row.id, status: 'skipped' });
      continue;
    }
    if (!RESEND_API_KEY || !RESEND_FROM_EMAIL) {
      await admin.rpc('mark_platform_digest_delivered', { p_id: row.id, p_status: 'skipped', p_error: 'email not configured (RESEND_API_KEY / RESEND_FROM_EMAIL)' });
      results.push({ id: row.id, status: 'skipped', error: 'email not configured' });
      continue;
    }
    const { data: summary } = await admin.rpc('platform_digest_summary', { p_payload: row.payload });
    const { subject, html } = renderDigest(branding, row, (summary as string) ?? '');
    const err = await sendEmail({ apiKey: RESEND_API_KEY, from: RESEND_FROM_EMAIL, to: row.recipients, subject, html });
    await admin.rpc('mark_platform_digest_delivered', { p_id: row.id, p_status: err ? 'failed' : 'sent', p_error: err });
    results.push({ id: row.id, status: err ? 'failed' : 'sent', error: err ?? undefined });
  }

  return new Response(JSON.stringify({ processed: results.length, results }), { headers: { 'Content-Type': 'application/json' } });
});
