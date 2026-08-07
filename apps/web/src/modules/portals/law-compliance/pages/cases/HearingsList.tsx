import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Case { id: string; case_no: string; title: string; }
interface Hearing { id: string; tenant_id: string; case_id: string; hearing_date: string; location: string | null; outcome: string | null; notes: string | null; created_at: string; law_cases?: { case_no: string; title: string } | null; }

export default function HearingsList() {
  const { session } = useAuth();
  const [hearings, setHearings] = useState<Hearing[]>([]);
  const [cases, setCases] = useState<Case[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ case_id: "", hearing_date: "", location: "", outcome: "", notes: "" });

  const fetchData = async () => {
    setLoading(true);
    const [hearingsRes, casesRes] = await Promise.all([
      supabase.from("law_case_hearings").select("*, law_cases(case_no, title)").order("hearing_date", { ascending: false }).limit(100),
      supabase.from("law_cases").select("id, case_no, title").order("created_at", { ascending: false }),
    ]);
    if (hearingsRes.data) setHearings(hearingsRes.data as Hearing[]);
    else if (hearingsRes.error) console.warn("law_case_hearings may not exist:", hearingsRes.error.message);
    if (casesRes.data) setCases(casesRes.data as Case[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.case_id || !form.hearing_date) return;
    const payload: any = {
      case_id: form.case_id,
      hearing_date: new Date(form.hearing_date).toISOString(),
      location: form.location.trim() || null,
      outcome: form.outcome.trim() || null,
      notes: form.notes.trim() || null,
      tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined,
    };
    if (!payload.tenant_id) delete payload.tenant_id;

    const { error } = await supabase.from("law_case_hearings").insert(payload);
    if (error) {
      if (error.message.includes("does not exist")) {
        // Mock for shell without table
        const mock: Hearing = {
          id: Math.random().toString(36).substring(7),
          tenant_id: "mock",
          case_id: form.case_id,
          hearing_date: new Date(form.hearing_date).toISOString(),
          location: form.location || null,
          outcome: form.outcome || null,
          notes: form.notes || null,
          created_at: new Date().toISOString(),
          law_cases: cases.find(c => c.id === form.case_id) ? { case_no: cases.find(c => c.id === form.case_id)!.case_no, title: cases.find(c => c.id === form.case_id)!.title } : null,
        };
        setHearings(prev => [mock, ...prev]);
        setOpen(false);
        setForm({ case_id: "", hearing_date: "", location: "", outcome: "", notes: "" });
        return;
      }
      alert(error.message);
      return;
    }
    setOpen(false);
    setForm({ case_id: "", hearing_date: "", location: "", outcome: "", notes: "" });
    fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Hearings & Sessions</Typography><Typography variant="body2" color="text.secondary">{hearings.length} hearings. Linked to legal cases.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Hearing</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Case</TableCell><TableCell>Location</TableCell><TableCell>Outcome</TableCell><TableCell>Notes</TableCell></TableRow></TableHead><TableBody>{hearings.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No hearings yet. Log hearing dates for legal cases.</Typography></TableCell></TableRow> : hearings.map(h => <TableRow key={h.id} hover><TableCell>{new Date(h.hearing_date).toLocaleString()}</TableCell><TableCell><Typography fontWeight={600}>{h.law_cases ? `${h.law_cases.case_no} - ${h.law_cases.title}` : "-"}</Typography></TableCell><TableCell>{h.location || "-"}</TableCell><TableCell><Chip label={h.outcome || "Pending"} size="small" variant="outlined" /></TableCell><TableCell><Typography variant="body2" color="text.secondary" sx={{ maxWidth: 250, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{h.notes || "-"}</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Hearing</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Case *" value={form.case_id} onChange={e => setForm({ ...form, case_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Case --</MenuItem>{cases.map(c => <MenuItem key={c.id} value={c.id}>{c.case_no} - {c.title}</MenuItem>)}</TextField><TextField label="Hearing Date & Time *" type="datetime-local" value={form.hearing_date} onChange={e => setForm({ ...form, hearing_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /><Grid container spacing={2}><Grid item xs={6}><TextField label="Location" value={form.location} onChange={e => setForm({ ...form, location: e.target.value })} fullWidth placeholder="Court name, room" /></Grid><Grid item xs={6}><TextField label="Outcome" value={form.outcome} onChange={e => setForm({ ...form, outcome: e.target.value })} fullWidth placeholder="Adjourned, Judgement, etc." /></Grid></Grid><TextField label="Notes" value={form.notes} onChange={e => setForm({ ...form, notes: e.target.value })} fullWidth multiline rows={3} /></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.case_id || !form.hearing_date}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
