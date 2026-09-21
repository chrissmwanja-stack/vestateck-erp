import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import {
  Alert, Box, Breadcrumbs, Button, Card, CardContent, Chip, CircularProgress,
  Dialog, DialogActions, DialogContent, DialogTitle, Divider, Grid, Link,
  Snackbar, TextField, Tooltip, Typography,
} from "@mui/material";
import { ArrowBack } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface ContractRecord {
  id: string;
  contract_no: string;
  title: string;
  party_name: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
  value: number | null;
  currency: string;
  created_by: string | null;
  created_at: string;
  updated_at: string;
  law_contract_types?: { name: string } | null;
}

interface DecisionRow {
  id: string;
  decision: "submitted" | "approved" | "rejected";
  notes: string | null;
  created_at: string;
  app_users?: { name: string } | null;
}

export default function ContractDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { session } = useAuth();
  const [record, setRecord] = useState<ContractRecord | null>(null);
  const [decisions, setDecisions] = useState<DecisionRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [canApprove, setCanApprove] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [snack, setSnack] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [dialog, setDialog] = useState<{ decision: "approved" | "rejected" } | null>(null);
  const [notes, setNotes] = useState("");
  const [noteError, setNoteError] = useState<string | null>(null);

  const fetchAll = async () => {
    if (!id) return;
    setLoading(true);
    const { data, error } = await supabase.from("law_contracts").select("*, law_contract_types(name)").eq("id", id).single();
    if (error || !data) {
      setNotFound(true);
    } else {
      const normalized = {
        ...data,
        law_contract_types: Array.isArray(data.law_contract_types) ? data.law_contract_types[0] ?? null : data.law_contract_types ?? null,
      };
      setRecord(normalized as ContractRecord);
      const { data: history } = await supabase
        .from("law_contract_decisions")
        .select("id, decision, notes, created_at, app_users(name)")
        .eq("contract_id", id)
        .order("created_at", { ascending: false });
      if (history) {
        setDecisions(history.map((h: any) => ({
          ...h,
          app_users: Array.isArray(h.app_users) ? h.app_users[0] ?? null : h.app_users ?? null,
        })) as DecisionRow[]);
      }
    }
    setLoading(false);
  };

  useEffect(() => { fetchAll(); }, [id]);

  // Approver-tier check via the same helper RLS/RPCs use; if it errors or
  // returns false the Approve/Reject buttons stay hidden (the RPC would
  // refuse them anyway, but hidden is better UX than erroring).
  useEffect(() => {
    const check = async () => {
      const { data } = await supabase.rpc("has_module_role", { p_module: "legal", p_roles: ["admin", "manager"] });
      setCanApprove(data === true);
    };
    check();
  }, []);

  const submitForApproval = async () => {
    if (!record) return;
    setBusy(true);
    setActionError(null);
    const { error } = await supabase.rpc("submit_contract_for_approval", { p_contract_id: record.id });
    setBusy(false);
    if (error) setActionError(error.message);
    else { setSnack(`${record.contract_no} submitted for approval`); fetchAll(); }
  };

  const confirmDecision = async () => {
    if (!record || !dialog) return;
    const trimmed = notes.trim();
    if (dialog.decision === "rejected" && !trimmed) {
      setNoteError("A rejection reason is required.");
      return;
    }
    setBusy(true);
    const { error } = await supabase.rpc("decide_contract", {
      p_contract_id: record.id,
      p_decision: dialog.decision,
      p_notes: trimmed || null,
    });
    setBusy(false);
    if (error) { setActionError(error.message); return; }
    setSnack(dialog.decision === "approved" ? "Contract approved and activated" : "Contract rejected");
    setDialog(null);
    fetchAll();
  };

  const getStatusColor = (s: string) => {
    if (s === 'active') return 'success';
    if (s === 'expired' || s === 'terminated' || s === 'rejected') return 'error';
    if (s === 'pending_approval') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (notFound || !record) {
    return (
      <Box sx={{ p: 3, maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>Contract not found.</Alert>
        <Button startIcon={<ArrowBack />} onClick={() => navigate("/law-compliance/contracts")}>Back to Contracts</Button>
      </Box>
    );
  }

  const msToEnd = record.end_date ? new Date(record.end_date).getTime() - Date.now() : null;
  const daysToEnd = msToEnd != null ? Math.ceil(msToEnd / (24 * 60 * 60 * 1000)) : null;
  const isExpiringSoon = daysToEnd != null && daysToEnd > 0 && daysToEnd <= 30; // matches ContractsList + ExpiryReport window
  const isPastEnd = daysToEnd != null && daysToEnd <= 0;
  const isMine = !!session?.user?.id && record.created_by === session.user.id;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/law-compliance/contracts" underline="hover" color="inherit">Contracts</Link>
        <Typography color="text.primary">{record.contract_no}</Typography>
      </Breadcrumbs>

      {actionError && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setActionError(null)}>{actionError}</Alert>}

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3, flexWrap: "wrap", gap: 1 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{record.title}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{record.contract_no}</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1, alignItems: "center" }}>
          {isExpiringSoon && <Chip label="Expiring soon" color="warning" />}
          {isPastEnd && record.status !== "terminated" && <Chip label="Past end date" color="error" variant="outlined" />}
          <Chip label={record.status} color={getStatusColor(record.status) as any} sx={{ textTransform: "capitalize" }} />
        </Box>
      </Box>

      {/* Workflow actions: submit drafts; decide pendings (approver tier,
          never the creator -- decide_contract enforces both again). */}
      {(record.status === "draft" || (record.status === "pending_approval" && canApprove)) && (
        <Box sx={{ display: "flex", gap: 1, mb: 3, flexWrap: "wrap" }}>
          {record.status === "draft" && (
            <Button variant="contained" onClick={submitForApproval} disabled={busy}>
              {busy ? "Working…" : "Submit for approval"}
            </Button>
          )}
          {record.status === "pending_approval" && canApprove && (
            <Tooltip title={isMine ? "You created this contract — another approver must decide" : ""}>
              <span>
                <Button variant="contained" color="success" sx={{ mr: 1 }} disabled={busy || isMine} onClick={() => { setDialog({ decision: "approved" }); setNotes(""); setNoteError(null); }}>
                  Approve
                </Button>
                <Button variant="outlined" color="error" disabled={busy || isMine} onClick={() => { setDialog({ decision: "rejected" }); setNotes(""); setNoteError(null); }}>
                  Reject
                </Button>
              </span>
            </Tooltip>
          )}
        </Box>
      )}

      <Grid container spacing={2}>
        <Grid item xs={12} md={7}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Contract Info</Typography>
            <Grid container spacing={2}>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Party</Typography><Typography>{record.party_name}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Type</Typography><Typography>{record.law_contract_types?.name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Start Date</Typography><Typography>{record.start_date ? new Date(record.start_date).toLocaleDateString() : "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">End Date</Typography><Typography>{record.end_date ? new Date(record.end_date).toLocaleDateString() : "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Created</Typography><Typography>{new Date(record.created_at).toLocaleDateString()}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Last Updated</Typography><Typography>{new Date(record.updated_at).toLocaleDateString()}</Typography></Grid>
            </Grid>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={5}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Contract Value</Typography>
            <Typography variant="h5" fontWeight={700}>{record.value ? `${record.currency} ${Number(record.value).toLocaleString()}` : "-"}</Typography>
            {daysToEnd != null && (
              <Typography variant="body2" color={isPastEnd ? "error.main" : isExpiringSoon ? "warning.main" : "text.secondary"} sx={{ mt: 2 }}>
                {isPastEnd ? `Ended ${Math.abs(daysToEnd)} day${Math.abs(daysToEnd) === 1 ? "" : "s"} ago` : `${daysToEnd} day${daysToEnd === 1 ? "" : "s"} remaining`}
              </Typography>
            )}
          </CardContent></Card>
        </Grid>

        <Grid item xs={12}>
          <Card><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Approval history</Typography>
            {decisions.length === 0 ? (
              <Typography variant="body2" color="text.secondary">
                No decisions yet. Submit the contract for approval to start the audit trail.
              </Typography>
            ) : decisions.map((d, i) => (
              <Box key={d.id}>
                {i > 0 && <Divider sx={{ my: 1.5 }} />}
                <Box sx={{ display: "flex", alignItems: "center", gap: 1, flexWrap: "wrap" }}>
                  <Chip
                    label={d.decision}
                    size="small"
                    color={d.decision === "approved" ? "success" : d.decision === "rejected" ? "error" : "info"}
                    sx={{ textTransform: "capitalize", minWidth: 88 }}
                  />
                  <Typography variant="body2" fontWeight={600}>{d.app_users?.name ?? "Unknown user"}</Typography>
                  <Typography variant="body2" color="text.secondary">
                    {new Date(d.created_at).toLocaleString()}
                  </Typography>
                </Box>
                {d.notes && <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5, ml: 1 }}>{d.notes}</Typography>}
              </Box>
            ))}
          </CardContent></Card>
        </Grid>
      </Grid>

      <Dialog open={!!dialog} onClose={() => !busy && setDialog(null)} maxWidth="sm" fullWidth>
        <DialogTitle>{dialog?.decision === "approved" ? "Approve" : "Reject"} {record.contract_no}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField
            label={dialog?.decision === "rejected" ? "Rejection reason *" : "Notes (optional)"}
            value={notes}
            onChange={(e) => { setNotes(e.target.value); setNoteError(null); }}
            fullWidth multiline minRows={2} autoFocus
            error={!!noteError} helperText={noteError ?? (dialog?.decision === "rejected" ? "Sent to the contract's creator." : undefined)}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDialog(null)} disabled={busy}>Cancel</Button>
          <Button
            variant="contained"
            color={dialog?.decision === "approved" ? "success" : "error"}
            onClick={confirmDecision}
            disabled={busy}
          >
            {busy ? "Saving…" : dialog?.decision === "approved" ? "Approve & activate" : "Reject"}
          </Button>
        </DialogActions>
      </Dialog>

      <Snackbar open={!!snack} autoHideDuration={4000} onClose={() => setSnack(null)} message={snack ?? ""} />
    </Box>
  );
}
