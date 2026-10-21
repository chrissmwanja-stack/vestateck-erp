// generate-ins-doc
//
// Renders one document of the insurance document pack as a PDF, uploads it to
// the private 'tenant-documents' bucket, and registers it in the shared
// document store (documents, via documents_register) with the template
// version that produced it -- so a PDF can be reproduced years later.
//
// Authorization mirrors generate-po: the caller must hold insurance access in
// the policy's tenant. The function runs with the service-role key and
// bypasses RLS entirely, so it re-checks that itself; the registration RPC is
// called as the CALLER (documents_register derives the tenant from the JWT
// and enforces the same tenant-folder and hash rules the screens follow).
//
// Kinds (template_code = "ins_" + kind, template_version = TEMPLATE_VERSION):
//   client_debit_note  billed to the insured: the gross premium
//   insurer_debit_note commission debited to the insurers, premium shown for context
//   risk_note          schedule of the risks linked to the policy
//   renewal_notice     expiry notice for the insured
//
// No email path: the document lands in the store and is downloaded from
// there (the policy page's Documents panel lists it immediately).

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { buildCorsHeaders } from '../_shared/cors.ts';
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const BUCKET = 'tenant-documents';
const SIGNED_URL_TTL_SECONDS = 60 * 60; // the caller gets a fresh download from the store anyway
const TEMPLATE_VERSION = 1;

const KINDS = ['client_debit_note', 'insurer_debit_note', 'risk_note', 'renewal_notice'] as const;
type DocKind = (typeof KINDS)[number];

const TITLES: Record<DocKind, string> = {
  client_debit_note: 'CLIENT DEBIT NOTE',
  insurer_debit_note: 'INSURER DEBIT NOTE (COMMISSION)',
  risk_note: 'RISK NOTE',
  renewal_notice: 'RENEWAL NOTICE',
};

interface GenerateDocBody {
  policy_id: string;
  kind: DocKind;
}

function jsonResponse(corsHeaders: HeadersInit, body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes as unknown as ArrayBuffer);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

