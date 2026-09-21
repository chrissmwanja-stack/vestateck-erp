import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog,
  DialogActions, DialogContent, DialogTitle, Snackbar, Table, TableBody,
  TableCell, TableHead, TableRow, TextField, Tooltip, Typography,
} from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Project {
  id: string;
  project_no: string;
  name: string;
  client_name: string | null;
  status: string;
  budget: number | null;
  currency: string;
  created_by: string | null;
  created_at: string;
  pmo_project_categories?: { name: string } | null;
}

type Decision = "approved" | "rejected";

// PMO admin/manager queue (route tier PMO_ADMIN_ROLES). Decisions go
// through decide_pmo_project -- every approval/rejection lands in
// pmo_project_decisions with actor + notes, the creator is notified, and
// self-approval is refused (20260921110000_pmo_project_approval_flow.sql).
export default function PMOApprovals() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [projects, setProjects] = useState<Project[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [snack, setSnack] = useState<string | null>(null);
  const [dialog, setDialog] = useState<{ project: Project; decision: Decision } | null>(null);
  const [notes, setNotes] = useState("");
  const [noteError, setNoteError] = useState<string | null>(null);
  const [deciding, setDeciding] = useState(false);

  const fetchProjects = async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase
      .from("pmo_projects")
      .select("*, pmo_project_categories(name)")
      .eq("status", "pending_approval")
      .order("created_at", { ascending: true });
    if (error) setError(error.message);
    if (data) {
      setProjects((data as any[]).map((p) => ({
        ...p,
        pmo_project_categories: Array.isArray(p.pmo_project_categories) ? p.pmo_project_categories[0] ?? null : p.pmo_project_categories ?? null,
      })) as Project[]);
    }
    setLoading(false);
  };

  useEffect(() => { fetchProjects(); }, []);

  const openDialog = (project: Project, decision: Decision) => {
    setDialog({ project, decision });
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
    const { error } = await supabase.rpc("decide_pmo_project", {
      p_project_id: dialog.project.id,
      p_decision: dialog.decision,
      p_notes: trimmed || null,
    });
    setDeciding(false);
    if (error) {
      setError(`${dialog.project.project_no}: ${error.message}`);
      return;
    }
    setSnack(
      dialog.decision === "approved"
        ? `${dialog.project.project_no} approved and set in progress`
        : `${dialog.project.project_no} rejected`,
    );
    setDialog(null);
    setProjects((prev) => prev.filter((p) => p.id !== dialog.project.id));
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const myId = session?.user?.id;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Project Approvals</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Projects submitted for approval. Approving sets the project in progress; decisions are recorded with
        your name and notes, and a project's creator can never approve their own submission.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>{error}</Alert>}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Project No</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Budget</TableCell>
                <TableCell>Submitted</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {projects.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}>
                    <Typography color="text.secondary">
                      Nothing waiting on you. Projects appear here once submitted from the project detail page.
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : projects.map((p) => {
                const isMine = !!myId && p.created_by === myId;
                return (
                  <TableRow key={p.id} hover>
                    <TableCell><Typography fontFamily="monospace" fontWeight={600}>{p.project_no}</Typography></TableCell>
                    <TableCell><Typography fontWeight={600} variant="body2">{p.name}</Typography></TableCell>
                    <TableCell>{p.client_name || "-"}</TableCell>
                    <TableCell><Chip label={p.pmo_project_categories?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell>{p.budget != null ? `${p.currency} ${Number(p.budget).toLocaleString()}` : "-"}</TableCell>
                    <TableCell>{new Date(p.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      <Tooltip title={isMine ? "You created this project — another approver must decide" : "Open project"}>
                        <span>
                          <Button size="small" sx={{ mr: 1 }} onClick={() => navigate(`/pmo/projects/${p.id}`)}>View</Button>
                        </span>
                      </Tooltip>
                      <Tooltip title={isMine ? "You created this project — another approver must decide" : ""}>
                        <span>
                          <Button size="small" variant="contained" color="success" sx={{ mr: 1 }} disabled={isMine} onClick={() => openDialog(p, "approved")}>
                            Approve
                          </Button>
                          <Button size="small" variant="outlined" color="error" disabled={isMine} onClick={() => openDialog(p, "rejected")}>
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
        <DialogTitle>{dialog?.decision === "approved" ? "Approve" : "Reject"} project {dialog?.project.project_no}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <Box sx={{ p: 2, bgcolor: "action.hover", borderRadius: 1 }}>
            <Typography fontWeight={600}>{dialog?.project.name}</Typography>
            <Typography variant="body2" color="text.secondary">
              {dialog?.project.client_name || "No client"}
              {dialog?.project.budget != null ? ` • ${dialog.project.currency} ${Number(dialog.project.budget).toLocaleString()}` : ""}
            </Typography>
          </Box>
          {dialog?.decision === "approved" && (
            <Alert severity="info" sx={{ mt: 1 }}>
              Approving sets the project in progress. The decision and your name are recorded permanently.
            </Alert>
          )}
          <TextField
            label={dialog?.decision === "rejected" ? "Rejection reason *" : "Notes (optional)"}
            value={notes}
            onChange={(e) => { setNotes(e.target.value); setNoteError(null); }}
            fullWidth multiline minRows={2} autoFocus
            error={!!noteError} helperText={noteError ?? (dialog?.decision === "rejected" ? "Sent to the project's creator." : undefined)}
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
            {deciding ? "Saving…" : dialog?.decision === "approved" ? "Approve & start" : "Reject"}
          </Button>
        </DialogActions>
      </Dialog>

      <Snackbar open={!!snack} autoHideDuration={4000} onClose={() => setSnack(null)} message={snack ?? ""} />
    </Box>
  );
}
