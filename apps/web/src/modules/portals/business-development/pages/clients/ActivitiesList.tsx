import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Client { id: string; name: string; }
interface Activity { id: string; tenant_id: string; type: string; subject: string; description: string | null; client_id: string | null; activity_date: string; created_at: string; bd_clients?: { name: string } | null; }

export default function ActivitiesList() {
  const { session } = useAuth();
  const [activities, setActivities] = useState<Activity[]>([]);
  const [clients, setClients] = useState<Client[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ type: "call" as 'call'|'meeting'|'email'|'note'|'site_visit', subject: "", description: "", client_id: "", activity_date: new Date().toISOString().slice(0, 16) });

  const fetchData = async () => {
    setLoading(true);
    const [actsRes, clientsRes] = await Promise.all([
      supabase.from("bd_activities").select("*, bd_clients(name)").order("activity_date", { ascending: false }).limit(100),
      supabase.from("bd_clients").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (actsRes.data) setActivities(actsRes.data as Activity[]);
    if (clientsRes.data) setClients(clientsRes.data as Client[]);
    setLoading(false);
  };
  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.subject.trim()) return;
    const payload: any = {
      type: form.type,
      subject: form.subject.trim(),
      description: form.description.trim() || null,
      client_id: form.client_id || null,
      activity_date: form.activity_date ? new Date(form.activity_date).toISOString() : new Date().toISOString(),
      created_by: session?.user?.id,
    };
    const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || activities[0]?.tenant_id;
    if (tenant_id) payload.tenant_id = tenant_id;
    const { error } = await supabase.from("bd_activities").insert(payload);
    if (error) alert(error.message);
    else { setOpen(false); setForm({ type: "call", subject: "", description: "", client_id: "", activity_date: new Date().toISOString().slice(0, 16) }); fetchData(); }
  };

  const getTypeColor = (t: string) => {
    switch (t) {
      case "meeting": return "primary";
      case "call": return "info";
      case "email": return "secondary";
      case "site_visit": return "warning";
      default: return "default";
    }
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Activities & Meetings</Typography><Typography variant="body2" color="text.secondary">Timeline of calls, meetings, emails, notes, site visits linked to clients. {activities.length} activities.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Activity</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Type</TableCell><TableCell>Subject</TableCell><TableCell>Client</TableCell><TableCell>Description</TableCell></TableRow></TableHead><TableBody>{activities.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No activities yet. Log calls, meetings, emails with clients.</Typography></TableCell></TableRow> : activities.map(a => <TableRow key={a.id} hover><TableCell><Typography variant="caption">{new Date(a.activity_date).toLocaleString()}</Typography></TableCell><TableCell><Chip label={a.type} size="small" color={getTypeColor(a.type) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell><Typography fontWeight={600}>{a.subject}</Typography></TableCell><TableCell>{a.bd_clients?.name || "-"}</TableCell><TableCell><Typography variant="body2" color="text.secondary" sx={{ maxWidth: 300, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{a.description || "-"}</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Activity</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><Grid container spacing={2}><Grid item xs={6}><TextField select label="Type" value={form.type} onChange={e => setForm({ ...form, type: e.target.value as any })} fullWidth><MenuItem value="call">Call</MenuItem><MenuItem value="meeting">Meeting</MenuItem><MenuItem value="email">Email</MenuItem><MenuItem value="note">Note</MenuItem><MenuItem value="site_visit">Site Visit</MenuItem></TextField></Grid><Grid item xs={6}><TextField label="Date & Time" type="datetime-local" value={form.activity_date} onChange={e => setForm({ ...form, activity_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid><TextField label="Subject *" value={form.subject} onChange={e => setForm({ ...form, subject: e.target.value })} fullWidth required placeholder="e.g. Intro call with procurement manager" /><TextField select label="Client" value={form.client_id} onChange={e => setForm({ ...form, client_id: e.target.value })} fullWidth><MenuItem value="">-- No client link --</MenuItem>{clients.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}</TextField><TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={3} placeholder="What was discussed, next steps..." /></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.subject.trim()}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
