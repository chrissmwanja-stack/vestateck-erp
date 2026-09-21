import { useEffect, useState } from "react";
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog,
  DialogActions, DialogContent, DialogTitle, Divider, Grid, IconButton, ListItemText,
  Menu, MenuItem, Snackbar, Table, TableBody, TableCell, TableHead, TableRow,
  TextField, Tooltip, Typography,
} from "@mui/material";
import { Add, History, MoreVert } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Filing {
  id: string;
  title: string;
  filing_type: string | null;
  status: "pending" | "filed" | "approved" | "rejected";
  filing_date: string | null;
  due_date: string | null;
  reference_no: string | null;
  created_at: string;
}

interface FilingEvent {
  id: string;
  status: string;
  note: string | null;
  created_at: string;
  app_users?: { name: string } | null;
}

// Valid state machine, enforced server-side by transition_filing()
// (20260921103000_law_filing_transitions.sql); kept here to grey out what
// the RPC would refuse anyway.
const NEXT_STATES: Record<Filing["status"], { to: Filing["status"]; label: string }[]> = {
  pending: [
    { to: "filed", label: "Mark filed" },
    { to: "rejected", label: "Reject" },
  ],
  filed: [
    { to: "approved", label: "Approve" },
    { to: "rejected", label: "Reject" },
  ],
  rejected: [{ to: "pending", label: "Re-open as pending" }],
  approved: [],
};

