import { useCallback, useEffect, useState } from "react";
import {
  Alert, Box, Button, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogContentText,
  DialogTitle, Grid, IconButton, Link, MenuItem, Paper, Table, TableBody, TableCell, TableContainer,
  TableHead, TableRow, TextField, Tooltip, Typography,
} from "@mui/material";
import { PictureAsPdf } from "@mui/icons-material";
import { supabase } from "../../lib/supabaseClient";
import { buildPoPdf } from "./pdfGenerator";
import PurchaseOrderDetailDialog from "../finance/PurchaseOrderDetailDialog";




// PO-centric search/status screen ("Procurement Info" in the reference —
// intentionally a lookup screen, not "...Edit": it surfaces the same
// lifecycle actions as ProcurementTrack.tsx (share / confirm delivered /
// settle manually) per row, scoped by search filters instead of "my
// submitted offers". No raw PO field editing here.
//
// PDF icon: regenerates the PO PDF fresh on every click (via
// get_po_pdf_data -> jsPDF -> upload to the po-documents bucket ->
// record_po_pdf), so it always reflects current data rather than
// serving a possibly-stale cached file.
//
// Initial PO # / PO # click: opens PurchaseOrderDetailDialog in place --
// same "read-only preview instead of navigating away" pattern as the MR #
// link in RequestTracking.tsx. Backed by the get_po_detail() RPC.

interface Organization { id: string; company_code: string; site_name: string; }

interface InfoRow {
  request_id: string;
  purchase_order_id: string;
  initial_po_number: string | null;
  po_number: string;
  po_total: number;
  currency: string;
  company: string;
  requester_name: string;
  mr_originator_name: string | null;
  mr_title: string;
  mr_number: string;
  po_date: string;
  delivery_date: string | null;
  shared_with_supplier: boolean;
  delivered_at: string | null;
  completed_at: string | null;
  po_status: "pending" | "shared" | "delivered" | "completed";
  pdf_storage_path: string | null;
  pdf_generated_at: string | null;
}

const STATUS_OPTIONS = ["All", "pending", "shared", "delivered", "completed"];

const emptyFilters = {
  organization_id: "",
  initial_po_number: "",
  company: "",
  purchaser: "",
  mr_number: "",
  po_number: "",
  po_status: "All",
};

function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc("am_i_finance").then(({ data, error }) => setIsFinance(error ? false : Boolean(data)));
  }, []);
  return isFinance;
}

