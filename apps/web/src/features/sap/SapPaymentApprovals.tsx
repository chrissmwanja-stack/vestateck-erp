import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Alert, Box, Button, Chip, CircularProgress, Dialog, DialogActions,
  DialogContent, DialogTitle, LinearProgress, MenuItem, Paper, Stack,
  Table, TableBody, TableCell, TableContainer, TableHead, TableRow,
  TextField, Typography,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";

interface SapPayment {
  id: string;
  amount: number;
  status: "pending_sap" | "sent_to_sap" | "paid" | "rejected";
  sap_reference: string | null;
  created_at: string;
}

interface PurchaseOrderRow {
  id: string;
  po_number: string;
  vendor_name: string;
  amount: number;
  generated_at: string;
  sap_payments: SapPayment[];
}

type PaymentStatusFilter = "all" | "unpaid" | "partial" | "paid";

function paidTotal(payments: SapPayment[]): number {
  return payments
    .filter((p) => p.status === "paid")
    .reduce((sum, p) => sum + Number(p.amount), 0);
}

function statusChip(po: PurchaseOrderRow) {
  const paid = paidTotal(po.sap_payments);
  const total = Number(po.amount);
  if (paid <= 0) return <Chip size="small" label="Pending SAP" color="warning" />;
  if (paid >= total) return <Chip size="small" label="Paid" color="success" />;
  return <Chip size="small" label={`Partially Paid (${Math.round((paid / total) * 100)}%)`} color="info" />;
}

