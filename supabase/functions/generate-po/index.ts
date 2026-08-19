// generate-po
//
// PO row creation happens inline in approve-stage when a request closes
// at its final workflow stage. This function does NOT create the
// purchase_orders row — per this session's design decision, it's kept
// separate: given a request_id whose PO already exists, it renders a
// PDF, uploads it to the private 'purchase-order-documents' bucket, and
// emails it (via Resend) to the requester. Returns a signed URL either
// way, so it can be called again later without re-emailing side effects
// mattering much (upload + email both just re-run).
//
// Authorization: caller must be either the request's requester, or
// someone who appears in that request's approval_actions (i.e. took
// part in approving it). This mirrors the RLS "own or actionable" rule
// used elsewhere, since this function runs with the service-role key
// and bypasses RLS entirely.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { buildCorsHeaders } from '../_shared/cors.ts';
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const RESEND_FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL');

const PO_BUCKET = 'purchase-order-documents';
const SIGNED_URL_TTL_SECONDS = 60 * 60 * 24 * 7; // 7 days

interface GeneratePoBody {
  request_id: string;
}

function jsonResponse(corsHeaders: HeadersInit, body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// Deno-safe Uint8Array -> base64 (avoids call-stack blowups from
// spreading large arrays into String.fromCharCode).
function uint8ToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

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
    const callerId = userData.user.id;

    const body = (await req.json()) as GeneratePoBody;
    if (!body.request_id) {
      return jsonResponse(corsHeaders, { error: 'request_id is required' }, 400);
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // --- Load the PO together with everything needed for the document ---
    const { data: po, error: poError } = await admin
      .from('purchase_orders')
      .select(
        `
        id, po_number, vendor_name, amount, generated_at,
        requests!purchase_orders_request_id_fkey (
          id, item_description, quantity, status, tenant_id, requester_id,
          tenants (name),
          departments (name),
          cost_centers (name, project_code),
          requester:app_users!requests_requester_id_fkey (name, email)
        )
      `
      )
      .eq('request_id', body.request_id)
      .maybeSingle();

    if (poError) return jsonResponse(corsHeaders, { error: poError.message }, 500);
    if (!po || !po.requests) {
      return jsonResponse(corsHeaders,
        { error: 'No purchase order exists for this request yet — it must be approved through its final stage first' },
        404
      );
    }

    const request = po.requests as unknown as {
      id: string;
      item_description: string;
      quantity: number;
      status: string;
      tenant_id: string;
      requester_id: string;
      tenants: { name: string } | null;
      departments: { name: string } | null;
      cost_centers: { name: string; project_code: string | null } | null;
      requester: { name: string; email: string } | null;
    };

    // --- Authorization: requester, or someone in the approval trail ---
    let authorized = request.requester_id === callerId;
    if (!authorized) {
      const { data: actedOn } = await admin
        .from('approval_actions')
        .select('id')
        .eq('request_id', request.id)
        .eq('approver_id', callerId)
        .limit(1)
        .maybeSingle();
      authorized = !!actedOn;
    }
    if (!authorized) {
      return jsonResponse(corsHeaders,
        { error: 'You are not authorized to view this purchase order' },
        403
      );
    }

    // --- Approval history, for the PDF's audit trail section ---
    const { data: approvalHistory } = await admin
      .from('approval_actions')
      .select(
        `
        decision, comment, acted_at,
        workflow_stages!approval_actions_workflow_stage_id_fkey (name),
        approver:app_users!approval_actions_approver_id_fkey (name),
        behalf:app_users!approval_actions_acted_on_behalf_of_fkey (name)
      `
      )
      .eq('request_id', request.id)
      .order('acted_at', { ascending: true });

    // --- Render the PDF ---
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

    drawText(request.tenants?.name ?? 'VestaPortal', { size: 16, useBold: true });
    y -= 4;
    drawText('PURCHASE ORDER', { size: 14, useBold: true, color: [0.06, 0.17, 0.34] });
    y -= 6;
    drawText(`PO Number: ${po.po_number}`, { useBold: true });
    drawText(`Date Generated: ${new Date(po.generated_at).toLocaleDateString()}`);
    y -= 10;

    drawText('Vendor', { useBold: true });
    drawText(po.vendor_name);
    y -= 6;

    drawText('Item', { useBold: true });
    drawText(request.item_description);
    drawText(`Quantity: ${request.quantity}`);
    drawText(`Amount: ${Number(po.amount).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
    y -= 6;

    drawText('Requested By', { useBold: true });
    drawText(request.requester?.name ?? 'Unknown');
    if (request.departments?.name) drawText(`Department: ${request.departments.name}`);
    if (request.cost_centers?.name) {
      drawText(
        `Cost Center: ${request.cost_centers.name}${request.cost_centers.project_code ? ` (${request.cost_centers.project_code})` : ''}`
      );
    }
    y -= 12;

    drawText('Approval History', { useBold: true, size: 12 });
    y -= 2;
    for (const action of approvalHistory ?? []) {
      const stageName = (action.workflow_stages as unknown as { name: string } | null)?.name ?? 'Stage';
      const approverName = (action.approver as unknown as { name: string } | null)?.name ?? 'Unknown';
      const behalfName = (action.behalf as unknown as { name: string } | null)?.name;
      const who = behalfName ? `${approverName} (on behalf of ${behalfName})` : approverName;
      const date = new Date(action.acted_at).toLocaleDateString();
      drawText(`${stageName}: ${action.decision.toUpperCase()} — ${who} — ${date}`, { size: 10 });
      if (action.comment) drawText(`   "${action.comment}"`, { size: 9, color: [0.4, 0.4, 0.4] });
      if (y < 60) break; // avoid drawing off-page; good enough for now
    }

    const pdfBytes = await pdfDoc.save();

    // --- Upload to private storage ---
    const filePath = `${request.tenant_id}/${po.po_number}.pdf`;
    const { error: uploadError } = await admin.storage
      .from(PO_BUCKET)
      .upload(filePath, pdfBytes, { contentType: 'application/pdf', upsert: true });

    if (uploadError) return jsonResponse(corsHeaders, { error: uploadError.message }, 500);

    const { data: signedUrlData, error: signedUrlError } = await admin.storage
      .from(PO_BUCKET)
      .createSignedUrl(filePath, SIGNED_URL_TTL_SECONDS);

    if (signedUrlError || !signedUrlData) {
      return jsonResponse(corsHeaders, { error: signedUrlError?.message ?? 'Could not create signed URL' }, 500);
    }

    // --- Email via Resend ---
    let emailed = false;
    if (RESEND_API_KEY && RESEND_FROM_EMAIL && request.requester?.email) {
      const emailRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${RESEND_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from: RESEND_FROM_EMAIL,
          to: [request.requester.email],
          subject: `Purchase Order ${po.po_number} generated`,
          html: `
            <p>Purchase order <strong>${po.po_number}</strong> has been generated for your request.</p>
            <p><strong>Vendor:</strong> ${po.vendor_name}<br/>
               <strong>Item:</strong> ${request.item_description}<br/>
               <strong>Amount:</strong> ${Number(po.amount).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</p>
            <p>The PDF is attached, and also available here for the next 7 days: <a href="${signedUrlData.signedUrl}">${signedUrlData.signedUrl}</a></p>
          `,
          attachments: [
            {
              filename: `${po.po_number}.pdf`,
              content: uint8ToBase64(pdfBytes),
            },
          ],
        }),
      });

      if (!emailRes.ok) {
        // Don't fail the whole request over email — the PDF is already
        // generated and stored; surface the email problem separately.
        const errText = await emailRes.text();
        return jsonResponse(corsHeaders,
          {
            po_number: po.po_number,
            pdf_url: signedUrlData.signedUrl,
            emailed: false,
            email_error: errText,
          },
          200
        );
      }
      emailed = true;
    }

    return jsonResponse(corsHeaders,
      {
        po_number: po.po_number,
        pdf_url: signedUrlData.signedUrl,
        emailed,
      },
      200
    );
  } catch (err) {
    return jsonResponse(corsHeaders,
      { error: err instanceof Error ? err.message : 'Unexpected error' },
      500
    );
  }
});