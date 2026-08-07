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
  FormControlLabel,
  Paper,
  Radio,
  RadioGroup,
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

// Offer Approval PO — Budget Controller's worklist, and (once branched
// past it) Finance / Project Manager / General Manager's.
//
// Multi-offer model: at the Budget Controller stage
// (current_stage.requires_offer_selection = true), several competing
// offers are on file and nobody has picked a winner yet -- this screen
// is where that decision happens, bundled into the same Approve action
// (record_approval_decision takes p_selected_offer_id). Rejecting
// doesn't require picking a winner. Every stage after Budget Controller
// has already had a winner selected, so those just show the one
// selected offer read-only alongside plain Approve/Reject.

interface PendingDecision {
  request: QueuedRequest;
  decision: ApprovalDecision;
  selectedOfferId: string | null;
}

function BranchIndicator({ amount, threshold }: { amount?: number; threshold?: number | null }) {
  if (amount === undefined || amount === null || threshold === null || threshold === undefined) {
    return null;
  }
  const isLow = amount <= threshold;
  return (
    <Chip
      size="small"
      label={isLow ? "≤5M path" : ">5M path"}
      color={isLow ? "success" : "warning"}
      variant="outlined"
      sx={{ ml: 1 }}
      title={`Quoted ${amount.toLocaleString()} vs threshold ${threshold.toLocaleString()}`}
    />
  );
}

export default function OfferApprovalPO() {
  const [queue, setQueue] = useState<QueuedRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);

  const [pending, setPending] = useState<PendingDecision | null>(null);
  const [comment, setComment] = useState("");
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionSubmitting, setActionSubmitting] = useState(false);

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

  // Everything past the offer-entry stage -- Budget Controller (where a
  // winner still needs picking) plus Finance / PM / GM (where one's
  // already been chosen).
  const offerStageQueue = useMemo(
    () => queue.filter((r) => !r.current_stage.requires_offer_entry && (r.offers?.length ?? 0) > 0),
    [queue]
  );

  const isBlockedAsOfferSubmitter = (r: QueuedRequest) =>
    r.current_stage.blocks_offer_submitter_approval &&
    (r.offers ?? []).some((o) => o.submitted_by === currentUserId);

  const hasExistingPO = (r: QueuedRequest) => !!(r as any).purchase_order;

  const openDialog = (request: QueuedRequest, decision: ApprovalDecision) => {
    const defaultSelection =
      decision === "approved" && request.current_stage.requires_offer_selection
        ? null
        : request.selected_offer?.id ?? null;
    setPending({ request, decision, selectedOfferId: defaultSelection });
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
    if (
      pending.decision === "approved" &&
      pending.request.current_stage.requires_offer_selection &&
      !pending.selectedOfferId
    ) {
      setActionError("Pick a winning offer before approving.");
      return;
    }

    setActionSubmitting(true);
    setActionError(null);

    // Same core engine as before: applies the 5M threshold branch,
    // generates the PO the moment either branch reaches Finance, closes
    // the request at Finance sign-off. p_selected_offer_id only matters
    // (and is only required) at the requires_offer_selection stage --
    // record_approval_decision ignores it otherwise and reads whichever
    // offer is already marked selected.
    const { error } = await supabase.rpc("record_approval_decision", {
      p_request_id: pending.request.id,
      p_decision: pending.decision,
      p_comment: comment.trim() || null,
      p_acting_on_behalf_of: (pending.request.acting_on_behalf_of as any)?.id ?? null,
      p_selected_offer_id: pending.selectedOfferId,
    });

    setActionSubmitting(false);

    if (error) {
      setActionError(error.message ?? "Could not record the decision. Try again.");
      return;
    }

    setPending(null);
    setQueue((prev) => prev.filter((r) => r.id !== pending.request.id));
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
        Offer approval (PO)
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Requests with competing vendor offers on file, waiting on your decision. At Budget
        Controller you'll pick the winning offer as part of approving -- everything downstream just
        carries that choice forward. A rejection cancels the request outright.
      </Typography>

      {offerStageQueue.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">Nothing waiting on you right now.</Typography>
          <Button component={RouterLink} to="/approvals" variant="outlined" sx={{ mt: 2 }}>
            View full approval queue
          </Button>
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Item</TableCell>
                <TableCell>Requester</TableCell>
                <TableCell>Stage</TableCell>
                <TableCell align="right">Offers</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {offerStageQueue.map((r) => {
                const blockedAsSubmitter = isBlockedAsOfferSubmitter(r);
                const threshold = r.current_stage.threshold_amount ?? null;
                const needsSelection = r.current_stage.requires_offer_selection;
                const referenceAmount = needsSelection
                  ? undefined
                  : r.selected_offer?.quotation_amount;
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
                    <TableCell>
                      <Stack direction="row" alignItems="center" spacing={0.5} flexWrap="wrap">
                        <Typography variant="body2">{r.current_stage.name}</Typography>
                        {needsSelection && (
                          <Chip size="small" color="warning" variant="outlined" label="Pick a winner" />
                        )}
                        {blockedAsSubmitter && (
                          <Tooltip title="You submitted one of the offers on this request, so a different reviewer needs to act on it here.">
                            <Chip size="small" color="default" variant="outlined" label="You submitted an offer" />
                          </Tooltip>
                        )}
                        <BranchIndicator amount={referenceAmount} threshold={threshold} />
                        {poExists && <Chip size="small" color="info" variant="outlined" label="PO exists" />}
                      </Stack>
                    </TableCell>
                    <TableCell align="right">
                      {needsSelection
                        ? `${r.offers?.length ?? 0} competing`
                        : r.selected_offer
                        ? `${r.selected_offer.vendor_name} (${r.selected_offer.quotation_amount.toLocaleString()})`
                        : "—"}
                    </TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end" flexWrap="wrap">
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

      <Dialog open={!!pending} onClose={closeDialog} fullWidth maxWidth="sm">
        <DialogTitle>
          {pending?.decision === "approved" ? "Approve" : "Reject"} — {pending?.request.item_description}
        </DialogTitle>
        <DialogContent>
          {pending?.decision === "approved" && pending.request.current_stage.requires_offer_selection ? (
            <>
              <DialogContentText sx={{ mb: 2 }}>
                Pick the winning offer. This moves the request forward on the branch matching that
                offer's amount against the {pending.request.current_stage.threshold_amount?.toLocaleString()}{" "}
                threshold.
              </DialogContentText>
              <RadioGroup
                value={pending.selectedOfferId ?? ""}
                onChange={(e) => setPending((p) => (p ? { ...p, selectedOfferId: e.target.value } : p))}
              >
                {(pending.request.offers ?? []).map((o) => (
                  <FormControlLabel
                    key={o.id}
                    value={o.id}
                    control={<Radio />}
                    label={`${o.vendor_name} — ${o.quotation_amount.toLocaleString()} (qty ${o.quantity})`}
                  />
                ))}
              </RadioGroup>
            </>
          ) : (
            <DialogContentText sx={{ mb: 2 }}>
              {pending?.decision === "approved"
                ? "This moves the request to its next configured stage. If a PO already exists (Finance sign-off), no new PO will be created."
                : "This cancels the request outright. The requester will need to submit a new one to try again."}
            </DialogContentText>
          )}
          <TextField
            label={pending?.decision === "rejected" ? "Reason (required)" : "Comment (optional)"}
            multiline
            minRows={2}
            fullWidth
            sx={{ mt: 2 }}
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
    </Box>
  );
}