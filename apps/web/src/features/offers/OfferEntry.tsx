import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
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
  Typography,
} from "@mui/material";
import { Link as RouterLink } from "react-router-dom";
import { supabase } from "../../lib/supabaseClient";
import type { QueuedRequest } from "@erp-platform/shared";

// Offer Entry — the Procurement/Logistics Expert's worklist.
//
// Multi-offer model: a request stays at the offer-entry stage while
// procurement logs competing vendor quotes (request_offers has no
// auto-advance trigger anymore -- see submit_offers_for_approval RPC).
// At least 2 offers are required before the request can be sent to
// Budget Controller; the DB enforces that minimum, this screen just
// mirrors it so the button is disabled with a clear reason instead of
// failing on submit. request_offers_insert_authorized RLS ties INSERT
// permission to the request's *current* stage requiring offer entry --
// once submit_offers_for_approval() moves the request to Budget
// Controller, further inserts are rejected server-side, so the list is
// naturally locked with no extra column needed.

const MIN_OFFERS_REQUIRED = 2;

interface OfferForm {
  vendor_name: string;
  quotation_amount: string;
  quantity: string;
}

const emptyOfferForm: OfferForm = { vendor_name: "", quotation_amount: "", quantity: "" };

export default function OfferEntry() {
  const [queue, setQueue] = useState<QueuedRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);

  const [offerTarget, setOfferTarget] = useState<QueuedRequest | null>(null);
  const [offerForm, setOfferForm] = useState<OfferForm>(emptyOfferForm);
  const [offerError, setOfferError] = useState<string | null>(null);
  const [offerSubmitting, setOfferSubmitting] = useState(false);

  const [submitTarget, setSubmitTarget] = useState<QueuedRequest | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitSubmitting, setSubmitSubmitting] = useState(false);

  const loadQueue = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    const { data, error } = await supabase.rpc("get_my_approval_queue");
    if (error) setLoadError(error.message);
    else setQueue((data ?? []) as QueuedRequest[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    loadQueue();
  }, [loadQueue]);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setCurrentUserId(data.user?.id ?? null);
    });
  }, []);

  // Everything still at an offer-entry stage -- regardless of how many
  // offers have been logged so far, since the request only leaves this
  // list once explicitly submitted to Budget Controller.
  const awaitingOffers = useMemo(
    () => queue.filter((r) => r.current_stage.requires_offer_entry),
    [queue]
  );

  const openOfferDialog = (request: QueuedRequest) => {
    setOfferTarget(request);
    setOfferForm({ ...emptyOfferForm, quantity: String(request.quantity ?? "") });
    setOfferError(null);
  };

  const closeOfferDialog = () => {
    if (offerSubmitting) return;
    setOfferTarget(null);
  };

  const confirmOffer = async () => {
    if (!offerTarget) return;

    const vendorName = offerForm.vendor_name.trim();
    const amount = Number(offerForm.quotation_amount);
    const quantity = offerForm.quantity.trim() ? Number(offerForm.quantity) : undefined;

    if (!vendorName) {
      setOfferError("Vendor name is required.");
      return;
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      setOfferError("Quotation amount must be a number greater than zero.");
      return;
    }
    if (quantity !== undefined && (!Number.isFinite(quantity) || quantity <= 0)) {
      setOfferError("Quantity must be a number greater than zero.");
      return;
    }

    const alreadyQuoted = offerTarget.offers?.some(
      (o) => o.vendor_name.trim().toLowerCase() === vendorName.toLowerCase()
    );
    if (alreadyQuoted) {
      setOfferError(
        "This vendor already has a quote on this request. Edit isn't supported yet -- use a different vendor name or check the existing list below."
      );
      return;
    }

    setOfferSubmitting(true);
    setOfferError(null);

    // Direct insert -- request_offers_insert_authorized RLS restricts
    // this to the offer-entry stage's assignee/delegate, and the
    // (request_id, vendor_name) unique constraint blocks a duplicate
    // quote from the same vendor on the same request.
    const { error } = await supabase.from("request_offers").insert({
      request_id: offerTarget.id,
      vendor_name: vendorName,
      quotation_amount: amount,
      ...(quantity !== undefined ? { quantity } : {}),
      submitted_by: currentUserId,
    });

    setOfferSubmitting(false);

    if (error) {
      setOfferError(error.message ?? "Could not record the offer. Try again.");
      return;
    }

    setOfferTarget(null);
    loadQueue();
  };

  const openSubmitDialog = (request: QueuedRequest) => {
    setSubmitTarget(request);
    setSubmitError(null);
  };

  const closeSubmitDialog = () => {
    if (submitSubmitting) return;
    setSubmitTarget(null);
  };

  const confirmSubmit = async () => {
    if (!submitTarget) return;

    setSubmitSubmitting(true);
    setSubmitError(null);

    const { error } = await supabase.rpc("submit_offers_for_approval", {
      p_request_id: submitTarget.id,
    });

    setSubmitSubmitting(false);

    if (error) {
      setSubmitError(error.message ?? "Could not send this request for approval. Try again.");
      return;
    }

    setSubmitTarget(null);
    loadQueue();
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
    <Box sx={{ maxWidth: 1100, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>
        Offer entry
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Log competing vendor quotes for each request -- at least {MIN_OFFERS_REQUIRED} are required
        before you can send it to Budget Controller. They'll pick the winning offer at approval;
        once sent, this list locks and no more quotes can be added.
      </Typography>

      {awaitingOffers.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">Nothing waiting on a quote right now.</Typography>
          <Button component={RouterLink} to="/approvals" variant="outlined" sx={{ mt: 2 }}>
            View full approval queue
          </Button>
        </Paper>
      ) : (
        <Stack spacing={2}>
          {awaitingOffers.map((r) => {
            const offers = r.offers ?? [];
            const canSubmit = offers.length >= MIN_OFFERS_REQUIRED;

            return (
              <Card key={r.id} variant="outlined">
                <CardContent>
                  <Stack
                    direction={{ xs: "column", sm: "row" }}
                    justifyContent="space-between"
                    alignItems={{ sm: "flex-start" }}
                    spacing={1}
                  >
                    <Box>
                      <Typography variant="subtitle1" fontWeight={600}>
                        {r.item_description}
                      </Typography>
                      <Typography variant="body2" color="text.secondary">
                        {r.requester.name} • {r.department.name} • {r.cost_center.project_code} • Qty {r.quantity}
                      </Typography>
                    </Box>
                    <Chip
                      size="small"
                      label={`${offers.length} offer${offers.length === 1 ? "" : "s"} logged`}
                      color={canSubmit ? "success" : "default"}
                      variant="outlined"
                    />
                  </Stack>

                  {offers.length > 0 && (
                    <TableContainer sx={{ mt: 2 }}>
                      <Table size="small">
                        <TableHead>
                          <TableRow>
                            <TableCell>Vendor</TableCell>
                            <TableCell align="right">Quotation</TableCell>
                            <TableCell align="right">Qty</TableCell>
                            <TableCell>Submitted</TableCell>
                          </TableRow>
                        </TableHead>
                        <TableBody>
                          {offers.map((o) => (
                            <TableRow key={o.id}>
                              <TableCell>{o.vendor_name}</TableCell>
                              <TableCell align="right">{o.quotation_amount.toLocaleString()}</TableCell>
                              <TableCell align="right">{o.quantity}</TableCell>
                              <TableCell>{new Date(o.submitted_at).toLocaleDateString()}</TableCell>
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    </TableContainer>
                  )}

                  <Divider sx={{ my: 2 }} />

                  <Stack direction="row" spacing={1} justifyContent="flex-end">
                    <Button size="small" variant="outlined" onClick={() => openOfferDialog(r)}>
                      Add offer
                    </Button>
                    <Button
                      size="small"
                      variant="contained"
                      color="warning"
                      onClick={() => openSubmitDialog(r)}
                      disabled={!canSubmit}
                    >
                      Send to Budget Controller
                    </Button>
                  </Stack>
                  {!canSubmit && (
                    <Typography
                      variant="caption"
                      color="text.secondary"
                      display="block"
                      textAlign="right"
                      sx={{ mt: 0.5 }}
                    >
                      {MIN_OFFERS_REQUIRED - offers.length} more offer
                      {MIN_OFFERS_REQUIRED - offers.length === 1 ? "" : "s"} needed
                    </Typography>
                  )}
                </CardContent>
              </Card>
            );
          })}
        </Stack>
      )}

      {/* Add offer dialog */}
      <Dialog open={!!offerTarget} onClose={closeOfferDialog} fullWidth maxWidth="sm">
        <DialogTitle>Add vendor offer — {offerTarget?.item_description}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            Record one vendor's quote. Add at least {MIN_OFFERS_REQUIRED} competing quotes before
            sending this request to Budget Controller.
          </DialogContentText>
          <Stack spacing={2}>
            <TextField
              autoFocus
              label="Vendor name"
              fullWidth
              value={offerForm.vendor_name}
              onChange={(e) => setOfferForm((f) => ({ ...f, vendor_name: e.target.value }))}
            />
            <TextField
              label="Quotation amount"
              type="number"
              fullWidth
              value={offerForm.quotation_amount}
              onChange={(e) => setOfferForm((f) => ({ ...f, quotation_amount: e.target.value }))}
              InputProps={{
                startAdornment: <InputAdornment position="start">UGX</InputAdornment>,
              }}
            />
            <TextField
              label="Quantity"
              type="number"
              fullWidth
              value={offerForm.quantity}
              onChange={(e) => setOfferForm((f) => ({ ...f, quantity: e.target.value }))}
              helperText="Defaults to the request's original quantity if left as-is."
            />
          </Stack>
          {offerError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {offerError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeOfferDialog} disabled={offerSubmitting}>
            Cancel
          </Button>
          <Button onClick={confirmOffer} variant="contained" disabled={offerSubmitting}>
            {offerSubmitting ? "Saving…" : "Save Offer"}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Send to Budget Controller confirmation */}
      <Dialog open={!!submitTarget} onClose={closeSubmitDialog} fullWidth maxWidth="sm">
        <DialogTitle>Send to Budget Controller — {submitTarget?.item_description}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            This locks the offer list for this request -- no more vendor quotes can be added
            afterward. Budget Controller will choose which offer wins.
          </DialogContentText>
          {submitError && (
            <Alert severity="error" sx={{ mt: 1 }}>
              {submitError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeSubmitDialog} disabled={submitSubmitting}>
            Back
          </Button>
          <Button onClick={confirmSubmit} variant="contained" color="warning" disabled={submitSubmitting}>
            {submitSubmitting ? "Sending…" : "Send for approval"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}