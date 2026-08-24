import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, IconButton, Tooltip, Dialog, DialogActions, DialogContent, DialogTitle, Grid, Alert, InputAdornment } from "@mui/material";
import { Add, Edit, Visibility } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Tender {
  id: string;
  tender_no: string;
  title: string;
  status: string;
  client_id: string | null;
  type_id: string | null;
  submission_deadline: string | null;
  estimated_value: number | null;
  currency: string;
  portal_url: string | null;
  description: string | null;
  created_at: string;
  bd_clients?: { name: string } | null;
  bd_tender_types?: { name: string } | null;
}
interface Client { id: string; name: string; }
interface TenderType { id: string; name: string; }

// Convert an ISO timestamp to the value a datetime-local input expects
// (local time, "YYYY-MM-DDTHH:mm"), and back on save.
const toDateTimeLocal = (iso: string) => {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
};

export default function TendersList() {
  const navigate = useNavigate();
  const [tenders, setTenders] = useState<Tender[]>([]);
  const [clients, setClients] = useState<Client[]>([]);
  const [types, setTypes] = useState<TenderType[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");

  const [editOpen, setEditOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [editError, setEditError] = useState<string | null>(null);
  const [form, setForm] = useState({
    title: "",
    client_id: "",
    type_id: "",
    status: "open",
    submission_deadline: "",
    estimated_value: "",
    currency: "UGX",
    portal_url: "",
    description: "",
  });

  const fetchTenders = async () => {
    setLoading(true);
    let query = supabase.from("bd_tenders").select("*, bd_clients(name), bd_tender_types(name)").order("submission_deadline", { ascending: true, nullsFirst: false });
    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    const { data } = await query;
    if (data) setTenders(data as Tender[]);
    setLoading(false);
  };

  const fetchLookups = async () => {
    const [clientsRes, typesRes] = await Promise.all([
      supabase.from("bd_clients").select("id, name").eq("is_active", true).order("name"),
      supabase.from("bd_tender_types").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (clientsRes.data) setClients(clientsRes.data as Client[]);
    if (typesRes.data) setTypes(typesRes.data as TenderType[]);
  };

  useEffect(() => { fetchTenders(); }, [statusFilter]);
  useEffect(() => { fetchLookups(); }, []);

  const getStatusColor = (s: string) => {
    if (s === 'awarded') return 'success';
    if (s === 'lost' || s === 'cancelled') return 'error';
    if (s === 'submitted' || s === 'under_evaluation') return 'primary';
    return 'default';
  };

  const isNearDeadline = (deadline: string | null) => {
    if (!deadline) return false;
    const diff = new Date(deadline).getTime() - new Date().getTime();
    return diff > 0 && diff < 3 * 24 * 60 * 60 * 1000; // 3 days
  };

  const handleOpenEdit = (t: Tender) => {
    setEditingId(t.id);
    setEditError(null);
    setForm({
      title: t.title,
      client_id: t.client_id || "",
      type_id: t.type_id || "",
      status: t.status,
      submission_deadline: t.submission_deadline ? toDateTimeLocal(t.submission_deadline) : "",
      estimated_value: t.estimated_value != null ? String(t.estimated_value) : "",
      currency: t.currency,
      portal_url: t.portal_url || "",
      description: t.description || "",
    });
    setEditOpen(true);
  };

  const handleSaveEdit = async () => {
    if (!editingId) return;
    setEditError(null);
    if (!form.title.trim()) { setEditError("Title is required."); return; }
    setSaving(true);
    const { error: updateError } = await supabase
      .from("bd_tenders")
      .update({
        title: form.title.trim(),
        client_id: form.client_id || null,
        type_id: form.type_id || null,
        status: form.status,
        submission_deadline: form.submission_deadline ? new Date(form.submission_deadline).toISOString() : null,
        estimated_value: form.estimated_value ? parseFloat(form.estimated_value) : null,
        currency: form.currency,
        portal_url: form.portal_url.trim() || null,
        description: form.description.trim() || null,
      })
      .eq("id", editingId);
    setSaving(false);
    if (updateError) {
      setEditError(`Failed to update tender: ${updateError.message}`);
      return;
    }
    setEditOpen(false);
    setEditingId(null);
    fetchTenders();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Tenders</Typography>
          <Typography variant="body2" color="text.secondary">{tenders.length} tenders • Tracks deadline, submissions, award status</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/business-development/tenders/new")}>New Tender</Button>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2 }}>
          <TextField select label="Status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} size="small" sx={{ minWidth: 200 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="open">Open</MenuItem>
            <MenuItem value="submitted">Submitted</MenuItem>
            <MenuItem value="under_evaluation">Under Evaluation</MenuItem>
            <MenuItem value="awarded">Awarded</MenuItem>
            <MenuItem value="lost">Lost</MenuItem>
            <MenuItem value="cancelled">Cancelled</MenuItem>
          </TextField>
        </CardContent>
      </Card>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Tender No</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Deadline</TableCell>
                <TableCell>Value</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {tenders.length === 0 ? (
                <TableRow><TableCell colSpan={8} sx={{ textAlign: "center", py: 6 }}><Typography color="text.secondary">No tenders yet. Create first via New Tender.</Typography></TableCell></TableRow>
              ) : (
                tenders.map(t => (
                  <TableRow key={t.id} hover sx={{ bgcolor: isNearDeadline(t.submission_deadline) ? "warning.light" : "inherit" }}>
                    <TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{t.tender_no || "-"}</Typography></TableCell>
                    <TableCell><Typography fontWeight={600} variant="body2">{t.title}</Typography></TableCell>
                    <TableCell>{t.bd_clients?.name || "-"}</TableCell>
                    <TableCell><Chip label={t.bd_tender_types?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell><Chip label={t.status} size="small" color={getStatusColor(t.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>
                      {t.submission_deadline ? (
                        <Box>
                          <Typography variant="body2">{new Date(t.submission_deadline).toLocaleDateString()}</Typography>
                          {isNearDeadline(t.submission_deadline) && <Chip label="Due soon" size="small" color="warning" sx={{ mt: 0.5 }} />}
                        </Box>
                      ) : "-"}
                    </TableCell>
                    <TableCell>{t.estimated_value ? `${t.currency} ${Number(t.estimated_value).toLocaleString()}` : "-"}</TableCell>
                    <TableCell align="right">
                      <Tooltip title="View"><IconButton size="small" onClick={() => navigate(`/business-development/tenders/${t.id}`)}><Visibility fontSize="small" /></IconButton></Tooltip>
                      <Tooltip title="Edit"><IconButton size="small" onClick={() => handleOpenEdit(t)}><Edit fontSize="small" /></IconButton></Tooltip>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={editOpen} onClose={() => !saving && setEditOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Edit Tender</DialogTitle>
        <DialogContent sx={{ pt: 2 }}>
          {editError && <Alert severity="error" sx={{ mb: 2 }}>{editError}</Alert>}
          <Grid container spacing={2}>
            <Grid item xs={12}>
              <TextField label="Tender Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField select label="Client" value={form.client_id} onChange={e => setForm({ ...form, client_id: e.target.value })} fullWidth>
                <MenuItem value="">-- None --</MenuItem>
                {clients.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField select label="Tender Type" value={form.type_id} onChange={e => setForm({ ...form, type_id: e.target.value })} fullWidth>
                <MenuItem value="">-- None --</MenuItem>
                {types.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth helperText="Submitted or later shows on the Submissions page">
                <MenuItem value="open">Open</MenuItem>
                <MenuItem value="submitted">Submitted</MenuItem>
                <MenuItem value="under_evaluation">Under Evaluation</MenuItem>
                <MenuItem value="awarded">Awarded</MenuItem>
                <MenuItem value="lost">Lost</MenuItem>
                <MenuItem value="cancelled">Cancelled</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField label="Submission Deadline" type="datetime-local" value={form.submission_deadline} onChange={e => setForm({ ...form, submission_deadline: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField label="Estimated Value" type="number" value={form.estimated_value} onChange={e => setForm({ ...form, estimated_value: e.target.value })} fullWidth InputProps={{ startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment> }} />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField select label="Currency" value={form.currency} onChange={e => setForm({ ...form, currency: e.target.value })} fullWidth>
                <MenuItem value="USD">USD</MenuItem>
                <MenuItem value="UGX">UGX</MenuItem>
                <MenuItem value="EUR">EUR</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12}>
              <TextField label="Portal URL" value={form.portal_url} onChange={e => setForm({ ...form, portal_url: e.target.value })} fullWidth placeholder="https://tender portal link" />
            </Grid>
            <Grid item xs={12}>
              <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={3} />
            </Grid>
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditOpen(false)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={handleSaveEdit} disabled={saving || !form.title.trim()}>
            {saving ? "Saving..." : "Update Tender"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
