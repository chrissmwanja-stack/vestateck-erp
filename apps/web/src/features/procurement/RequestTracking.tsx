import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Box,
  Button,
  CircularProgress,
  Grid,
  IconButton,
  Link,
  MenuItem,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from "@mui/material";
import { Email, PictureAsPdf } from "@mui/icons-material";
import { supabase } from "../../lib/supabaseClient";
import { buildPoPdf } from "./pdfGenerator";
import RequestLineItemsDialog from "./RequestLineItemsDialog";
import OfferDetailDialog from "./OfferDetailDialog"; // NEW: Initial PO # popup

// Read-only reporting screen — mirrors the "Request Tracking" reference
// screen (MR search -> MR list, steps 1 through PO close). Backed by the
// get_request_tracking() RPC; no row actions live here except the PDF
// icon, which reuses the exact generate-and-view flow from
// ProcurementInfo.tsx (get_po_pdf_data -> jsPDF -> upload to
// po-documents -> record_po_pdf -> signed URL). For rows with no PO yet
// (purchase_order_id is null), the icon is disabled with a tooltip
// explaining why, since there's nothing to generate.
//
// Clicking the MR # opens a read-only RequestLineItemsDialog in place --
// no navigation, no new window/tab. Clicking Initial PO # does the same
// via OfferDetailDialog, backed by get_offer_detail() (SECURITY DEFINER,
// tenant-scoped) since request_offers' own RLS policy only allows the
// requester or a current-stage actor to read it directly, which is too
// narrow for someone just browsing this report.
//
// mr_created_at: full timestamp (requests.created_at), added to
// get_request_tracking() alongside the existing date-only mr_date so the
// detail dialog's header can show a real "Date" with time, matching the
// MAKS reference. mr_date (date-only) is left untouched since it's what
// the MR Date from/to filters are built on.

interface Organization {
  id: string;
  company_code: string;
  site_name: string;
}

interface TrackingRow {
  request_id: string;
  purchase_order_id: string | null;
  mr_number: string;
  mr_date: string;
  mr_created_at: string;
  mr_title: string;
  subcontractor: string | null;
  requester_name: string;
  order_placer_name: string | null;
  initial_po_number: string | null;
  po_number: string | null;
  po_date: string | null;
  delivery_date: string | null;
  market_offer_date: string | null;
  company: string | null;
  po_total: number | null;
  currency: string | null;
  closing_date: string | null;
  status: string;
  lifecycle_status: string;
  pending_authority: string | null;
  cost_code: string | null;
  place_of_use: string | null;
  pdf_storage_path?: string | null;
  pdf_generated_at?: string | null;
}

// Matches the reference screen's Status dropdown. p_status also accepts
// the virtual value "pending_all", which groups the three pending_*
// lifecycle states server-side. "All" is UI-only shorthand for "no
// status filter" and must be translated to null before hitting the RPC
// (see FIX below) — the SQL function has no branch for the literal
// string "All".
const STATUS_OPTIONS = [
  { value: "All", label: "All" },
  { value: "pending_mr", label: "Pending MR" },
  { value: "pending_bid_entry", label: "Pending Bid Entry" },
  { value: "pending_po", label: "Pending PO" },
  { value: "pending_all", label: "Pending All" },
  { value: "open_order", label: "Open Orders" },
];

// Labels for rows whose lifecycle_status falls outside the filter's own
// options (closed/rejected/cancelled) — the reference screen shows these
// in the MR List even though they aren't separate dropdown entries.
const STATUS_LABELS: Record<string, string> = {
  pending_mr: "Pending MR",
  pending_bid_entry: "Pending Bid Entry",
  pending_po: "Pending PO",
  open_order: "Open Order",
  closed_order: "Closed Order",
  rejected: "Rejected",
  cancelled: "Cancelled",
};

