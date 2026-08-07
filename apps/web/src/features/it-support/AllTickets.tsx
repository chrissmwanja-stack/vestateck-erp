import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  MenuItem,
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

// All Tickets -- IT Support's working queue. Gated on is_it_support():
// get_all_tickets() silently returns nothing for non-IT-Support users
// (it's a plain filter, not an error), so this screen checks access
// itself first and shows a clear message rather than an empty table that
// could be misread as "no tickets exist".

interface Ticket {
  id: string;
  ticket_number: string;
  subject: string;
  description: string;
  category: string;
  priority: string;
  status: string;
  assignee_id: string | null;
  requester_id: string;
  resolution_notes: string | null;
  created_at: string;
}

interface ItSupportUser {
  id: string;
  name: string;
}

const STATUS_COLOR: Record<string, "default" | "warning" | "info" | "success"> = {
  open: "warning",
  in_progress: "info",
  resolved: "success",
  closed: "default",
};

const PRIORITY_COLOR: Record<string, "default" | "warning" | "error"> = {
  low: "default",
  medium: "default",
  high: "warning",
  urgent: "error",
};

const NEXT_STATUSES: Record<string, string[]> = {
  open: ["in_progress", "resolved", "closed"],
  in_progress: ["resolved", "closed", "open"],
  resolved: ["closed", "in_progress"],
  closed: ["open"],
};

