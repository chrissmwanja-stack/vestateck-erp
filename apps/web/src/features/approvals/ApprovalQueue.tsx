import { useCallback, useEffect, useMemo, useState } from "react";
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
  Tooltip,
  Typography,
} from "@mui/material";
import { Link as RouterLink } from "react-router-dom";
import { supabase } from "../../lib/supabaseClient";
import type { ApprovalDecision, QueuedRequest } from "@erp-platform/shared";

interface PendingDecision {
  request: QueuedRequest;
  decision: ApprovalDecision;
}

export default function ApprovalQueue() {
  const [queue, setQueue] = useState<QueuedRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [currentUserId, setCurrentUserId] = useState<string | null>(null);

  const [pending, setPending] = useState<PendingDecision | null>(null);
  const [comment, setComment] = useState("");
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionSubmitting, setActionSubmitting] = useState(false);

  // Cancel request — distinct from Reject. Reject is a workflow decision
  // recorded via record_approval_decision at the current stage. Cancel is
  // a separate action (cancel_request RPC) available to whoever can act on
  // the stage OR the original requester (requester side lives in
  // MyRequests.tsx). Kept as its own dialog/state rather than reusing the
  // approve/reject dialog since it doesn't take an ApprovalDecision.
  const [cancelTarget, setCancelTarget] = useState<QueuedRequest | null>(null);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelError, setCancelError] = useState<string | null>(null);
  const [cancelSubmitting, setCancelSubmitting] = useState(false);

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

  // Offer-entry and offer-approval rows now have dedicated homes:
  // - OfferEntry.tsx owns requires_offer_entry stages with no offer yet
  // - OfferApprovalPO.tsx owns stages with an offer already on file
  // This queue is the pre-offer chain (Cost Control Engineer, Cost
  // Control Manager) plus anything else that isn't offer-related, so it
  // stays a general catch-all without duplicating rows those two screens
  // already show. A request that's transiently at an offer-entry stage
  // AND already has an offer (shouldn't normally happen -- the insert
  // trigger advances the stage in the same transaction) still shows up
  // here rather than silently vanishing.
  const displayedQueue = useMemo(
    () =>
      queue.filter((r) => {
        const offerHandledElsewhere =
          (r.current_stage.requires_offer_entry && !r.latest_offer) ||
          (!r.current_stage.requires_offer_entry && !!r.latest_offer);
        return !offerHandledElsewhere;
      }),
    [queue]
  );

  const isBlockedAsOfferSubmitter = (r: QueuedRequest) =>
    r.current_stage.blocks_offer_submitter_approval &&
    !!r.latest_offer &&
    r.latest_offer.submitted_by === currentUserId;

  const hasExistingPO = (r: QueuedRequest) => !!(r as any).purchase_order;

  const openDialog = (request: QueuedRequest, decision: ApprovalDecision) => {
    setPending({ request, decision });
    setComment("");
    setActionError(null);
  };

  const closeDialog = () => {
    if (actionSubmitting) return;
    setPending(null);
  };

  const confirmDecision = async () => {
    if (!pending) return;
    if (pending.decision === "rejected" && comment.trim().length === 0) {
      setActionError("A comment is required when rejecting — it cancels the request outright.");
      return;
    }

    setActionSubmitting(true);
    setActionError(null);

    // Direct RPC — record_approval_decision is the core engine: applies the
    // 5M threshold branch, generates the PO the moment either branch
    // reaches Finance, closes the request at Finance sign-off, stops the
    // workflow on rejection, and notifies the requester + next approvers.
    //
    // NOTE: parameter keys must exactly match the SQL function's
    // p_-prefixed argument names -- PostgREST resolves RPC calls by
    // matching JSON keys to the function's declared parameter names.
    const { error } = await supabase.rpc("record_approval_decision", {
      p_request_id: pending.request.id,
      p_decision: pending.decision,
      p_comment: comment.trim() || null,
      p_acting_on_behalf_of: (pending.request.acting_on_behalf_of as any)?.id ?? null,
    });

    setActionSubmitting(false);

    if (error) {
      setActionError(error.message ?? "Could not record the decision. Try again.");
      return;
    }

    setPending(null);
    setQueue((prev) => prev.filter((r) => r.id !== pending.request.id));
  };

  // Cancel dialog handlers — separate flow from approve/reject above.
  const openCancelDialog = (request: QueuedRequest) => {
    setCancelTarget(request);
    setCancelReason("");
    setCancelError(null);
  };

  const closeCancelDialog = () => {
    if (cancelSubmitting) return;
    setCancelTarget(null);
  };

  const confirmCancel = async () => {
    if (!cancelTarget) return;
    if (cancelReason.trim().length === 0) {
      setCancelError("A reason is required to cancel a request.");
      return;
    }

    setCancelSubmitting(true);
    setCancelError(null);

    const { error } = await supabase.rpc("cancel_request", {
      p_request_id: cancelTarget.id,
      p_reason: cancelReason.trim(),
    });

    setCancelSubmitting(false);

    if (error) {
      setCancelError(error.message ?? "Could not cancel the request. Try again.");
      return;
    }

    setCancelTarget(null);
    setQueue((prev) => prev.filter((r) => r.id !== cancelTarget.id));
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
        Approval queue
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Requests waiting on your decision at their current stage. A rejection
        cancels the request — there's no bounce-back to a prior stage.
        Offer-entry and offer/PO approval have their own dedicated screens
        under Purchasing &amp; Logistics; this queue covers everything
        earlier in the chain.
      </Typography>

      {displayedQueue.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">
            Nothing waiting on you right now.
          </Typography>
          <Button component={RouterLink} to="/requests/new" variant="outlined" sx={{ mt: 2 }}>
            Submit a new request
          </Button>
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Item</TableCell>
                <TableCell>Requester</TableCell>
                <TableCell>Dept</TableCell>
                <TableCell>Cost center</TableCell>
                <TableCell>Stage</TableCell>
                <TableCell align="right">Qty</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {displayedQueue.map((r) => {
                const blockedAsSubmitter = isBlockedAsOfferSubmitter(r);
                const poExists = hasExistingPO(r);

                return (
                  <TableRow key={r.id} hover>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600}>
                        {r.item_description}
                      </Typography>
                      {r.acting_on_behalf_of && (
                        <Tooltip title={`Delegated from ${r.acting_on_behalf_of.name}`}>
                          <Chip
                            size="small"
                            label={`On behalf of ${r.acting_on_behalf_of.name}`}
                            sx={{ mt: 0.5 }}
                            variant="outlined"
                          />
                        </Tooltip>
                      )}
                    </TableCell>
                    <TableCell>{r.requester.name}</TableCell>
                    <TableCell sx={{ display: { xs: "none", sm: "table-cell" } }}>{r.department.name}</TableCell>
                    <TableCell sx={{ display: { xs: "none", md: "table-cell" } }}>{r.cost_center.project_code}</TableCell>
                    <TableCell>
                      <Stack direction="row" alignItems="center" spacing={0.5} flexWrap="wrap">
                        <Typography variant="body2">{r.current_stage.name}</Typography>
                        {blockedAsSubmitter && (
                          <Tooltip title="You submitted the vendor offer on this request, so a different reviewer needs to act on it here.">
                            <Chip size="small" color="default" variant="outlined" label="You submitted this offer" />
                          </Tooltip>
                        )}
                        {poExists && (
                          <Chip size="small" color="info" variant="outlined" label="PO exists" />
                        )}
                      </Stack>
                    </TableCell>
                    <TableCell align="right">{r.quantity}</TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end" flexWrap="wrap">
                        <Button
                          size="small"
                          color="warning"
                          variant="text"
                          onClick={() => openCancelDialog(r)}
                        >
                          Cancel request
                        </Button>
                        <Button
                          size="small"
                          color="error"
                          onClick={() => openDialog(r, "rejected")}
                          disabled={blockedAsSubmitter}
                        >
                          Reject
                        </Button>
                        <Button
                          size="small"
                          variant="contained"
                          onClick={() => openDialog(r, "approved")}
                          disabled={blockedAsSubmitter}
                        >
                          Approve
                        </Button>
                      </Stack>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {/* Approve / Reject dialog */}
      <Dialog open={!!pending} onClose={closeDialog} fullWidth maxWidth="sm">
        <DialogTitle>
          {pending?.decision === "approved" ? "Approve" : "Reject"} — {pending?.request.item_description}
        </DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            {pending?.decision === "approved"
              ? "This moves the request to its next configured stage."
              : "This cancels the request outright. The requester will need to submit a new one to try again."}
          </DialogContentText>
          <TextField
            autoFocus
            label={pending?.decision === "rejected" ? "Reason (required)" : "Comment (optional)"}
            multiline
            minRows={2}
            fullWidth
            value={comment}
            onChange={(e) => setComment(e.target.value)}
          />
          {actionError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {actionError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeDialog} disabled={actionSubmitting}>
            Back
          </Button>
          <Button
            onClick={confirmDecision}
            variant="contained"
            color={pending?.decision === "rejected" ? "error" : "primary"}
            disabled={actionSubmitting}
          >
            {actionSubmitting ? "Saving…" : "Confirm"}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Cancel request dialog */}
      <Dialog open={!!cancelTarget} onClose={closeCancelDialog} fullWidth maxWidth="sm">
        <DialogTitle>Cancel request — {cancelTarget?.item_description}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            This withdraws the request entirely — different from Reject, which is a workflow
            decision at your stage. The requester will be notified with your reason.
          </DialogContentText>
          <TextField
            autoFocus
            label="Reason (required)"
            multiline
            minRows={2}
            fullWidth
            value={cancelReason}
            onChange={(e) => setCancelReason(e.target.value)}
          />
          {cancelError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {cancelError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeCancelDialog} disabled={cancelSubmitting}>
            Back
          </Button>
          <Button onClick={confirmCancel} variant="contained" color="warning" disabled={cancelSubmitting}>
            {cancelSubmitting ? "Cancelling…" : "Confirm cancellation"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}