const emptyFilters = {
  organization_id: "",
  mr_number: "",
  po_number: "",
  company: "",
  description: "",
  subcontractor: "",
  mr_originator: "",
  pending_authority: "",
  status: "All",
  cost_code: "",
  place_of_use: "",
  mr_date_from: "",
  mr_date_to: "",
  po_date_from: "",
  po_date_to: "",
  delivery_date_from: "",
  delivery_date_to: "",
  market_offer_date_from: "",
  market_offer_date_to: "",
  closing_date_from: "",
  closing_date_to: "",
};

export default function RequestTracking() {
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [filters, setFilters] = useState(emptyFilters);
  const [rows, setRows] = useState<TrackingRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pdfGenerating, setPdfGenerating] = useState<string | null>(null);
  const [emailingPo, setEmailingPo] = useState<string | null>(null);
  const [emailSuccess, setEmailSuccess] = useState<string | null>(null);

  // Row whose "Request Detail" dialog is currently open, if any.
  const [detailRow, setDetailRow] = useState<TrackingRow | null>(null);

  // NEW: row whose "Initial PO #" (offer) dialog is currently open, if any.
  const [offerDetailRow, setOfferDetailRow] = useState<TrackingRow | null>(null);

  useEffect(() => {
    supabase
      .from("organizations")
      .select("id, company_code, site_name")
      .eq("is_active", true)
      .then(({ data }) => setOrganizations((data ?? []) as Organization[]));
  }, []);

  const runSearch = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase.rpc("get_request_tracking", {
      p_organization_id: filters.organization_id || null,
      p_mr_number: filters.mr_number || null,
      p_po_number: filters.po_number || null,
      p_company: filters.company || null,
      p_description: filters.description || null,
      p_subcontractor: filters.subcontractor || null,
      p_mr_originator: filters.mr_originator || null,
      p_pending_authority: filters.pending_authority || null,
      // FIX: "All" is the default/no-op selection in the dropdown, not a
      // real lifecycle_status value the RPC understands. Sending the
      // literal string "All" through previously meant the very first
      // search on page load (and any explicit "All" re-selection) was
      // filtered against a status that matches nothing. Only real status
      // values (including the "pending_all" grouping value) get sent.
      p_status: filters.status === "All" ? null : filters.status || null,
      p_cost_code: filters.cost_code || null,
      p_place_of_use: filters.place_of_use || null,
      p_mr_date_from: filters.mr_date_from || null,
      p_mr_date_to: filters.mr_date_to || null,
      p_po_date_from: filters.po_date_from || null,
      p_po_date_to: filters.po_date_to || null,
      p_delivery_date_from: filters.delivery_date_from || null,
      p_delivery_date_to: filters.delivery_date_to || null,
      p_market_offer_date_from: filters.market_offer_date_from || null,
      p_market_offer_date_to: filters.market_offer_date_to || null,
      p_closing_date_from: filters.closing_date_from || null,
      p_closing_date_to: filters.closing_date_to || null,
    });
    setLoading(false);
    if (error) setError(error.message);
    else setRows((data ?? []) as TrackingRow[]);
  }, [filters]);

  useEffect(() => {
    runSearch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const setField = (key: keyof typeof filters) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setFilters((f) => ({ ...f, [key]: e.target.value }));

  // Same generate-and-view flow as ProcurementInfo.tsx: fetch PO data,
  // build the PDF client-side with buildPoPdf, upload it to the
  // per-tenant folder in the po-documents bucket, record the storage
  // path on the PO row, then open a short-lived signed URL. Kept
  // identical on purpose so both screens always produce the same
  // document for the same PO.
  const viewPdf = async (row: TrackingRow) => {
    if (!row.purchase_order_id) return;
    setPdfGenerating(row.purchase_order_id);
    setError(null);
    try {
      const { data, error: fetchErr } = await supabase
        .rpc("get_po_pdf_data", { p_purchase_order_id: row.purchase_order_id })
        .single();
      if (fetchErr || !data) throw new Error(fetchErr?.message ?? "Could not load PO data for PDF");

      const blob = buildPoPdf(data as any);

      const { data: tenantId, error: tenantErr } = await supabase.rpc("get_my_tenant_id");
      if (tenantErr || !tenantId) throw new Error("Could not resolve tenant for storage path");

      const path = `${tenantId}/${row.po_number}.pdf`;
      const { error: uploadErr } = await supabase.storage
        .from("po-documents")
        .upload(path, blob, { upsert: true, contentType: "application/pdf" });
      if (uploadErr) throw uploadErr;

      const { error: recordErr } = await supabase.rpc("record_po_pdf", {
        p_purchase_order_id: row.purchase_order_id,
        p_storage_path: path,
      });
      if (recordErr) throw recordErr;

      const { data: signed, error: signErr } = await supabase.storage
        .from("po-documents")
        .createSignedUrl(path, 60);
      if (signErr || !signed) throw new Error(signErr?.message ?? "Could not create a link to the PDF");

      window.open(signed.signedUrl, "_blank");
      runSearch();
    } catch (e: any) {
      setError(e.message ?? "Could not generate the PO PDF");
    } finally {
      setPdfGenerating(null);
    }
  };

  // Server-side generation + email to the requester via the generate-po
  // Edge Function — same handler as ProcurementInfo.tsx, kept identical
  // on purpose. Separate from viewPdf, which regenerates client-side and
  // just opens a link; this one renders on the server, uploads to the
  // purchase-order-documents bucket, and emails the requester via Resend.
  const emailPo = async (row: TrackingRow) => {
    if (!row.purchase_order_id) return;
    setEmailingPo(row.purchase_order_id);
    setError(null);
    setEmailSuccess(null);
    try {
      const { data, error: fnError } = await supabase.functions.invoke("generate-po", {
        body: { request_id: row.request_id },
      });
      if (fnError) {
        const context = (fnError as { context?: Response }).context;
        const detail = context ? await context.clone().json().catch(() => null) : null;
        throw new Error(detail?.error ?? fnError.message);
      }

      const result = data as { po_number: string; pdf_url: string; emailed: boolean; email_error?: string };
      if (result.emailed) {
        setEmailSuccess(`PO ${result.po_number} emailed to the requester.`);
      } else {
        setEmailSuccess(
          `PO ${result.po_number} generated, but the email could not be sent${
            result.email_error ? `: ${result.email_error}` : "."
          } A link is available: ${result.pdf_url}`
        );
      }
    } catch (e: any) {
      setError(e.message ?? "Could not email the PO");
    } finally {
      setEmailingPo(null);
    }
  };

  const exportCsv = () => {
    const headers = [
      "MR #", "MR Date", "MR Title", "Subcontractor", "Requester", "Order Placer",
      "Initial PO #", "PO Date", "Delivery Date", "Market Offer Date", "Company",
      "PO #", "Closing Date", "PO Total", "Currency", "Status", "Pending Authority",
    ];
    const lines = rows.map((r) => [
      r.mr_number, r.mr_date, r.mr_title, r.subcontractor ?? "", r.requester_name,
      r.order_placer_name ?? "", r.initial_po_number ?? "", r.po_date ?? "",
      r.delivery_date ?? "", r.market_offer_date ?? "", r.company ?? "",
      r.po_number ?? "", r.closing_date ?? "", r.po_total ?? "", r.currency ?? "",
      STATUS_LABELS[r.lifecycle_status] ?? r.lifecycle_status, r.pending_authority ?? "",
    ].map((v) => `"${String(v).replace(/"/g, '""')}"`).join(","));
    const blob = new Blob([[headers.join(","), ...lines].join("\n")], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "request-tracking.csv";
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <Box sx={{ maxWidth: 1400, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>
        Request tracking
      </Typography>

      <Paper variant="outlined" sx={{ p: 2, mb: 3 }}>
        <Grid container spacing={2}>
          <Grid item xs={12} sm={4}>
            <TextField
              select fullWidth size="small" label="Organization"
              value={filters.organization_id}
              onChange={(e) => setFilters((f) => ({ ...f, organization_id: e.target.value }))}
            >
              <MenuItem value="">All</MenuItem>
              {organizations.map((o) => (
                <MenuItem key={o.id} value={o.id}>{o.company_code} - {o.site_name}</MenuItem>
              ))}
            </TextField>
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="MR #" value={filters.mr_number} onChange={setField("mr_number")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="PO #" value={filters.po_number} onChange={setField("po_number")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Company" value={filters.company} onChange={setField("company")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Subcontractor" value={filters.subcontractor} onChange={setField("subcontractor")} />
          </Grid>

          <Grid item xs={12} sm={4}>
            <TextField fullWidth size="small" label="Description" value={filters.description} onChange={setField("description")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="MR Originator" value={filters.mr_originator} onChange={setField("mr_originator")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Pending Authority" value={filters.pending_authority} onChange={setField("pending_authority")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField
              select fullWidth size="small" label="Status"
              value={filters.status}
              onChange={(e) => setFilters((f) => ({ ...f, status: e.target.value }))}
            >
              {STATUS_OPTIONS.map((s) => <MenuItem key={s.value} value={s.value}>{s.label}</MenuItem>)}
            </TextField>
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Cost Code" value={filters.cost_code} onChange={setField("cost_code")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Place of use" value={filters.place_of_use} onChange={setField("place_of_use")} />
          </Grid>

          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="MR Date from" InputLabelProps={{ shrink: true }} value={filters.mr_date_from} onChange={setField("mr_date_from")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="MR Date to" InputLabelProps={{ shrink: true }} value={filters.mr_date_to} onChange={setField("mr_date_to")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="PO Date from" InputLabelProps={{ shrink: true }} value={filters.po_date_from} onChange={setField("po_date_from")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="PO Date to" InputLabelProps={{ shrink: true }} value={filters.po_date_to} onChange={setField("po_date_to")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="Delivery Date from" InputLabelProps={{ shrink: true }} value={filters.delivery_date_from} onChange={setField("delivery_date_from")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="Delivery Date to" InputLabelProps={{ shrink: true }} value={filters.delivery_date_to} onChange={setField("delivery_date_to")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="Offer Date from" InputLabelProps={{ shrink: true }} value={filters.market_offer_date_from} onChange={setField("market_offer_date_from")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" type="date" label="Offer Date to" InputLabelProps={{ shrink: true }} value={filters.market_offer_date_to} onChange={setField("market_offer_date_to")} />
          </Grid>

          <Grid item xs={12} sx={{ display: "flex", gap: 1 }}>
            <Button variant="contained" onClick={runSearch} disabled={loading}>
              {loading ? "Searching…" : "Search"}
            </Button>
            <Button variant="outlined" onClick={() => setFilters(emptyFilters)}>Clear</Button>
            <Box sx={{ flexGrow: 1 }} />
            <Button variant="text" onClick={exportCsv} disabled={rows.length === 0}>Export to CSV</Button>
          </Grid>
        </Grid>
      </Paper>

      {error && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>{error}</Alert>}
      {emailSuccess && <Alert severity="success" sx={{ mb: 2 }} onClose={() => setEmailSuccess(null)}>{emailSuccess}</Alert>}

      <TableContainer component={Paper} variant="outlined">
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>MR #</TableCell>
              <TableCell>MR Date</TableCell>
              <TableCell>MR Title</TableCell>
              <TableCell>Subcontractor</TableCell>
              <TableCell>Requester</TableCell>
              <TableCell>Order Placer</TableCell>
              <TableCell>Initial PO #</TableCell>
              <TableCell>PO Date</TableCell>
              <TableCell>Delivery Date</TableCell>
              <TableCell>Company</TableCell>
              <TableCell>PO #</TableCell>
              <TableCell>Closing Date</TableCell>
              <TableCell align="right">PO Total</TableCell>
              <TableCell>Curr.</TableCell>
              <TableCell>Status</TableCell>
              <TableCell>Pending Authority</TableCell>
              <TableCell align="center">PDF</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => {
              const isPdfBusy = pdfGenerating === r.purchase_order_id;
              const isEmailBusy = emailingPo === r.purchase_order_id;
              const pdfTooltip = !r.purchase_order_id
                ? "No PO issued yet for this request"
                : r.pdf_generated_at
                ? `Last generated ${new Date(r.pdf_generated_at).toLocaleString()}`
                : "Generate PO PDF";
              const emailTooltip = !r.purchase_order_id
                ? "No PO issued yet for this request"
                : "Email PO to requester";
              return (
                <TableRow key={r.request_id} hover>
                  <TableCell>
                    <Link component="button" variant="body2" onClick={() => setDetailRow(r)}>
                      {r.mr_number}
                    </Link>
                  </TableCell>
                  <TableCell>{r.mr_date}</TableCell>
                  <TableCell>{r.mr_title}</TableCell>
                  <TableCell>{r.subcontractor}</TableCell>
                  <TableCell>{r.requester_name}</TableCell>
                  <TableCell>{r.order_placer_name}</TableCell>
                  <TableCell>
                    {r.initial_po_number ? (
                      <Link component="button" variant="body2" onClick={() => setOfferDetailRow(r)}>
                        {r.initial_po_number}
                      </Link>
                    ) : (
                      "—"
                    )}
                  </TableCell>
                  <TableCell>{r.po_date}</TableCell>
                  <TableCell>{r.delivery_date}</TableCell>
                  <TableCell>{r.company}</TableCell>
                  <TableCell>{r.po_number}</TableCell>
                  <TableCell>{r.closing_date}</TableCell>
                  <TableCell align="right">{r.po_total?.toLocaleString()}</TableCell>
                  <TableCell>{r.currency}</TableCell>
                  <TableCell>{STATUS_LABELS[r.lifecycle_status] ?? r.lifecycle_status}</TableCell>
                  <TableCell>{r.pending_authority}</TableCell>
                  <TableCell align="center">
                    <Tooltip title={pdfTooltip}>
                      <span>
                        <IconButton
                          size="small"
                          disabled={!r.purchase_order_id || isPdfBusy}
                          onClick={() => viewPdf(r)}
                        >
                          {isPdfBusy ? (
                            <CircularProgress size={16} />
                          ) : (
                            <PictureAsPdf fontSize="small" color={r.purchase_order_id ? "error" : "disabled"} />
                          )}
                        </IconButton>
                      </span>
                    </Tooltip>
                    <Tooltip title={emailTooltip}>
                      <span>
                        <IconButton
                          size="small"
                          disabled={!r.purchase_order_id || isEmailBusy}
                          onClick={() => emailPo(r)}
                        >
                          {isEmailBusy ? (
                            <CircularProgress size={16} />
                          ) : (
                            <Email fontSize="small" color={r.purchase_order_id ? "primary" : "disabled"} />
                          )}
                        </IconButton>
                      </span>
                    </Tooltip>
                  </TableCell>
                </TableRow>
              );
            })}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={17} align="center">
                  <Typography color="text.secondary" sx={{ py: 3 }}>No results for these filters.</Typography>
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>

      <RequestLineItemsDialog
        open={!!detailRow}
        onClose={() => setDetailRow(null)}
        requestId={detailRow?.request_id ?? null}
        header={
          detailRow
            ? {
                mrNumber: detailRow.mr_number,
                title: detailRow.mr_title,
                requesterName: detailRow.requester_name,
                mrCreatedAt: detailRow.mr_created_at,
                deliveryDate: detailRow.delivery_date,
              }
            : null
        }
      />

      {/* NEW: Initial PO # click -> offer detail, same in-place dialog pattern */}
      <OfferDetailDialog
        open={!!offerDetailRow}
        onClose={() => setOfferDetailRow(null)}
        requestId={offerDetailRow?.request_id ?? null}
        initialPoNumber={offerDetailRow?.initial_po_number}
      />
    </Box>
  );
}