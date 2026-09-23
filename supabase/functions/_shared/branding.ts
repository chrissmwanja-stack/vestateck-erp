// Operator branding for emails (item 6). Reads get_platform_branding()
// with whatever client it is given (service role or anon both work: the
// function is SECURITY DEFINER and open to anon) and renders a small,
// inline-styled HTML shell every outbound email shares, so the operator's
// name / colour / support address show up consistently.

export interface Branding {
  platformName: string;
  logoUrl: string;
  primaryColor: string;
  supportEmail: string;
  tagline: string;
}

export const DEFAULT_BRANDING: Branding = {
  platformName: 'VestaPortal',
  logoUrl: '',
  primaryColor: '#1B5560',
  supportEmail: '',
  tagline: 'Multi-department ERP',
};

// deno-lint-ignore no-explicit-any
export async function loadBranding(client: any): Promise<Branding> {
  try {
    const { data, error } = await client.rpc('get_platform_branding').single();
    if (error || !data) return DEFAULT_BRANDING;
    return {
      platformName: data.platform_name || DEFAULT_BRANDING.platformName,
      logoUrl: /^https?:\/\//i.test(data.logo_url ?? '') ? data.logo_url : '',
      primaryColor: /^#[0-9a-f]{6}$/i.test(data.primary_color ?? '') ? data.primary_color : DEFAULT_BRANDING.primaryColor,
      supportEmail: data.support_email || '',
      tagline: data.tagline || DEFAULT_BRANDING.tagline,
    };
  } catch {
    return DEFAULT_BRANDING;
  }
}

export function escapeHtml(s: unknown): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Wraps already-escaped body HTML in the branded shell. Table-based and
// inline-styled on purpose: that is what survives Outlook/Gmail.
export function renderEmail(b: Branding, opts: { title: string; preheader?: string; bodyHtml: string; footerNote?: string }): string {
  const name = escapeHtml(b.platformName);
  const color = b.primaryColor;
  const logo = b.logoUrl ? `<img src="${escapeHtml(b.logoUrl)}" alt="" height="28" style="height:28px;max-width:140px;vertical-align:middle;margin-right:10px;border:0" />` : '';
  const support = b.supportEmail ? ` &middot; <a href="mailto:${escapeHtml(b.supportEmail)}" style="color:#5B6C71">${escapeHtml(b.supportEmail)}</a>` : '';
  const pre = opts.preheader ? `<div style="display:none;max-height:0;overflow:hidden;opacity:0">${escapeHtml(opts.preheader)}</div>` : '';
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${escapeHtml(opts.title)}</title></head>
<body style="margin:0;padding:0;background:#F6F7F8;font-family:Inter,'Helvetica Neue',Arial,sans-serif;color:#1E2A2E">
${pre}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F6F7F8;padding:24px 0">
  <tr><td align="center">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#FFFFFF;border-radius:10px;overflow:hidden;border:1px solid #E4E8E9">
      <tr><td style="background:${color};color:#FFFFFF;padding:16px 24px;font-size:18px;font-weight:600">${logo}${name}</td></tr>
      <tr><td style="padding:24px;font-size:14px;line-height:1.55">
        <h1 style="margin:0 0 12px;font-size:20px;line-height:1.3;color:#123B44">${escapeHtml(opts.title)}</h1>
        ${opts.bodyHtml}
      </td></tr>
      <tr><td style="padding:14px 24px;border-top:1px solid #E4E8E9;font-size:12px;color:#5B6C71">
        ${opts.footerNote ? escapeHtml(opts.footerNote) + '<br/>' : ''}Sent by ${name}${support}
      </td></tr>
    </table>
  </td></tr>
</table>
</body></html>`;
}

// Resend transport shared by every function that emails. Returns null on
// success or the error text; never throws so callers can degrade.
export async function sendEmail(args: {
  apiKey: string;
  from: string;
  to: string[];
  subject: string;
  html: string;
  attachments?: { filename: string; content: string }[];
}): Promise<string | null> {
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${args.apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: args.from, to: args.to, subject: args.subject, html: args.html, attachments: args.attachments }),
    });
    if (!res.ok) return `Resend ${res.status}: ${(await res.text()).slice(0, 500)}`;
    return null;
  } catch (e) {
    return e instanceof Error ? e.message : 'send failed';
  }
}
