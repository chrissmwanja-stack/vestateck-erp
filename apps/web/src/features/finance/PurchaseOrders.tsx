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
  Divider,
  InputAdornment,
  Paper,
  Stack,
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
import { Link as RouterLink } from "react-router-dom";
import { supabase } from "../../lib/supabaseClient";
import type { FinancePurchaseOrder, PoEdit } from "@erp-platform/shared";

interface EditForm {
  vendor_name: string;
  amount: string;
  reason: string;
  // NEW: fields that only appear on the printed "Purchase Order and
  // Approval Form" PDF (pdfGenerator.ts) -- optional, blank until someone
  // fills them in here.
  project_sap_no: string;
  payment_conditions: string;
  terms_of_delivery: string;
}

const emptyEditForm: EditForm = {
  vendor_name: "",
  amount: "",
  reason: "",
  project_sap_no: "",
  payment_conditions: "",
  terms_of_delivery: "",
};

export default function PurchaseOrders() {
  const [orders, setOrders] = useState<FinancePurchaseOrder[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  // --- Edit dialog ---
  const [editTarget, setEditTarget] = useState<FinancePurchaseOrder | null>(null);
  const [editForm, setEditForm] = useState<EditForm>(emptyEditForm);
  const [editError, setEditError] = useState<string | null>(null);
  const [editSubmitting, setEditSubmitting] = useState(false);

  // --- History dialog ---
  const [historyTarget, setHistoryTarget] = useState<FinancePurchaseOrder | null>(null);
  const [history, setHistory] = useState<PoEdit[]>([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);

  const loadOrders = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    const { data, error } = await supabase.rpc("get_my_purchase_orders");
    if (error) setLoadError(error.message);
    else setOrders((data ?? []) as FinancePurchaseOrder[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    loadOrders();
  }, [loadOrders]);

  // --- Edit dialog handlers ---
  const openEditDialog = (po: FinancePurchaseOrder) => {
    setEditTarget(po);
    setEditForm({
      vendor_name: po.vendor_name,
      amount: String(po.amount),
      reason: "",
      project_sap_no: po.project_sap_no ?? "",
      payment_conditions: po.payment_conditions ?? "",
      terms_of_delivery: po.terms_of_delivery ?? "",
    });
    setEditError(null);
  };

  const closeEditDialog = () => {
    if (editSubmitting) return;
    setEditTarget(null);
  };

  const confirmEdit = async () => {
    if (!editTarget) return;

    const vendorName = editForm.vendor_name.trim();
    const amount = Number(editForm.amount);
    const reason = editForm.reason.trim();
    const projectSapNo = editForm.project_sap_no.trim();
    const paymentConditions = editForm.payment_conditions.trim();
    const termsOfDelivery = editForm.terms_of_delivery.trim();

    if (!vendorName) {
      setEditError("Vendor name cannot be empty.");
      return;
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      setEditError("Amount must be a number greater than zero.");
      return;
    }
    if (!reason) {
      setEditError("A reason is required for every PO edit.");
      return;
    }

    const nothingChanged =
      vendorName === editTarget.vendor_name &&
      amount === Number(editTarget.amount) &&
      projectSapNo === (editTarget.project_sap_no ?? "") &&
      paymentConditions === (editTarget.payment_conditions ?? "") &&
      termsOfDelivery === (editTarget.terms_of_delivery ?? "");

    if (nothingChanged) {
      setEditError("Nothing has changed — update a field, or cancel.");
      return;
    }

    setEditSubmitting(true);
    setEditError(null);

    // Direct RPC — edit_purchase_order() is the only legitimate path to
    // change these fields: it logs the diff to po_edits, then updates
    // purchase_orders through a narrow, transaction-scoped escape hatch in
    // the immutability trigger. Direct client .update() calls on
    // vendor_name/amount are still blocked by
    // protect_po_immutable_fields(); project_sap_no/payment_conditions/
    // terms_of_delivery aren't guarded by that trigger, but go through
    // this RPC too so every PO change lands in the same edit history.
    //
    // NOTE: parameter keys must match the SQL function's p_-prefixed
    // argument names exactly — PostgREST matches RPC calls by parameter
    // name, not position, so unprefixed keys fail with "could not find
    // the function ... in the schema cache" rather than a clearer error.
    // Fields left blank are sent as null, which the RPC coalesces against
    // the current value (a no-op) -- so this call only ever changes what
    // was actually edited, even though it always sends all six params.
    const { error } = await supabase.rpc("edit_purchase_order", {
      p_purchase_order_id: editTarget.id,
      p_vendor_name: vendorName,
      p_amount: amount,
      p_reason: reason,
      p_project_sap_no: projectSapNo || null,
      p_payment_conditions: paymentConditions || null,
      p_terms_of_delivery: termsOfDelivery || null,
    });

    setEditSubmitting(false);

    if (error) {
      setEditError(error.message ?? "Could not save the edit. Try again.");
      return;
    }

    setEditTarget(null);
    loadOrders();
  };

  // --- History dialog handlers ---
  const openHistory = async (po: FinancePurchaseOrder) => {
    setHistoryTarget(po);
    setHistory([]);
    setHistoryError(null);
    setHistoryLoading(true);

    const { data, error } = await supabase.rpc("get_po_edit_history", { po_id: po.id });
    setHistoryLoading(false);

    if (error) setHistoryError(error.message);
    else setHistory((data ?? []) as PoEdit[]);
  };

  const closeHistory = () => {
    setHistoryTarget(null);
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
      <Alert severity="error" sx={{ maxWidth: 640, mx: "auto" }}>
        {loadError}
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1200, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>
        Purchase orders
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Purchase orders generated when a request clears its final approval
        stage (step 8a / 8b). Finance performs final sign-off (step 9) here —
        the PO already exists, so this view does not create a new one. Vendor
        name and amount can be corrected if needed — every change requires a
        reason and is logged. Sharing the PO with the supplier (step 12) is a
        Procurement action and lives on the Procurement track page.
      </Typography>

      {orders.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">No purchase orders yet.</Typography>
          <Button component={RouterLink} to="/approvals" variant="outlined" sx={{ mt: 2 }}>
            Go to approval queue
          </Button>
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>PO number</TableCell>
                <TableCell>Item</TableCell>
                <TableCell>Requester</TableCell>
                <TableCell>Department</TableCell>
                <TableCell>Vendor</TableCell>
                <TableCell align="right">Amount</TableCell>
                <TableCell>Generated</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {orders.map((po) => (
                <TableRow key={po.id} hover>
                  <TableCell>
                    <Typography variant="body2" fontWeight={600}>
                      {po.po_number}
                    </Typography>
                    {po.edit_count > 0 && (
                      <Tooltip
                        title={
                          po.last_edited_by
                            ? `Last edited by ${po.last_edited_by.name}`
                            : "This PO has been edited"
                        }
                      >
                        <Chip
                          size="small"
                          variant="outlined"
                          label={`Edited ×${po.edit_count}`}
                          sx={{ mt: 0.5 }}
                        />
                      </Tooltip>
                    )}
                  </TableCell>
                  <TableCell>
                    <Typography variant="body2">{po.request.item_description}</Typography>
                    <Typography variant="caption" color="text.secondary">
                      Request: {po.request.id.slice(0, 8)}...
                    </Typography>
                  </TableCell>
                  <TableCell>{po.requester.name}</TableCell>
                  <TableCell>{po.department.name}</TableCell>
                  <TableCell>{po.vendor_name}</TableCell>
                  <TableCell align="right">
                    {po.amount.toLocaleString()}{" "}
                    <Typography component="span" variant="caption" color="text.secondary">
                      UGX
                    </Typography>
                  </TableCell>
                  <TableCell>{new Date(po.generated_at).toLocaleDateString()}</TableCell>
                  <TableCell align="right">
                    <Stack direction="row" spacing={1} justifyContent="flex-end">
                      <Button size="small" onClick={() => openHistory(po)}>
                        History
                      </Button>
                      <Button size="small" variant="contained" onClick={() => openEditDialog(po)}>
                        Edit
                      </Button>
                    </Stack>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {/* Edit dialog */}
      <Dialog open={!!editTarget} onClose={closeEditDialog} fullWidth maxWidth="sm">
        <DialogTitle>Edit purchase order — {editTarget?.po_number}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            Changes are logged with the reason below — this doesn't regenerate
            the PO document, it corrects the record.
          </DialogContentText>
          <Stack spacing={2}>
            <TextField
              autoFocus
              label="Vendor name"
              fullWidth
              value={editForm.vendor_name}
              onChange={(e) => setEditForm((f) => ({ ...f, vendor_name: e.target.value }))}
            />
            <TextField
              label="Amount"
              type="number"
              fullWidth
              value={editForm.amount}
              onChange={(e) => setEditForm((f) => ({ ...f, amount: e.target.value }))}
              InputProps={{
                startAdornment: <InputAdornment position="start">UGX</InputAdornment>,
              }}
            />

            <Divider>
              <Typography variant="caption" color="text.secondary">
                PDF fields (optional)
              </Typography>
            </Divider>

            <TextField
              label="Project SAP no"
              fullWidth
              value={editForm.project_sap_no}
              onChange={(e) => setEditForm((f) => ({ ...f, project_sap_no: e.target.value }))}
              helperText="Printed as PROJECT SAP NO on the PO PDF"
            />
            <TextField
              label="Payment conditions"
              fullWidth
              value={editForm.payment_conditions}
              onChange={(e) => setEditForm((f) => ({ ...f, payment_conditions: e.target.value }))}
              placeholder="e.g. C.H., 10 days credit"
            />
            <TextField
              label="Terms of delivery"
              fullWidth
              value={editForm.terms_of_delivery}
              onChange={(e) => setEditForm((f) => ({ ...f, terms_of_delivery: e.target.value }))}
            />

            <TextField
              label="Reason for change (required)"
              multiline
              minRows={2}
              fullWidth
              value={editForm.reason}
              onChange={(e) => setEditForm((f) => ({ ...f, reason: e.target.value }))}
            />
          </Stack>
          {editError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {editError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeEditDialog} disabled={editSubmitting}>
            Cancel
          </Button>
          <Button onClick={confirmEdit} variant="contained" disabled={editSubmitting}>
            {editSubmitting ? "Saving…" : "Save changes"}
          </Button>
        </DialogActions>
      </Dialog>

      {/* History dialog */}
      <Dialog open={!!historyTarget} onClose={closeHistory} fullWidth maxWidth="sm">
        <DialogTitle>Edit history — {historyTarget?.po_number}</DialogTitle>
        <DialogContent>
          {historyLoading ? (
            <Box display="flex" justifyContent="center" py={4}>
              <CircularProgress size={28} />
            </Box>
          ) : historyError ? (
            <Alert severity="error">{historyError}</Alert>
          ) : history.length === 0 ? (
            <Typography color="text.secondary">No edits recorded.</Typography>
          ) : (
            <Stack spacing={2} divider={<Divider flexItem />}>
              {history.map((h) => (
                <Box key={h.id}>
                  <Typography variant="body2" fontWeight={600}>
                    {h.editor.name} — {new Date(h.edited_at).toLocaleString()}
                  </Typography>
                  <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
                    {h.reason}
                  </Typography>
                  <Stack spacing={0.5}>
                    {Object.entries(h.changes).map(([field, change]) => (
                      <Typography key={field} variant="body2">
                        <strong>{field}:</strong> {String(change.old)} → {String(change.new)}
                      </Typography>
                    ))}
                  </Stack>
                </Box>
              ))}
            </Stack>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeHistory}>Close</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}