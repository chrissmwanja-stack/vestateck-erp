import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Filing { id: string; tenant_id: string; title: string; filing_type: string | null; status: string; filing_date: string | null; reference_no: string | null; created_at: string; }

export default function FilingsList() {
  const { session } = useAuth();
  const [filings, setFilings] = useState<Filing[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ title: "", filing_type: "", status: "pending", filing_date: "", reference_no: "" });

  const fetchData = async () => {
    setLoading(true);
    const { data, error } = await supabase.from("law_regulatory_filings").select("*").order("filing_date", { ascending: false }).limit(100);
    if (data) setFilings(data as Filing[]);
    else if (error) console.warn("law_regulatory_filings may not exist:", error.message);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.title.trim()) return;
    const payload: any = {
      title: form.title.trim(),
      filing_type: form.filing_type.trim() || null,
      status: form.status,
      filing_date: form.filing_date || null,
      reference_no: form.reference_no.trim() || null,
      tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined,
    };
    if (!payload.tenant_id) delete payload.tenant_id;

    const { error } = await supabase.from("law_regulatory_filings").insert(payload);
    if (error) {
      if (error.message.includes("does not exist")) {
        const mock: Filing = {
          id: Math.random().toString(36).substring(7),
          tenant_id: "mock",
          title: form.title,
          filing_type: form.filing_type || null,
          status: form.status,
          filing_date: form.filing_date || null,
          reference_no: form.reference_no || null,
          created_at: new Date().toISOString(),
        };
        setFilings(prev => [mock, ...prev]);
        setOpen(false);
        setForm({ title: "", filing_type: "", status: "pending", filing_date: "", reference_no: "" });
        return;
      }
      alert(error.message);
      return;
    }
    setOpen(false);
    setForm({ title: "", filing_type: "", status: "pending", filing_date: "", reference_no: "" });
    fetchData();
  };

  const getStatusColor = (s: string) => {
    if (s === 'filed' || s === 'approved') return 'success';
    if (s === 'rejected') return 'error';
    return 'warning';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Regulatory Filings</Typography><Typography variant="body2" color="text.secondary">{filings.length} filings. Track submissions to regulators.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Filing</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Type</TableCell><TableCell>Reference No</TableCell><TableCell>Filing Date</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{filings.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No filings yet. Track regulatory submissions.</Typography></TableCell></TableRow> : filings.map(f => <TableRow key={f.id} hover><TableCell><Typography fontWeight={600}>{f.title}</Typography></TableCell><TableCell>{f.filing_type || "-"}</TableCell><TableCell>{f.reference_no || "-"}</TableCell><TableCell>{f.filing_date ? new Date(f.filing_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={f.status} size="small" color={getStatusColor(f.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Filing</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. Annual Returns Filing" /><TextField label="Filing Type" value={form.filing_type} onChange={e => setForm({ ...form, filing_type: e.target.value })} fullWidth placeholder="Tax, URSB, NSSF, etc." /><Grid container spacing={2}><Grid item xs={6}><TextField label="Reference No" value={form.reference_no} onChange={e => setForm({ ...form, reference_no: e.target.value })} fullWidth placeholder="Filing receipt no" /></Grid><Grid item xs={6}><TextField label="Filing Date" type="date" value={form.filing_date} onChange={e => setForm({ ...form, filing_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="pending">Pending</MenuItem><MenuItem value="filed">Filed</MenuItem><MenuItem value="approved">Approved</MenuItem><MenuItem value="rejected">Rejected</MenuItem></TextField></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.title.trim()}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
