import { useEffect, useState } from "react";
import {
  Dialog, DialogTitle, DialogContent, IconButton, Table, TableBody, TableCell,
  TableHead, TableRow, Box, Typography, CircularProgress, Divider, Grid, Chip,
} from "@mui/material";
import CloseIcon from "@mui/icons-material/Close";
import { supabase } from "../../lib/supabaseClient";

interface LineItem {
  material_service: string;
  cost_code: string | null;
  place_of_use: string | null;
  quantity: number;
  unit_price: number | null;
  total: number | null;
  currency: string;
}

interface PoDetail {
  purchase_order_id: string;
  request_id: string;
  po_number: string;
  initial_po_number: string | null;
  vendor_name: string;
  po_amount: number;
  currency: string;
  generated_at: string;
  generated_by_name: string;
  shared_with_supplier: boolean;
  delivered_at: string | null;
  completed_at: string | null;
  mr_number: string;
  mr_title: string;
  mr_date: string;
  requester_name: string;
  delivery_date: string | null;
  // NEW: same optional fields the PO PDF (pdfGenerator.ts) prints, editable
  // from Finance's Edit dialog in PurchaseOrders.tsx. Shown here only when
  // set, so this preview stays consistent with what the generated PDF will
  // actually contain.
  project_sap_no: string | null;
  payment_conditions: string | null;
  terms_of_delivery: string | null;
  offer_quotation_amount: number | null;
  offer_quantity: number | null;
  offer_submitted_by_name: string | null;
  offer_submitted_at: string | null;
}

interface PurchaseOrderDetailDialogProps {
  open: boolean;
  onClose: () => void;
  purchaseOrderId: string | null;
}

