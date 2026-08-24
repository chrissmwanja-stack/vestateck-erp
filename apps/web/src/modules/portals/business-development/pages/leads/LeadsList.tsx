import { useEffect, useState } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Grid,
  Alert,
  IconButton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  MenuItem,
  Tooltip,
  InputAdornment,
} from "@mui/material";
import { Add, Search, Edit, Visibility, TrendingUp } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Lead {
  id: string;
  lead_no: string;
  company_name: string;
  contact_name: string;
  email: string | null;
  phone: string | null;
  source_id: string;
  status: string;
  estimated_value: number | null;
  currency: string;
  notes: string | null;
  created_at: string;
  bd_lead_sources?: { name: string } | null;
}

interface Source {
  id: string;
  name: string;
}

export default function LeadsList() {
  const navigate = useNavigate();
  const [leads, setLeads] = useState<Lead[]>([]);
  const [sources, setSources] = useState<Source[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [sourceFilter, setSourceFilter] = useState("all");

  const [editOpen, setEditOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [editError, setEditError] = useState<string | null>(null);
  const [form, setForm] = useState({
    company_name: "",
    contact_name: "",
    email: "",
    phone: "",
    source_id: "",
    status: "new",
    estimated_value: "",
    currency: "UGX",
    notes: "",
  });

  const fetchData = async () => {
    setLoading(true);
    const { data: srcData } = await supabase.from("bd_lead_sources").select("id, name").eq("is_active", true).order("name");
    if (srcData) setSources(srcData as Source[]);

    let query = supabase
      .from("bd_leads")
      .select("*, bd_lead_sources(name)")
      .order("created_at", { ascending: false });

    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    if (sourceFilter !== "all") query = query.eq("source_id", sourceFilter);

    const { data, error } = await query;
    if (error) console.error(error);
    else setLeads(data as Lead[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, [statusFilter, sourceFilter]);

  const filtered = leads.filter(l => {
    if (!search) return true;
    const s = search.toLowerCase();
    return (
      l.company_name.toLowerCase().includes(s) ||
      l.contact_name.toLowerCase().includes(s) ||
      l.lead_no.toLowerCase().includes(s) ||
      (l.email || "").toLowerCase().includes(s)
    );
  });

  const getStatusColor = (status: string) => {
    switch (status) {
      case "new": return "default";
      case "contacted": return "info";
      case "qualified": return "success";
      case "unqualified": return "warning";
      case "converted": return "primary";
      case "lost": return "error";
      default: return "default";
    }
  };

  const handleOpenEdit = (lead: Lead) => {
    setEditingId(lead.id);
    setEditError(null);
    setForm({
      company_name: lead.company_name,
      contact_name: lead.contact_name,
      email: lead.email || "",
      phone: lead.phone || "",
      source_id: lead.source_id || "",
      status: lead.status,
      estimated_value: lead.estimated_value != null ? String(lead.estimated_value) : "",
      currency: lead.currency,
      notes: lead.notes || "",
    });
    setEditOpen(true);
  };

  const handleSaveEdit = async () => {
    if (!editingId) return;
    setEditError(null);
    if (!form.company_name.trim() || !form.contact_name.trim() || !form.source_id) {
      setEditError("Company name, Contact name, and Source are required.");
      return;
    }
    setSaving(true);
    const { error: updateError } = await supabase
      .from("bd_leads")
      .update({
        company_name: form.company_name.trim(),
        contact_name: form.contact_name.trim(),
        email: form.email.trim() || null,
        phone: form.phone.trim() || null,
        source_id: form.source_id,
        status: form.status,
        estimated_value: form.estimated_value ? parseFloat(form.estimated_value) : null,
        currency: form.currency,
        notes: form.notes.trim() || null,
      })
      .eq("id", editingId);
    setSaving(false);
    if (updateError) {
      setEditError(`Failed to update lead: ${updateError.message}`);
      return;
    }
    setEditOpen(false);
    setEditingId(null);
    fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3, flexWrap: "wrap", gap: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Leads</Typography>
          <Typography variant="body2" color="text.secondary">All business leads with source and status tracking. {filtered.length} leads</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/business-development/leads/new")}>
          New Lead
        </Button>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2, flexWrap: "wrap" }}>
          <TextField
            placeholder="Search company, contact, lead no..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            size="small"
            sx={{ minWidth: 280, flex: 1 }}
            InputProps={{ startAdornment: <InputAdornment position="start"><Search fontSize="small" /></InputAdornment> }}
          />
          <TextField select label="Status" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} size="small" sx={{ minWidth: 150 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="new">New</MenuItem>
            <MenuItem value="contacted">Contacted</MenuItem>
            <MenuItem value="qualified">Qualified</MenuItem>
            <MenuItem value="unqualified">Unqualified</MenuItem>
            <MenuItem value="converted">Converted</MenuItem>
            <MenuItem value="lost">Lost</MenuItem>
          </TextField>
          <TextField select label="Source" value={sourceFilter} onChange={(e) => setSourceFilter(e.target.value)} size="small" sx={{ minWidth: 180 }}>
            <MenuItem value="all">All Sources</MenuItem>
            {sources.map(s => <MenuItem key={s.id} value={s.id}>{s.name}</MenuItem>)}
          </TextField>
        </CardContent>
      </Card>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Lead No</TableCell>
                <TableCell>Company</TableCell>
                <TableCell>Contact</TableCell>
                <TableCell>Source</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Value</TableCell>
                <TableCell>Created</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={8} sx={{ textAlign: "center", py: 6 }}>
                    <Typography color="text.secondary">No leads found. {leads.length === 0 ? "Create your first lead via New Lead form." : "Try adjusting filters."}</Typography>
                  </TableCell>
                </TableRow>
              ) : (
                filtered.map(lead => (
                  <TableRow key={lead.id} hover>
                    <TableCell><Typography variant="body2" fontFamily="monospace" fontWeight={600}>{lead.lead_no}</Typography></TableCell>
                    <TableCell><Typography variant="body2" fontWeight={600}>{lead.company_name}</Typography></TableCell>
                    <TableCell>
                      <Typography variant="body2">{lead.contact_name}</Typography>
                      <Typography variant="caption" color="text.secondary">{lead.email || "-"}</Typography>
                    </TableCell>
                    <TableCell><Chip label={lead.bd_lead_sources?.name || "Unknown"} size="small" variant="outlined" /></TableCell>
                    <TableCell><Chip label={lead.status} size="small" color={getStatusColor(lead.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>{lead.estimated_value ? `${lead.currency} ${Number(lead.estimated_value).toLocaleString()}` : "-"}</TableCell>
                    <TableCell><Typography variant="caption">{new Date(lead.created_at).toLocaleDateString()}</Typography></TableCell>
                    <TableCell align="right">
                      <Tooltip title="View"><IconButton size="small" onClick={() => navigate(`/business-development/leads/${lead.id}`)}><Visibility fontSize="small" /></IconButton></Tooltip>
                      <Tooltip title="Edit"><IconButton size="small" onClick={() => handleOpenEdit(lead)}><Edit fontSize="small" /></IconButton></Tooltip>
                      <Tooltip title="Convert to Opportunity">
                        <IconButton size="small" color="primary" onClick={() => navigate(`/business-development/opportunities/new?lead_id=${lead.id}`)}>
                          <TrendingUp fontSize="small" />
                        </IconButton>
                      </Tooltip>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={editOpen} onClose={() => !saving && setEditOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Edit Lead</DialogTitle>
        <DialogContent sx={{ pt: 2 }}>
          {editError && <Alert severity="error" sx={{ mb: 2 }}>{editError}</Alert>}
          <Grid container spacing={2}>
            <Grid item xs={12} sm={6}>
              <TextField label="Company Name *" value={form.company_name} onChange={(e) => setForm({ ...form, company_name: e.target.value })} fullWidth required />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField label="Contact Name *" value={form.contact_name} onChange={(e) => setForm({ ...form, contact_name: e.target.value })} fullWidth required />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField label="Email" type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} fullWidth />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField label="Phone" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} fullWidth />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField select label="Source *" value={form.source_id} onChange={(e) => setForm({ ...form, source_id: e.target.value })} fullWidth required>
                {sources.map((s) => (
                  <MenuItem key={s.id} value={s.id}>{s.name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField select label="Status" value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })} fullWidth>
                <MenuItem value="new">New</MenuItem>
                <MenuItem value="contacted">Contacted</MenuItem>
                <MenuItem value="qualified">Qualified</MenuItem>
                <MenuItem value="unqualified">Unqualified</MenuItem>
                <MenuItem value="converted">Converted</MenuItem>
                <MenuItem value="lost">Lost</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField label="Estimated Value" type="number" value={form.estimated_value} onChange={(e) => setForm({ ...form, estimated_value: e.target.value })} fullWidth InputProps={{ startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment> }} />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField select label="Currency" value={form.currency} onChange={(e) => setForm({ ...form, currency: e.target.value })} fullWidth>
                <MenuItem value="USD">USD</MenuItem>
                <MenuItem value="UGX">UGX</MenuItem>
                <MenuItem value="EUR">EUR</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12}>
              <TextField label="Notes" value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} fullWidth multiline rows={3} />
            </Grid>
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditOpen(false)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={handleSaveEdit} disabled={saving || !form.company_name.trim() || !form.contact_name.trim() || !form.source_id}>
            {saving ? "Saving..." : "Update Lead"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
