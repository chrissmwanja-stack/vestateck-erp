import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog,
  DialogActions, DialogContent, DialogTitle, Snackbar, Table, TableBody,
  TableCell, TableHead, TableRow, TextField, Tooltip, Typography,
} from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Contract {
  id: string;
  contract_no: string;
  title: string;
  party_name: string;
  status: string;
  value: number | null;
  currency: string;
  created_by: string | null;
  created_at: string;
  law_contract_types?: { name: string } | null;
}

type Decision = "approved" | "rejected";

// Legal admin/manager queue only (route tier LEGAL_APPROVER_ROLES in
// App.tsx). Decisions go through the decide_contract RPC -- never a direct
// table update -- so every approval/rejection lands in
// law_contract_decisions with actor + notes, and the creator can never
// self-approve (20260921100000_law_contract_approval_flow.sql).
export default function ContractApprovals() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [snack, setSnack] = useState<string | null>(null);

  const [dialog, setDialog] = useState<{ contract: Contract; decision: Decision } | null>(null);
  const [notes, setNotes] = useState("");
  const [noteError, setNoteError] = useState<string | null>(null);
  const [deciding, setDeciding] = useState(false);

  const fetchContracts = async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase
      .from("law_contracts")
      .select("*, law_contract_types(name)")
      .eq("status", "pending_approval")
      .order("created_at", { ascending: true });
    if (error) setError(error.message);
    if (data) setContracts(data as Contract[]);
    setLoading(false);
  };

  useEffect(() => { fetchContracts(); }, []);

  const openDialog = (contract: Contract, decision: Decision) => {
    setDialog({ contract, decision });
    setNotes("");
    setNoteError(null);
  };

  const handleConfirm = async () => {
    if (!dialog) return;
    const trimmed = notes.trim();
    if (dialog.decision === "rejected" && !trimmed) {
      setNoteError("A rejection reason is required.");
      return;
    }
    setDeciding(true);
    const { error } = await supabase.rpc("decide_contract", {
      p_contract_id: dialog.contract.id,
      p_decision: dialog.decision,
      p_notes: trimmed || undefined,
    });
    setDeciding(false);
    if (error) {
      setError(`${dialog.contract.contract_no}: ${error.message}`);
      return;
    }
    setSnack(
      dialog.decision === "approved"
        ? `${dialog.contract.contract_no} approved and activated`
        : `${dialog.contract.contract_no} rejected`,
    );
    setDialog(null);
    setContracts((prev) => prev.filter((c) => c.id !== dialog.contract.id));
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const myId = session?.user?.id;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Contract Approvals</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Contracts submitted for approval. Decisions are recorded with your name and notes, and a contract's
        creator can never approve their own submission.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>{error}</Alert>}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Contract No</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Party</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Value</TableCell>
                <TableCell>Submitted</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {contracts.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}>
                    <Typography color="text.secondary">
                      Nothing waiting on you. Drafts appear here once a legal user submits them from the
                      contract detail page.
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : contracts.map((c) => {
                const isMine = !!myId && c.created_by === myId;
                return (
                  <TableRow key={c.id} hover>
                    <TableCell><Typography fontFamily="monospace" fontWeight={600}>{c.contract_no}</Typography></TableCell>
                    <TableCell>
                      <Typography fontWeight={600} variant="body2">{c.title}</Typography>
                    </TableCell>
                    <TableCell>{c.party_name}</TableCell>
                    <TableCell><Chip label={c.law_contract_types?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell>{c.value != null ? `${c.currency} ${Number(c.value).toLocaleString()}` : "-"}</TableCell>
                    <TableCell>{new Date(c.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      <Tooltip title={isMine ? "You created this contract — another approver must decide" : "Open full contract"}>
                        <span>
                          <Button size="small" sx={{ mr: 1 }} onClick={() => navigate(`/law-compliance/contracts/${c.id}`)}>View</Button>
                        </span>
                      </Tooltip>
                      <Tooltip title={isMine ? "You created this contract — another approver must decide" : ""}>
                        <span>
                          <Button size="small" variant="contained" color="success" sx={{ mr: 1 }} disabled={isMine} onClick={() => openDialog(c, "approved")}>
                            Approve
                          </Button>
                          <Button size="small" variant="outlined" color="error" disabled={isMine} onClick={() => openDialog(c, "rejected")}>
                            Reject
                          </Button>
                        </span>
                      </Tooltip>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={!!dialog} onClose={() => !deciding && setDialog(null)} maxWidth="sm" fullWidth>
        <DialogTitle>{dialog?.decision === "approved" ? "Approve" : "Reject"} contract {dialog?.contract.contract_no}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <Box sx={{ p: 2, bgcolor: "action.hover", borderRadius: 1 }}>
            <Typography fontWeight={600}>{dialog?.contract.title}</Typography>
            <Typography variant="body2" color="text.secondary">
              {dialog?.contract.party_name}
              {dialog?.contract.value != null ? ` • ${dialog.contract.currency} ${Number(dialog.contract.value).toLocaleString()}` : ""}
            </Typography>
          </Box>
          {dialog?.decision === "approved" && (
            <Alert severity="info" sx={{ mt: 1 }}>
              Approving activates the contract. The decision and your name are recorded permanently.
            </Alert>
          )}
          <TextField
            label={dialog?.decision === "rejected" ? "Rejection reason *" : "Notes (optional)"}
            value={notes}
            onChange={(e) => { setNotes(e.target.value); setNoteError(null); }}
            fullWidth multiline minRows={2} autoFocus
            error={!!noteError} helperText={noteError ?? (dialog?.decision === "rejected" ? "Sent to the contract's creator." : undefined)}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDialog(null)} disabled={deciding}>Cancel</Button>
          <Button
            variant="contained"
            color={dialog?.decision === "approved" ? "success" : "error"}
            onClick={handleConfirm}
            disabled={deciding}
          >
            {deciding ? "Saving…" : dialog?.decision === "approved" ? "Approve & activate" : "Reject"}
          </Button>
        </DialogActions>
      </Dialog>

      <Snackbar open={!!snack} autoHideDuration={4000} onClose={() => setSnack(null)} message={snack ?? ""} />
    </Box>
  );
}