// Read-only "Offer/PO Detail" dialog — the counterpart to
// RequestLineItemsDialog.tsx, opened by clicking Initial PO # / PO # in
// ProcurementInfo.tsx and RequestTracking.tsx instead of navigating away.
// Mirrors the reference "Proposal Title" popup (offer/vendor summary +
// MR line items), but built from what our schema actually has:
// purchase_orders doesn't store a foreign key to the winning offer, so
// the matching request_offers row is resolved server-side in
// get_po_detail() by (request_id, vendor_name) — the vendor that won
// becomes the PO's vendor_name, so this is a reliable join, not a guess
// per row of data. Line items are fetched the same way
// RequestLineItemsDialog does it, scoped to the PO's request_id.
export default function PurchaseOrderDetailDialog({ open, onClose, purchaseOrderId }: PurchaseOrderDetailDialogProps) {
  const [detail, setDetail] = useState<PoDetail | null>(null);
  const [items, setItems] = useState<LineItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open || !purchaseOrderId) return;
    setLoading(true);
    setError(null);
    setDetail(null);
    setItems([]);

    (async () => {
      const { data: poData, error: poErr } = await supabase
        .rpc("get_po_detail", { p_purchase_order_id: purchaseOrderId })
        .single();
      if (poErr || !poData) {
        setError(poErr?.message ?? "Could not load PO detail");
        setLoading(false);
        return;
      }
      const detail = poData as PoDetail;
      setDetail(detail);

      const { data: lineItems, error: liErr } = await supabase
        .from("request_line_items")
        .select("material_service, cost_code, place_of_use, quantity, unit_price, total, currency")
        .eq("request_id", detail.request_id);
      if (liErr) setError(liErr.message);
      setItems((lineItems ?? []) as LineItem[]);
      setLoading(false);
    })();
  }, [open, purchaseOrderId]);

  const status = detail
    ? detail.completed_at ? "completed"
    : detail.delivered_at ? "delivered"
    : detail.shared_with_supplier ? "shared"
    : "pending"
    : null;

  // Only show the PDF-reference row group at all if at least one of the
  // three fields has been filled in — most POs won't have these set yet,
  // and an all-dashes row adds noise without adding information.
  const hasReferenceFields =
    !!detail && (detail.project_sap_no || detail.payment_conditions || detail.terms_of_delivery);

  return (
    <Dialog open={open} onClose={onClose} maxWidth="md" fullWidth>
      <DialogTitle
        sx={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          bgcolor: "primary.main",
          color: "primary.contrastText",
        }}
      >
        PURCHASE ORDER DETAIL
        <IconButton size="small" onClick={onClose} sx={{ color: "inherit" }}>
          <CloseIcon fontSize="small" />
        </IconButton>
      </DialogTitle>
      <DialogContent sx={{ pt: 2 }}>
        {loading && (
          <Box sx={{ display: "flex", justifyContent: "center", py: 4 }}>
            <CircularProgress />
          </Box>
        )}

        {error && <Typography color="error">{error}</Typography>}

        {!loading && !error && detail && (
          <>
            <Grid container spacing={1} sx={{ mb: 2 }}>
              <Grid item xs={6}>
                <Typography variant="body2"><b>PO #:</b> {detail.po_number}</Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="body2"><b>Initial PO #:</b> {detail.initial_po_number ?? "—"}</Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="body2"><b>Vendor:</b> {detail.vendor_name}</Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="body2">
                  <b>Total:</b> {detail.po_amount?.toLocaleString()} {detail.currency}
                </Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="body2">
                  <b>Buyer:</b> {detail.generated_by_name}
                </Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="body2">
                  <b>PO Date:</b> {new Date(detail.generated_at).toLocaleDateString()}
                </Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="body2"><b>MR #:</b> {detail.mr_number}</Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="body2"><b>Requester:</b> {detail.requester_name}</Typography>
              </Grid>
              <Grid item xs={12}>
                <Typography variant="body2"><b>Description:</b> {detail.mr_title}</Typography>
              </Grid>
              {detail.offer_quotation_amount != null && (
                <Grid item xs={12}>
                  <Typography variant="body2">
                    <b>Winning offer:</b> {detail.offer_quotation_amount.toLocaleString()} {detail.currency}
                    {detail.offer_submitted_by_name ? ` — submitted by ${detail.offer_submitted_by_name}` : ""}
                    {detail.offer_submitted_at ? ` on ${new Date(detail.offer_submitted_at).toLocaleDateString()}` : ""}
                  </Typography>
                </Grid>
              )}
              {hasReferenceFields && (
                <>
                  {detail.project_sap_no && (
                    <Grid item xs={6}>
                      <Typography variant="body2"><b>Project SAP no:</b> {detail.project_sap_no}</Typography>
                    </Grid>
                  )}
                  {detail.payment_conditions && (
                    <Grid item xs={6}>
                      <Typography variant="body2"><b>Payment conditions:</b> {detail.payment_conditions}</Typography>
                    </Grid>
                  )}
                  {detail.terms_of_delivery && (
                    <Grid item xs={12}>
                      <Typography variant="body2"><b>Terms of delivery:</b> {detail.terms_of_delivery}</Typography>
                    </Grid>
                  )}
                </>
              )}
              <Grid item xs={12}>
                <Chip
                  size="small"
                  label={status}
                  color={
                    status === "completed" ? "primary" :
                    status === "delivered" ? "info" :
                    status === "shared" ? "success" : "warning"
                  }
                  variant={status === "completed" ? "filled" : "outlined"}
                />
              </Grid>
            </Grid>
            <Divider sx={{ mb: 2 }} />

            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Material / Service</TableCell>
                  <TableCell>Cost Code</TableCell>
                  <TableCell>Place of Use</TableCell>
                  <TableCell align="right">Qty</TableCell>
                  <TableCell align="right">Unit Price</TableCell>
                  <TableCell align="right">Total</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {items.map((li, i) => (
                  <TableRow key={i}>
                    <TableCell>{li.material_service}</TableCell>
                    <TableCell>{li.cost_code}</TableCell>
                    <TableCell>{li.place_of_use}</TableCell>
                    <TableCell align="right">{li.quantity}</TableCell>
                    <TableCell align="right">
                      {li.unit_price?.toLocaleString()} {li.currency}
                    </TableCell>
                    <TableCell align="right">
                      {li.total?.toLocaleString()} {li.currency}
                    </TableCell>
                  </TableRow>
                ))}
                {items.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={6} align="center">
                      <Typography color="text.secondary" sx={{ py: 2 }}>
                        No line items.
                      </Typography>
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}