export default function SapPaymentApprovals() {
  const [orders, setOrders] = useState<PurchaseOrderRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [filter, setFilter] = useState<PaymentStatusFilter>("all");

  const [paymentTarget, setPaymentTarget] = useState<PurchaseOrderRow | null>(null);
  const [paymentAmount, setPaymentAmount] = useState("");
  const [paymentStatus, setPaymentStatus] = useState<SapPayment["status"]>("pending_sap");
  const [paymentRef, setPaymentRef] = useState("");
  const [paymentSubmitting, setPaymentSubmitting] = useState(false);
  const [paymentError, setPaymentError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("purchase_orders")
      .select("id, po_number, vendor_name, amount, generated_at, sap_payments(id, amount, status, sap_reference, created_at)")
      .order("generated_at", { ascending: false })
      .limit(20);
    setLoadError(error ? error.message : null);
    setOrders((data ?? []) as unknown as PurchaseOrderRow[]);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const filteredOrders = useMemo(() => {
    if (filter === "all") return orders;
    return orders.filter((po) => {
      const paid = paidTotal(po.sap_payments);
      const total = Number(po.amount);
      if (filter === "unpaid") return paid <= 0;
      if (filter === "paid") return paid >= total;
      return paid > 0 && paid < total; // partial
    });
  }, [orders, filter]);

  const openPaymentDialog = (po: PurchaseOrderRow) => {
    setPaymentTarget(po);
    const remaining = Number(po.amount) - paidTotal(po.sap_payments);
    setPaymentAmount(remaining > 0 ? String(remaining) : "");
    setPaymentStatus("pending_sap");
    setPaymentRef("");
    setPaymentError(null);
  };

  const closePaymentDialog = () => { if (!paymentSubmitting) setPaymentTarget(null); };

  const submitPayment = async () => {
    if (!paymentTarget) return;
    setPaymentError(null);

    const amount = Number(paymentAmount);
    if (!paymentAmount || Number.isNaN(amount) || amount <= 0) {
      setPaymentError("Enter a valid payment amount.");
      return;
    }

    const remaining = Number(paymentTarget.amount) - paidTotal(paymentTarget.sap_payments);
    if (amount > remaining) {
      setPaymentError(`Amount exceeds remaining balance of ${remaining.toLocaleString()} UGX.`);
      return;
    }

    setPaymentSubmitting(true);
    const { error } = await supabase.from("sap_payments").insert({
      purchase_order_id: paymentTarget.id,
      amount,
      status: paymentStatus,
      sap_reference: paymentRef.trim() || null,
    });
    setPaymentSubmitting(false);

    if (error) {
      setPaymentError(error.message);
      return;
    }

    setPaymentTarget(null);
    load();
  };

  if (loading) return <Box display="flex" justifyContent="center" py={6}><CircularProgress /></Box>;
  if (loadError) return <Alert severity="error">{loadError}</Alert>;

  return (
    <Box sx={{ maxWidth: 1200, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>SAP Payment Approvals</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Review purchase orders and record payments against them. A PO can be paid in full or in stages —
        status below reflects the sum of recorded payments, not a single flag.
      </Typography>

      <TextField
        select
        size="small"
        label="Filter"
        value={filter}
        onChange={(e) => setFilter(e.target.value as PaymentStatusFilter)}
        sx={{ mb: 2, width: 220 }}
      >
        <MenuItem value="all">All</MenuItem>
        <MenuItem value="unpaid">Pending SAP</MenuItem>
        <MenuItem value="partial">Partially Paid</MenuItem>
        <MenuItem value="paid">Paid</MenuItem>
      </TextField>

      <Paper variant="outlined">
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>PO Number</TableCell>
                <TableCell>Vendor</TableCell>
                <TableCell align="right">Amount (UGX)</TableCell>
                <TableCell align="right">Paid (UGX)</TableCell>
                <TableCell>Progress</TableCell>
                <TableCell>Generated</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filteredOrders.map((po) => {
                const paid = paidTotal(po.sap_payments);
                const total = Number(po.amount);
                const pct = total > 0 ? Math.min(100, (paid / total) * 100) : 0;
                return (
                  <TableRow key={po.id} hover>
                    <TableCell>{po.po_number}</TableCell>
                    <TableCell>{po.vendor_name}</TableCell>
                    <TableCell align="right">{total.toLocaleString()}</TableCell>
                    <TableCell align="right">{paid.toLocaleString()}</TableCell>
                    <TableCell sx={{ minWidth: 120 }}>
                      <LinearProgress variant="determinate" value={pct} />
                    </TableCell>
                    <TableCell>{new Date(po.generated_at).toLocaleDateString()}</TableCell>
                    <TableCell>{statusChip(po)}</TableCell>
                    <TableCell>
                      <Button size="small" onClick={() => openPaymentDialog(po)} disabled={paid >= total}>
                        Record Payment
                      </Button>
                    </TableCell>
                  </TableRow>
                );
              })}
              {filteredOrders.length === 0 && (
                <TableRow>
                  <TableCell colSpan={8}>
                    <Typography variant="body2" color="text.secondary" sx={{ py: 2, textAlign: "center" }}>
                      No purchase orders match this filter.
                    </Typography>
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      <Dialog open={!!paymentTarget} onClose={closePaymentDialog} maxWidth="sm" fullWidth>
        <DialogTitle>Record Payment — {paymentTarget?.po_number}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            {paymentTarget && (
              <Typography variant="body2" color="text.secondary">
                Remaining balance: {(Number(paymentTarget.amount) - paidTotal(paymentTarget.sap_payments)).toLocaleString()} UGX
                {" "}of {Number(paymentTarget.amount).toLocaleString()} UGX total.
              </Typography>
            )}
            <TextField
              label="Payment Amount (UGX)"
              type="number"
              fullWidth
              value={paymentAmount}
              onChange={(e) => setPaymentAmount(e.target.value)}
            />
            <TextField
              select
              label="Status"
              fullWidth
              value={paymentStatus}
              onChange={(e) => setPaymentStatus(e.target.value as SapPayment["status"])}
            >
              <MenuItem value="pending_sap">Pending SAP</MenuItem>
              <MenuItem value="sent_to_sap">Sent to SAP</MenuItem>
              <MenuItem value="paid">Paid</MenuItem>
              <MenuItem value="rejected">Rejected</MenuItem>
            </TextField>
            <TextField
              label="SAP Reference (optional)"
              fullWidth
              value={paymentRef}
              onChange={(e) => setPaymentRef(e.target.value)}
            />
            {paymentError && <Alert severity="error">{paymentError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={closePaymentDialog}>Cancel</Button>
          <Button onClick={submitPayment} variant="contained" disabled={paymentSubmitting}>
            {paymentSubmitting ? "Saving…" : "Save Payment"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}