import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";

// Flowchart steps 11-13:
// 11. PO to Procurement
// 12. Procurement shares PO with Supplier  <- "Share with supplier" action lives here now
// 13. Supplier supplies product -> Complete

interface ProcurementOrder {
  id: string;
  po_number: string;
  item_description: string;
  vendor_name: string;
  amount: number;
  request_id: string;
  shared_with_supplier: boolean;
  delivered_at: string | null;
  completed_at: string | null;
  request_status: string;
}

// "Complete" now sets itself automatically the moment a supplier invoice
// tied to the PO is fully paid (see try_complete_po / the two triggers on
// cash_bank_transactions and advance_payment_applications). This manual
// path is a Finance-only safety valve for cases that never touch either
// table -- write-offs, payments made outside the system, etc. It's
// enforced server-side by has_po_access() inside
// complete_purchase_order_manually(); the client-side finance check below
// just avoids showing a button that would only error for everyone else.
function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    supabase.rpc("am_i_finance").then(({ data, error }) => {
      if (cancelled) return;
      setIsFinance(error ? false : Boolean(data));
    });
    return () => {
      cancelled = true;
    };
  }, []);

  return isFinance;
}

export default function ProcurementTrack() {
  const [orders, setOrders] = useState<ProcurementOrder[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionSubmitting, setActionSubmitting] = useState<string | null>(null);
  const isFinance = useFinanceAccess();

  const [settleTarget, setSettleTarget] = useState<ProcurementOrder | null>(null);
  const [settleReason, setSettleReason] = useState("");
  const [settleError, setSettleError] = useState<string | null>(null);
  const [settleSubmitting, setSettleSubmitting] = useState(false);

  const loadOrders = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    // This RPC should return POs linked to offers submitted by current user
    // joined with request info for procurement tracking
    const { data, error } = await supabase.rpc("get_my_procurement_orders");
    if (error) setLoadError(error.message);
    else setOrders((data ?? []) as ProcurementOrder[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    loadOrders();
  }, [loadOrders]);

  // Step 12 — share the PO with the supplier.
  //
  // IMPORTANT: this used to be a direct `.update()` on purchase_orders,
  // gated by the purchase_orders_update_handoff RLS policy — but that
  // policy only grants access via has_po_access() (Finance/terminal-stage
  // assignees). The people who actually see this screen are offer
  // submitters (per get_my_procurement_orders()), not Finance, so that
  // direct update was failing RLS for the exact users this page is for.
  //
  // share_purchase_order() is a SECURITY DEFINER RPC that replicates the
  // three-way check the old share-po edge function used (offer submitter,
  // any approval-trail participant, or Finance) and is idempotent if the
  // PO is already marked shared.
  const shareWithSupplier = async (poId: string) => {
    setActionError(null);
    setActionSubmitting(poId);
    const { error } = await supabase.rpc("share_purchase_order", {
      p_purchase_order_id: poId,
    });
    setActionSubmitting(null);
    if (error) {
      setActionError(error.message ?? "Could not mark PO as shared with supplier");
    } else {
      loadOrders();
    }
  };

  // Step 13 — supplier delivered. Same authorization gap as above, same
  // fix: routed through confirm_po_delivered() instead of a direct update.
  const confirmDelivered = async (poId: string) => {
    setActionError(null);
    setActionSubmitting(poId);
    const { error } = await supabase.rpc("confirm_po_delivered", {
      p_purchase_order_id: poId,
    });
    setActionSubmitting(null);
    if (error) {
      setActionError(error.message ?? "Could not confirm delivery");
    } else {
      loadOrders();
    }
  };

  const openSettleDialog = (order: ProcurementOrder) => {
    setSettleTarget(order);
    setSettleReason("");
    setSettleError(null);
  };

  const closeSettleDialog = () => {
    if (settleSubmitting) return;
    setSettleTarget(null);
  };

  const confirmSettle = async () => {
    if (!settleTarget) return;
    if (settleReason.trim().length === 0) {
      setSettleError("A reason is required to mark a purchase order settled manually.");
      return;
    }

    setSettleSubmitting(true);
    setSettleError(null);

    const { error } = await supabase.rpc("complete_purchase_order_manually", {
      p_purchase_order_id: settleTarget.id,
      p_reason: settleReason.trim(),
    });

    setSettleSubmitting(false);

    if (error) {
      setSettleError(error.message ?? "Could not mark this purchase order settled. Try again.");
      return;
    }

    setSettleTarget(null);
    loadOrders();
  };

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (loadError) {
    return (
      <Alert severity="error" sx={{ maxWidth: 700, mx: "auto" }}>
        {loadError}
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1100, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>
        Procurement track
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Track purchase orders from finance sign-off through supplier delivery.
        Step 11: PO to Procurement · Step 12: Share with Supplier · Step 13: Supplier delivers.
        Orders complete automatically once their supplier invoice is paid in full.
      </Typography>

      {actionError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setActionError(null)}>
          {actionError}
        </Alert>
      )}

      {orders.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">
            No procurement orders yet — POs appear after finance sign-off and notification.
          </Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>PO</TableCell>
                <TableCell>Item</TableCell>
                <TableCell>Vendor</TableCell>
                <TableCell align="right">Amount</TableCell>
                <TableCell>Status</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {orders.map((o) => {
                const isComplete = !!o.completed_at;
                const isShared = o.shared_with_supplier;
                const isDelivered = !!o.delivered_at;
                const isBusy = actionSubmitting === o.id;

                return (
                  <TableRow key={o.id} hover>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600}>
                        {o.po_number}
                      </Typography>
                      <Typography variant="caption" color="text.secondary">
                        {o.request_id.slice(0, 8)}...
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">{o.item_description}</Typography>
                    </TableCell>
                    <TableCell>{o.vendor_name}</TableCell>
                    <TableCell align="right">{o.amount.toLocaleString()} UGX</TableCell>
                    <TableCell>
                      <Stack direction="row" spacing={0.5} flexWrap="wrap">
                        {isShared && (
                          <Chip size="small" label="Shared" color="success" variant="outlined" />
                        )}
                        {isDelivered && (
                          <Chip size="small" label="Delivered" color="info" variant="outlined" />
                        )}
                        {isComplete && (
                          <Chip size="small" label="Complete" color="primary" />
                        )}
                        {!isShared && !isDelivered && !isComplete && (
                          <Chip size="small" label="Pending share" color="warning" variant="outlined" />
                        )}
                      </Stack>
                    </TableCell>
                    <TableCell align="right">
                      {isComplete ? (
                        <Typography variant="body2" color="text.secondary">
                          Completed
                        </Typography>
                      ) : isShared ? (
                        isDelivered ? (
                          isFinance ? (
                            <Button
                              size="small"
                              variant="text"
                              disabled={isBusy}
                              onClick={() => openSettleDialog(o)}
                            >
                              Mark settled manually
                            </Button>
                          ) : (
                            <Typography variant="body2" color="text.secondary">
                              Delivered
                            </Typography>
                          )
                        ) : (
                          <Button
                            size="small"
                            variant="contained"
                            disabled={isBusy}
                            onClick={() => confirmDelivered(o.id)}
                          >
                            {isBusy ? "Confirming…" : "Confirm delivered"}
                          </Button>
                        )
                      ) : (
                        <Button
                          size="small"
                          variant="outlined"
                          disabled={isBusy}
                          onClick={() => shareWithSupplier(o.id)}
                        >
                          {isBusy ? "Sharing…" : "Share with supplier"}
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Dialog open={!!settleTarget} onClose={closeSettleDialog} fullWidth maxWidth="sm">
        <DialogTitle>Mark settled manually — {settleTarget?.po_number}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            Orders normally complete automatically once their supplier invoice is paid in full. Use this
            only when payment happened outside that path — e.g. a write-off, or a payment recorded
            without a matching invoice. This is logged against the PO's edit history.
          </DialogContentText>
          <TextField
            autoFocus
            label="Reason (required)"
            multiline
            minRows={2}
            fullWidth
            value={settleReason}
            onChange={(e) => setSettleReason(e.target.value)}
          />
          {settleError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {settleError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeSettleDialog} disabled={settleSubmitting}>
            Back
          </Button>
          <Button onClick={confirmSettle} variant="contained" disabled={settleSubmitting}>
            {settleSubmitting ? "Marking settled…" : "Confirm"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}