export default function ProcurementInfo() {
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [filters, setFilters] = useState(emptyFilters);
  const [rows, setRows] = useState<InfoRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [actionSubmitting, setActionSubmitting] = useState<string | null>(null);
  const [pdfGenerating, setPdfGenerating] = useState<string | null>(null);
  const isFinance = useFinanceAccess();

  const [settleTarget, setSettleTarget] = useState<InfoRow | null>(null);
  const [settleReason, setSettleReason] = useState("");
  const [settleError, setSettleError] = useState<string | null>(null);
  const [settleSubmitting, setSettleSubmitting] = useState(false);

  // Purchase order whose read-only detail dialog is currently open, if any
  // (set by clicking Initial PO # or PO #).
  const [poDetailId, setPoDetailId] = useState<string | null>(null);

  useEffect(() => {
    supabase.from("organizations").select("id, company_code, site_name").eq("is_active", true)
      .then(({ data }) => setOrganizations((data ?? []) as Organization[]));
  }, []);

  const runSearch = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase.rpc("get_procurement_info", {
      p_organization_id: filters.organization_id || null,
      p_initial_po_number: filters.initial_po_number || null,
      p_company: filters.company || null,
      p_purchaser: filters.purchaser || null,
      p_mr_number: filters.mr_number || null,
      p_po_number: filters.po_number || null,
      p_po_status: filters.po_status || null,
    });
    setLoading(false);
    if (error) setError(error.message);
    else setRows((data ?? []) as InfoRow[]);
  }, [filters]);

  useEffect(() => { runSearch(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const setField = (key: keyof typeof filters) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setFilters((f) => ({ ...f, [key]: e.target.value }));

  const shareWithSupplier = async (poId: string) => {
    setActionSubmitting(poId);
    const { error } = await supabase.rpc("share_purchase_order", { p_purchase_order_id: poId });
    setActionSubmitting(null);
    if (error) setError(error.message);
    else runSearch();
  };

  const confirmDelivered = async (poId: string) => {
    setActionSubmitting(poId);
    const { error } = await supabase.rpc("confirm_po_delivered", { p_purchase_order_id: poId });
    setActionSubmitting(null);
    if (error) setError(error.message);
    else runSearch();
  };

  const openSettleDialog = (row: InfoRow) => {
    setSettleTarget(row);
    setSettleReason("");
    setSettleError(null);
  };

  const confirmSettle = async () => {
    if (!settleTarget) return;
    if (settleReason.trim().length === 0) {
      setSettleError("A reason is required to mark a purchase order settled manually.");
      return;
    }
    setSettleSubmitting(true);
    const { error } = await supabase.rpc("complete_purchase_order_manually", {
      p_purchase_order_id: settleTarget.purchase_order_id,
      p_reason: settleReason.trim(),
    });
    setSettleSubmitting(false);
    if (error) setSettleError(error.message);
    else { setSettleTarget(null); runSearch(); }
  };

  const viewPdf = async (row: InfoRow) => {
    setPdfGenerating(row.purchase_order_id);
    setError(null);
    try {
      const { data, error: fetchErr } = await supabase
        .rpc("get_po_pdf_data", { p_purchase_order_id: row.purchase_order_id })
        .single();
      if (fetchErr || !data) throw new Error(fetchErr?.message ?? "Could not load PO data for PDF");

      const blob = buildPoPdf(data as any);

      // Get tenant id for the storage path prefix (RLS requires it).
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

  const exportCsv = () => {
    const headers = [
      "Initial PO #", "PO #", "PO Total", "Currency", "Company", "Requester",
      "MR Originator", "MR Title", "MR #", "PO Date", "Delivery Date", "Status",
    ];
    const lines = rows.map((r) => [
      r.initial_po_number ?? "", r.po_number, r.po_total, r.currency, r.company,
      r.requester_name, r.mr_originator_name ?? "", r.mr_title, r.mr_number,
      r.po_date, r.delivery_date ?? "", r.po_status,
    ].map((v) => `"${String(v).replace(/"/g, '""')}"`).join(","));
    const blob = new Blob([[headers.join(","), ...lines].join("\n")], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "procurement-info.csv";
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <Box sx={{ maxWidth: 1400, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>Procurement info</Typography>

      <Paper variant="outlined" sx={{ p: 2, mb: 3 }}>
        <Grid container spacing={2}>
          <Grid item xs={12} sm={4}>
            <TextField select fullWidth size="small" label="Organization"
              value={filters.organization_id}
              onChange={(e) => setFilters((f) => ({ ...f, organization_id: e.target.value }))}>
              <MenuItem value="">All</MenuItem>
              {organizations.map((o) => (
                <MenuItem key={o.id} value={o.id}>{o.company_code} - {o.site_name}</MenuItem>
              ))}
            </TextField>
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Initial PO #" value={filters.initial_po_number} onChange={setField("initial_po_number")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="PO #" value={filters.po_number} onChange={setField("po_number")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Company" value={filters.company} onChange={setField("company")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="Purchaser" value={filters.purchaser} onChange={setField("purchaser")} />
          </Grid>

          <Grid item xs={6} sm={2}>
            <TextField fullWidth size="small" label="MR #" value={filters.mr_number} onChange={setField("mr_number")} />
          </Grid>
          <Grid item xs={6} sm={2}>
            <TextField select fullWidth size="small" label="PO Status"
              value={filters.po_status}
              onChange={(e) => setFilters((f) => ({ ...f, po_status: e.target.value }))}>
              {STATUS_OPTIONS.map((s) => <MenuItem key={s} value={s}>{s}</MenuItem>)}
            </TextField>
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

      <TableContainer component={Paper} variant="outlined">
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Initial PO #</TableCell>
              <TableCell>PO #</TableCell>
              <TableCell align="right">PO Total</TableCell>
              <TableCell>Curr.</TableCell>
              <TableCell>Company</TableCell>
              <TableCell>Requester</TableCell>
              <TableCell>MR Originator</TableCell>
              <TableCell>MR Title</TableCell>
              <TableCell>PO Date</TableCell>
              <TableCell>Delivery Date</TableCell>
              <TableCell>Status</TableCell>
              <TableCell align="center">PDF</TableCell>
              <TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => {
              const isBusy = actionSubmitting === r.purchase_order_id;
              const isPdfBusy = pdfGenerating === r.purchase_order_id;
              return (
                <TableRow key={r.purchase_order_id} hover>
                  <TableCell>
                    {r.initial_po_number ? (
                      <Link component="button" variant="body2" onClick={() => setPoDetailId(r.purchase_order_id)}>
                        {r.initial_po_number}
                      </Link>
                    ) : (
                      "—"
                    )}
                  </TableCell>
                  <TableCell>
                    <Link component="button" variant="body2" onClick={() => setPoDetailId(r.purchase_order_id)}>
                      {r.po_number}
                    </Link>
                  </TableCell>
                  <TableCell align="right">{r.po_total.toLocaleString()}</TableCell>
                  <TableCell>{r.currency}</TableCell>
                  <TableCell>{r.company}</TableCell>
                  <TableCell>{r.requester_name}</TableCell>
                  <TableCell>{r.mr_originator_name}</TableCell>
                  <TableCell>{r.mr_title}</TableCell>
                  <TableCell>{r.po_date}</TableCell>
                  <TableCell>{r.delivery_date}</TableCell>
                  <TableCell>
                    <Chip
                      size="small"
                      label={r.po_status}
                      color={
                        r.po_status === "completed" ? "primary" :
                        r.po_status === "delivered" ? "info" :
                        r.po_status === "shared" ? "success" : "warning"
                      }
                      variant={r.po_status === "completed" ? "filled" : "outlined"}
                    />
                  </TableCell>
                  <TableCell align="center">
                    <Tooltip title={r.pdf_generated_at ? `Last generated ${new Date(r.pdf_generated_at).toLocaleString()}` : "Generate PO PDF"}>
                      <span>
                        <IconButton size="small" disabled={isPdfBusy} onClick={() => viewPdf(r)}>
                          {isPdfBusy ? <CircularProgress size={16} /> : <PictureAsPdf fontSize="small" color="error" />}
                        </IconButton>
                      </span>
                    </Tooltip>
                  </TableCell>
                  <TableCell align="right">
                    {r.po_status === "completed" ? null
                      : r.po_status === "pending" ? (
                        <Button size="small" variant="outlined" disabled={isBusy} onClick={() => shareWithSupplier(r.purchase_order_id)}>
                          {isBusy ? "Sharing…" : "Share with supplier"}
                        </Button>
                      ) : r.po_status === "shared" ? (
                        <Button size="small" variant="contained" disabled={isBusy} onClick={() => confirmDelivered(r.purchase_order_id)}>
                          {isBusy ? "Confirming…" : "Confirm delivered"}
                        </Button>
                      ) : isFinance ? (
                        <Button size="small" variant="text" disabled={isBusy} onClick={() => openSettleDialog(r)}>
                          Mark settled manually
                        </Button>
                      ) : null}
                  </TableCell>
                </TableRow>
              );
            })}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={13} align="center">
                  <Typography color="text.secondary" sx={{ py: 3 }}>No purchase orders match these filters.</Typography>
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>

      <Dialog open={!!settleTarget} onClose={() => !settleSubmitting && setSettleTarget(null)} fullWidth maxWidth="sm">
        <DialogTitle>Mark settled manually — {settleTarget?.po_number}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            Use this only when payment happened outside the automatic invoice-paid path.
          </DialogContentText>
          <TextField autoFocus label="Reason (required)" multiline minRows={2} fullWidth
            value={settleReason} onChange={(e) => setSettleReason(e.target.value)} />
          {settleError && <Alert severity="error" sx={{ mt: 2 }}>{settleError}</Alert>}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setSettleTarget(null)} disabled={settleSubmitting}>Back</Button>
          <Button onClick={confirmSettle} variant="contained" disabled={settleSubmitting}>
            {settleSubmitting ? "Marking settled…" : "Confirm"}
          </Button>
        </DialogActions>
      </Dialog>

      <PurchaseOrderDetailDialog
        open={!!poDetailId}
        onClose={() => setPoDetailId(null)}
        purchaseOrderId={poDetailId}
      />
    </Box>
  );
}