export default function FilingsList() {
  const { session } = useAuth();
  const [filings, setFilings] = useState<Filing[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [snack, setSnack] = useState<string | null>(null);
  const [form, setForm] = useState({ title: "", filing_type: "", filing_date: "", reference_no: "", due_date: "" });

  // transition menu + note dialog state
  const [menuFor, setMenuFor] = useState<{ anchor: HTMLElement; filing: Filing } | null>(null);
  const [transition, setTransition] = useState<{ filing: Filing; to: Filing["status"]; label: string } | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  // history dialog state
  const [historyFor, setHistoryFor] = useState<Filing | null>(null);
  const [events, setEvents] = useState<FilingEvent[]>([]);
  const [eventsLoading, setEventsLoading] = useState(false);

  const fetchData = async () => {
    setLoading(true);
    const { data, error } = await supabase.from("law_regulatory_filings").select("*").order("filing_date", { ascending: false }).limit(100);
    if (data) setFilings(data as Filing[]);
    else if (error) setError(error.message);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.title.trim()) return;
    // Status is deliberately NOT user-selectable: filings are born
    // 'pending' and move via transition_filing() so every step is audited.
    const payload: any = {
      title: form.title.trim(),
      filing_type: form.filing_type.trim() || null,
      status: "pending",
      filing_date: form.filing_date || null,
      due_date: form.due_date || null,
      reference_no: form.reference_no.trim() || null,
      tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined,
    };
    if (!payload.tenant_id) delete payload.tenant_id;

    const { error } = await supabase.from("law_regulatory_filings").insert(payload);
    if (error) { setError(error.message); return; }
    setOpen(false);
    setForm({ title: "", filing_type: "", filing_date: "", reference_no: "", due_date: "" });
    setSnack("Filing created as pending");
    fetchData();
  };

  const confirmTransition = async () => {
    if (!transition) return;
    setBusy(true);
    const { error } = await supabase.rpc("transition_filing", {
      p_filing_id: transition.filing.id,
      p_status: transition.to,
      p_note: note.trim() || null,
    });
    setBusy(false);
    if (error) { setError(error.message); return; }
    setSnack(`${transition.filing.title}: ${transition.label.toLowerCase()}`);
    setTransition(null);
    setNote("");
    fetchData();
  };

  const openHistory = async (filing: Filing) => {
    setHistoryFor(filing);
    setEvents([]);
    setEventsLoading(true);
    const { data } = await supabase
      .from("law_filing_events")
      .select("id, status, note, created_at, app_users(name)")
      .eq("filing_id", filing.id)
      .order("created_at", { ascending: false });
    if (data) {
      setEvents(data.map((e: any) => ({
        ...e,
        app_users: Array.isArray(e.app_users) ? e.app_users[0] ?? null : e.app_users ?? null,
      })) as FilingEvent[]);
    }
    setEventsLoading(false);
  };

  const getStatusColor = (s: string) => {
    if (s === 'filed' || s === 'approved') return 'success';
    if (s === 'rejected') return 'error';
    return 'warning';
  };

  const isOverdue = (f: Filing) =>
    f.due_date != null && new Date(f.due_date).getTime() < Date.now() && f.status !== 'approved';

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Regulatory Filings</Typography>
          <Typography variant="body2" color="text.secondary">
            {filings.length} filings. Filings start pending and move through filed → approved/rejected with a full audit trail.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Filing</Button>
      </Box>

      {error && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>{error}</Alert>}

      <Card><CardContent sx={{ p: 0 }}>
        <Table>
          <TableHead>
            <TableRow>
              <TableCell>Title</TableCell>
              <TableCell>Type</TableCell>
              <TableCell>Reference No</TableCell>
              <TableCell>Due Date</TableCell>
              <TableCell>Filing Date</TableCell>
              <TableCell>Status</TableCell>
              <TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {filings.length === 0 ? (
              <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}>
                <Typography color="text.secondary">No filings yet. Track regulatory submissions.</Typography>
              </TableCell></TableRow>
            ) : filings.map(f => {
              const nextStates = NEXT_STATES[f.status] ?? [];
              return (
                <TableRow key={f.id} hover>
                  <TableCell><Typography fontWeight={600}>{f.title}</Typography></TableCell>
                  <TableCell>{f.filing_type || "-"}</TableCell>
                  <TableCell>{f.reference_no || "-"}</TableCell>
                  <TableCell>
                    {f.due_date ? (
                      <Box>
                        <Typography variant="body2">{new Date(f.due_date).toLocaleDateString()}</Typography>
                        {isOverdue(f) && <Chip label="Overdue" size="small" color="error" sx={{ mt: 0.5 }} />}
                      </Box>
                    ) : "-"}
                  </TableCell>
                  <TableCell>{f.filing_date ? new Date(f.filing_date).toLocaleDateString() : "-"}</TableCell>
                  <TableCell><Chip label={f.status} size="small" color={getStatusColor(f.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                  <TableCell align="right">
                    <Tooltip title="Transition history"><IconButton size="small" onClick={() => openHistory(f)}><History fontSize="small" /></IconButton></Tooltip>
                    <span>
                      <IconButton size="small" disabled={nextStates.length === 0} onClick={(e) => setMenuFor({ anchor: e.currentTarget, filing: f })} aria-label="Transitions">
                        <MoreVert fontSize="small" />
                      </IconButton>
                    </span>
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </CardContent></Card>

      <Menu anchorEl={menuFor?.anchor} open={!!menuFor} onClose={() => setMenuFor(null)}>
        {(NEXT_STATES[menuFor?.filing.status ?? "pending"] ?? []).map(ns => (
          <MenuItem key={ns.to} onClick={() => {
            setTransition({ filing: menuFor!.filing, to: ns.to, label: ns.label });
            setNote("");
            setMenuFor(null);
          }}>
            <ListItemText primary={ns.label} secondary={menuFor?.filing.title} />
          </MenuItem>
        ))}
      </Menu>

      {/* Create dialog */}
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>New Filing</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. Annual Returns Filing" />
          <TextField label="Filing Type" value={form.filing_type} onChange={e => setForm({ ...form, filing_type: e.target.value })} fullWidth placeholder="Tax, URSB, NSSF, etc." />
          <Grid container spacing={2}>
            <Grid item xs={6}><TextField label="Reference No" value={form.reference_no} onChange={e => setForm({ ...form, reference_no: e.target.value })} fullWidth placeholder="Filing receipt no" /></Grid>
            <Grid item xs={6}><TextField label="Due Date" type="date" value={form.due_date} onChange={e => setForm({ ...form, due_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
          </Grid>
          <TextField label="Filing Date (if already filed)" type="date" value={form.filing_date} onChange={e => setForm({ ...form, filing_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
          <Alert severity="info">New filings always start as <strong>pending</strong>; an admin/manager then files and approves them through the tracked workflow.</Alert>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.title.trim()}>Create</Button>
        </DialogActions>
      </Dialog>

      {/* Transition dialog */}
      <Dialog open={!!transition} onClose={() => !busy && setTransition(null)} maxWidth="sm" fullWidth>
        <DialogTitle>{transition?.label}: {transition?.filing.title}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField label="Note (optional)" value={note} onChange={e => setNote(e.target.value)} fullWidth multiline minRows={2} autoFocus placeholder="e.g. Filed with URSB, receipt attached to email" />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setTransition(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={confirmTransition} disabled={busy}>{busy ? "Saving…" : "Confirm"}</Button>
        </DialogActions>
      </Dialog>

      {/* History dialog */}
      <Dialog open={!!historyFor} onClose={() => setHistoryFor(null)} maxWidth="sm" fullWidth>
        <DialogTitle>History — {historyFor?.title}</DialogTitle>
        <DialogContent dividers>
          {eventsLoading ? (
            <Box sx={{ display: "flex", justifyContent: "center", py: 3 }}><CircularProgress size={28} /></Box>
          ) : events.length === 0 ? (
            <Typography variant="body2" color="text.secondary">No transitions recorded yet.</Typography>
          ) : events.map((e, i) => (
            <Box key={e.id}>
              {i > 0 && <Divider sx={{ my: 1.5 }} />}
              <Box sx={{ display: "flex", alignItems: "center", gap: 1, flexWrap: "wrap" }}>
                <Chip label={e.status} size="small" color={getStatusColor(e.status) as any} sx={{ textTransform: "capitalize", minWidth: 80 }} />
                <Typography variant="body2" fontWeight={600}>{e.app_users?.name ?? "Unknown user"}</Typography>
                <Typography variant="body2" color="text.secondary">{new Date(e.created_at).toLocaleString()}</Typography>
              </Box>
              {e.note && <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5, ml: 1 }}>{e.note}</Typography>}
            </Box>
          ))}
        </DialogContent>
      </Dialog>

      <Snackbar open={!!snack} autoHideDuration={4000} onClose={() => setSnack(null)} message={snack ?? ""} />
    </Box>
  );
}
