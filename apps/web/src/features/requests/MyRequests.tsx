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

type RequestStatus = "open" | "rejected" | "closed" | "cancelled";

interface MyRequestRow {
  id: string;
  item_description: string;
  quantity: number;
  status: RequestStatus;
  delivery_date: string | null;
  subcontractor: string | null;
  created_at: string;
  cost_center: { name: string; project_code: string } | { name: string; project_code: string }[] | null;
  current_stage: { name: string } | { name: string }[] | null;
}

const statusColor: Record<RequestStatus, "default" | "success" | "error" | "warning"> = {
  open: "warning",
  closed: "success",
  rejected: "error",
  cancelled: "default",
};

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export default function MyRequests() {
  const [rows, setRows] = useState<MyRequestRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);

  const [cancelTarget, setCancelTarget] = useState<MyRequestRow | null>(null);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelError, setCancelError] = useState<string | null>(null);
  const [cancelSubmitting, setCancelSubmitting] = useState(false);

  const loadRequests = useCallback(async (userId: string) => {
    setLoading(true);
    setLoadError(null);
    // requests_select_own_or_actionable RLS also allows rows the caller can
    // act on as an approver -- explicit requester_id filter here keeps this
    // screen scoped to only what this user submitted themselves.
    const { data, error } = await supabase
      .from("requests")
      .select(
        "id, item_description, quantity, status, delivery_date, subcontractor, created_at, " +
          "cost_center:cost_centers!requests_cost_center_id_fkey(name, project_code), " +
          "current_stage:workflow_stages!requests_current_stage_id_fkey(name)"
      )
      .eq("requester_id", userId)
      .order("created_at", { ascending: false });

    if (error) setLoadError(error.message);
    else setRows((data ?? []) as unknown as MyRequestRow[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      const userId = data.user?.id ?? null;
      setCurrentUserId(userId);
      if (userId) loadRequests(userId);
      else setLoading(false);
    });
  }, [loadRequests]);

  const openCancelDialog = (row: MyRequestRow) => {
    setCancelTarget(row);
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
    if (currentUserId) loadRequests(currentUserId);
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
        My requests
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Everything you've submitted. Open requests can be withdrawn if you no longer need them —
        once a request is closed a purchase order has already been generated, so cancellation is no
        longer available at that point.
      </Typography>

      {rows.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">You haven't submitted any requests yet.</Typography>
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
                <TableCell>Cost center</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Stage</TableCell>
                <TableCell align="right">Qty</TableCell>
                <TableCell>Submitted</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((row) => {
                const costCenter = embedOne(row.cost_center);
                const stage = embedOne(row.current_stage);
                return (
                  <TableRow key={row.id} hover>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600}>
                        {row.item_description}
                      </Typography>
                      {row.subcontractor && (
                        <Typography variant="caption" color="text.secondary">
                          {row.subcontractor}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell>{costCenter ? costCenter.project_code : "—"}</TableCell>
                    <TableCell>
                      <Chip size="small" label={row.status} color={statusColor[row.status]} />
                    </TableCell>
                    <TableCell>{row.status === "open" ? stage?.name ?? "—" : "—"}</TableCell>
                    <TableCell align="right">{row.quantity}</TableCell>
                    <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      {row.status === "open" ? (
                        <Button size="small" color="warning" onClick={() => openCancelDialog(row)}>
                          Cancel
                        </Button>
                      ) : (
                        <Typography variant="body2" color="text.secondary">
                          —
                        </Typography>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Dialog open={!!cancelTarget} onClose={closeCancelDialog} fullWidth maxWidth="sm">
        <DialogTitle>Withdraw request — {cancelTarget?.item_description}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            This withdraws your request entirely. Whoever currently holds it for approval will be
            notified with your reason.
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
            {cancelSubmitting ? "Withdrawing…" : "Confirm withdrawal"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}