export default function AllTickets() {
  const [access, setAccess] = useState<boolean | null>(null);
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [itStaff, setItStaff] = useState<ItSupportUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [statusTarget, setStatusTarget] = useState<Ticket | null>(null);
  const [statusValue, setStatusValue] = useState("");
  const [resolutionNotes, setResolutionNotes] = useState("");
  const [statusSubmitting, setStatusSubmitting] = useState(false);
  const [statusError, setStatusError] = useState<string | null>(null);

  const [assignTarget, setAssignTarget] = useState<Ticket | null>(null);
  const [assignValue, setAssignValue] = useState<ItSupportUser | null>(null);
  const [assignSubmitting, setAssignSubmitting] = useState(false);
  const [assignError, setAssignError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);

    const { data: canAccess, error: accessError } = await supabase.rpc("is_it_support");
    if (accessError) {
      setError(accessError.message);
      setLoading(false);
      return;
    }
    setAccess(Boolean(canAccess));
    if (!canAccess) {
      setLoading(false);
      return;
    }

    const [{ data: ticketData, error: ticketError }, { data: staffData, error: staffError }] =
      await Promise.all([
        supabase.rpc("get_all_tickets"),
        supabase
          .from("app_users")
          .select("id, name, departments!inner(name)")
          .eq("departments.name", "IT Support"),
      ]);

    if (ticketError) setError(ticketError.message);
    else setTickets((ticketData ?? []) as Ticket[]);

    if (!staffError && staffData) {
      setItStaff(staffData.map((u: any) => ({ id: u.id, name: u.name })));
    }

    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openStatusDialog = (t: Ticket) => {
    setStatusTarget(t);
    setStatusValue("");
    setResolutionNotes(t.resolution_notes ?? "");
    setStatusError(null);
  };

  const confirmStatus = async () => {
    if (!statusTarget || !statusValue) return;
    setStatusSubmitting(true);
    setStatusError(null);

    const { error: rpcError } = await supabase.rpc("update_ticket_status", {
      p_ticket_id: statusTarget.id,
      p_status: statusValue,
      p_resolution_notes: resolutionNotes.trim() || null,
    });

    setStatusSubmitting(false);
    if (rpcError) {
      setStatusError(rpcError.message ?? "Could not update the ticket. Try again.");
      return;
    }
    setStatusTarget(null);
    load();
  };

  const openAssignDialog = (t: Ticket) => {
    setAssignTarget(t);
    setAssignValue(itStaff.find((u) => u.id === t.assignee_id) ?? null);
    setAssignError(null);
  };

  const confirmAssign = async () => {
    if (!assignTarget) return;
    setAssignSubmitting(true);
    setAssignError(null);

    const { error: rpcError } = await supabase.rpc("assign_ticket", {
      p_ticket_id: assignTarget.id,
      p_assignee_id: assignValue?.id ?? null,
    });

    setAssignSubmitting(false);
    if (rpcError) {
      setAssignError(rpcError.message ?? "Could not assign the ticket. Try again.");
      return;
    }
    setAssignTarget(null);
    load();
  };

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (access === false) {
    return (
      <Alert severity="info" sx={{ maxWidth: 640, mx: "auto" }}>
        All Tickets is limited to IT Support staff. If you're expecting access, check with an admin
        that your account is assigned to the IT Support department.
      </Alert>
    );
  }

  if (error) {
    return (
      <Alert severity="error" sx={{ maxWidth: 640, mx: "auto" }}>
        {error}
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1200, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>
        All tickets
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Every ticket filed with IT Support, open ones first. Assign a ticket to move it to In
        Progress automatically, or update its status directly.
      </Typography>

      {tickets.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">No tickets on file yet.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Ticket</TableCell>
                <TableCell>Subject</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Priority</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Assignee</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {tickets.map((t) => {
                const assignee = itStaff.find((u) => u.id === t.assignee_id);
                return (
                  <TableRow key={t.id} hover>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600}>
                        {t.ticket_number}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">{t.subject}</Typography>
                    </TableCell>
                    <TableCell>{t.category}</TableCell>
                    <TableCell>
                      <Chip size="small" label={t.priority} color={PRIORITY_COLOR[t.priority]} variant="outlined" />
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={t.status.replace("_", " ")} color={STATUS_COLOR[t.status]} />
                    </TableCell>
                    <TableCell>{assignee?.name ?? "Unassigned"}</TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end">
                        <Button size="small" onClick={() => openAssignDialog(t)}>
                          Assign
                        </Button>
                        <Button size="small" variant="outlined" onClick={() => openStatusDialog(t)}>
                          Update status
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

      {/* Update status dialog */}
      <Dialog open={!!statusTarget} onClose={() => !statusSubmitting && setStatusTarget(null)} fullWidth maxWidth="sm">
        <DialogTitle>Update status — {statusTarget?.ticket_number}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>{statusTarget?.subject}</DialogContentText>
          <Stack spacing={2}>
            <TextField
              select
              label="New status"
              value={statusValue}
              onChange={(e) => setStatusValue(e.target.value)}
              fullWidth
            >
              {(statusTarget ? NEXT_STATUSES[statusTarget.status] ?? [] : []).map((s) => (
                <MenuItem key={s} value={s}>
                  {s.replace("_", " ")}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              label="Resolution notes"
              multiline
              minRows={3}
              fullWidth
              value={resolutionNotes}
              onChange={(e) => setResolutionNotes(e.target.value)}
              helperText="Visible to the requester once the ticket is resolved or closed."
            />
          </Stack>
          {statusError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {statusError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatusTarget(null)} disabled={statusSubmitting}>
            Cancel
          </Button>
          <Button onClick={confirmStatus} variant="contained" disabled={statusSubmitting || !statusValue}>
            {statusSubmitting ? "Saving…" : "Save"}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Assign dialog */}
      <Dialog open={!!assignTarget} onClose={() => !assignSubmitting && setAssignTarget(null)} fullWidth maxWidth="sm">
        <DialogTitle>Assign ticket — {assignTarget?.ticket_number}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            Assigning moves an Open ticket to In Progress automatically.
          </DialogContentText>
          <Autocomplete
            options={itStaff}
            getOptionLabel={(u) => u.name}
            value={assignValue}
            onChange={(_, v) => setAssignValue(v)}
            isOptionEqualToValue={(a, b) => a.id === b.id}
            renderInput={(params) => <TextField {...params} label="Assignee" placeholder="Unassigned" />}
          />
          {assignError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {assignError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAssignTarget(null)} disabled={assignSubmitting}>
            Cancel
          </Button>
          <Button onClick={confirmAssign} variant="contained" disabled={assignSubmitting}>
            {assignSubmitting ? "Saving…" : "Save"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}