const stamp = () => new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
const money = (v: number | null | undefined, cur: string) =>
  `${cur} ${Number(v ?? 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const day = (d: string | null | undefined) => (d ? new Date(d).toISOString().slice(0, 10) : '-');

serve(async (req) => {
  const corsHeaders = buildCorsHeaders(req);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return jsonResponse(corsHeaders, { error: 'Missing Authorization header' }, 401);
    }
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse(corsHeaders, { error: 'Invalid or expired session' }, 401);
    }

    const body = (await req.json()) as GenerateDocBody;
    if (!body.policy_id) return jsonResponse(corsHeaders, { error: 'policy_id is required' }, 400);
    if (!KINDS.includes(body.kind)) {
      return jsonResponse(corsHeaders, { error: `kind must be one of: ${KINDS.join(', ')}` }, 400);
    }
    const kind = body.kind;

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // --- Authorization: insurance access in the policy's tenant ---
    const [{ data: hasInsurance }, { data: callerTenantId }] = await Promise.all([
      userClient.rpc('can_access_insurance'),
      userClient.rpc('get_my_tenant_id'),
    ]);

    // --- Load the policy with the parties ---
    const { data: pol, error: polError } = await admin
      .from('ins_policies')
      .select(
        `
        id, policy_no, status, transaction_type, inception_date, expiry_date,
        sum_insured, currency, gross_premium, commission_rate_pct,
        commission_amount, net_premium_to_insurer, risk_description,
        tenant_id,
        ins_clients ( client_id, bd_clients ( name, email, phone ) ),
        ins_insurers ( name ),
        ins_product_lines ( name ),
        tenants ( name )
      `
      )
      .eq('id', body.policy_id)
      .maybeSingle();

    if (polError) return jsonResponse(corsHeaders, { error: polError.message }, 500);
    if (!pol) return jsonResponse(corsHeaders, { error: 'Policy not found' }, 404);

    if (hasInsurance !== true || callerTenantId !== pol.tenant_id) {
      return jsonResponse(corsHeaders, { error: 'You are not authorized to document this policy' }, 403);
    }

    // --- Risks, only where the document shows them ---
    let risks: {
      description: string; risk_type: string; reg_no: string | null;
      make: string | null; model: string | null; year_made: number | null; sum_insured: number;
    }[] = [];
    if (kind === 'risk_note') {
      const { data: rows, error: risksError } = await admin
        .from('ins_policy_risks')
        .select(
          `ins_risks ( description, risk_type, reg_no, make, model, year_made, sum_insured )`
        )
        .eq('policy_id', pol.id);
      if (risksError) return jsonResponse(corsHeaders, { error: risksError.message }, 500);
      risks = (rows ?? [])
        .map((r: { ins_risks: unknown }) => r.ins_risks as (typeof risks)[number])
        .filter(Boolean);
    }

    // --- Render ---
    const client = (pol.ins_clients as unknown as { bd_clients: { name: string; email: string | null; phone: string | null } | null } | null)?.bd_clients;
    const insurer = (pol.ins_insurers as unknown as { name: string } | null)?.name ?? '-';
    const line = (pol.ins_product_lines as unknown as { name: string } | null)?.name ?? '-';
    const tenantName = (pol.tenants as unknown as { name: string } | null)?.name ?? 'VestaPortal';

    const pdfDoc = await PDFDocument.create();
    const page = pdfDoc.addPage([595, 842]); // A4
    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
    const bold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);

    let y = 800;
    const left = 50;
    const lineGap = 18;

    const drawText = (text: string, opts: { size?: number; useBold?: boolean; color?: [number, number, number] } = {}) => {
      page.drawText(text, {
        x: left,
        y,
        size: opts.size ?? 11,
        font: opts.useBold ? bold : font,
        color: opts.color ? rgb(...opts.color) : rgb(0.1, 0.1, 0.1),
      });
      y -= lineGap;
    };

    drawText(tenantName, { size: 16, useBold: true });
    y -= 4;
    drawText(TITLES[kind], { size: 14, useBold: true, color: [0.06, 0.17, 0.34] });
    y -= 6;
    drawText(`Policy: ${pol.policy_no}`, { useBold: true });
    drawText(`Product: ${line}`);
    drawText(`Period: ${day(pol.inception_date)} to ${day(pol.expiry_date)}  (${pol.status}, ${pol.transaction_type})`);
    drawText(`Generated: ${new Date().toISOString().slice(0, 10)}  (template ins_${kind} v${TEMPLATE_VERSION})`, { size: 9, color: [0.4, 0.4, 0.4] });
    y -= 10;

    drawText('Insured', { useBold: true });
    drawText(client?.name ?? '-');
    if (client?.email) drawText(`Email: ${client.email}`);
    if (client?.phone) drawText(`Phone: ${client.phone}`);
    y -= 6;
    drawText('Insurer', { useBold: true });
    drawText(insurer);
    y -= 10;

    if (kind === 'risk_note') {
      drawText('Schedule of risks', { useBold: true, size: 12 });
      y -= 2;
      if (risks.length === 0) {
        drawText('No risks are linked to this policy.');
      }
      let total = 0;
      for (const r of risks) {
        total += Number(r.sum_insured ?? 0);
        const vehicle = [r.make, r.model, r.year_made ? String(r.year_made) : null, r.reg_no ? `reg ${r.reg_no}` : null]
          .filter(Boolean).join(' ');
        drawText(`- ${r.description}`, { useBold: true });
        if (vehicle) drawText(`  ${vehicle} (${r.risk_type})`, { size: 10 });
        drawText(`  Sum insured: ${money(r.sum_insured, pol.currency)}`, { size: 10 });
        if (y < 80) break;
      }
      y -= 6;
      drawText(`Total sum insured on schedule: ${money(total, pol.currency)}`, { useBold: true });
    } else {
      drawText('Premium breakdown', { useBold: true, size: 12 });
      y -= 2;
      drawText(`Sum insured: ${money(pol.sum_insured, pol.currency)}`);
      drawText(`Gross premium: ${money(pol.gross_premium, pol.currency)}`);
      drawText(`Commission at ${Number(pol.commission_rate_pct).toFixed(2)}%: ${money(pol.commission_amount, pol.currency)}`);
      drawText(`Net premium to insurers: ${money(pol.net_premium_to_insurer, pol.currency)}`);
      y -= 8;

      if (kind === 'client_debit_note') {
        drawText(`Amount due from the insured: ${money(pol.gross_premium, pol.currency)}`, { useBold: true });
      } else if (kind === 'insurer_debit_note') {
        drawText(`Commission due to us from the insurers: ${money(pol.commission_amount, pol.currency)}`, { useBold: true });
        drawText('Retained from the premium collected on this policy.', { size: 9, color: [0.4, 0.4, 0.4] });
      } else {
        drawText(`This policy expires on ${day(pol.expiry_date)}.`, { useBold: true });
        drawText('Please contact us before the expiry date to arrange renewal terms.');
      }
      if (pol.risk_description) {
        y -= 8;
        drawText('Risk description', { useBold: true, size: 12 });
        drawText(pol.risk_description);
      }
    }

    y -= 24;
    drawText(`Issued by ${tenantName} -- this document was generated from the policy record.`, { size: 9, color: [0.4, 0.4, 0.4] });

    const pdfBytes = await pdfDoc.save();

    // --- Upload to the shared private bucket (tenant folder) ---
    const filePath = `${pol.tenant_id}/insurance/insurance_policy/${pol.id}/${pol.policy_no}-${kind}-${stamp()}.pdf`;
    const { error: uploadError } = await admin.storage
      .from(BUCKET)
      .upload(filePath, pdfBytes, { contentType: 'application/pdf', upsert: true });
    if (uploadError) return jsonResponse(corsHeaders, { error: uploadError.message }, 500);

    // --- Register in the store, as the caller (the RPC re-checks tenant rules) ---
    const { data: registered, error: registerError } = await userClient.rpc('documents_register', {
      p_entity_type: 'insurance_policy',
      p_entity_id: pol.id,
      p_bucket: BUCKET,
      p_path: filePath,
      p_file_name: filePath.split('/').pop(),
      p_content_hash: await sha256Hex(pdfBytes),
      p_byte_size: pdfBytes.length,
      p_mime_type: 'application/pdf',
      p_doc_kind: kind,
      p_template_code: `ins_${kind}`,
      p_template_version: TEMPLATE_VERSION,
    });
    if (registerError || !registered) {
      // The registry refused the row: remove the orphan so storage and the
      // registry cannot drift apart (same rule the Documents panel follows).
      await admin.storage.from(BUCKET).remove([filePath]);
      return jsonResponse(corsHeaders, { error: registerError?.message ?? 'Could not register the document' }, 500);
    }

    const { data: signed, error: signedError } = await admin.storage
      .from(BUCKET)
      .createSignedUrl(filePath, SIGNED_URL_TTL_SECONDS);

    return jsonResponse(corsHeaders, {
      id: (registered as { id: string }).id,
      kind,
      path: filePath,
      signed_url: signed?.signedUrl ?? null,
      signed_error: signedError?.message ?? null,
    }, 200);
  } catch (err) {
    return jsonResponse(corsHeaders,
      { error: err instanceof Error ? err.message : 'Unexpected error' },
      500
    );
  }
});
