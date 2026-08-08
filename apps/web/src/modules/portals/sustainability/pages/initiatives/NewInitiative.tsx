import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, TextField, Typography, MenuItem, Grid, Alert, CircularProgress } from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Category { id: string; name: string; }

export default function NewInitiative() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [categories, setCategories] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [form, setForm] = useState({
    title: "",
    category_id: "",
    status: "planned",
    target_value: "",
    current_value: "",
    owner: "",
    start_date: "",
    end_date: "",
    description: "",
  });

  useEffect(() => {
    const fetchCats = async () => {
      setLoading(true);
      const { data } = await supabase.from("sustainability_initiative_categories").select("id, name").eq("is_active", true).order("name");
      if (data) setCategories(data as Category[]);
      setLoading(false);
    };
    fetchCats();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.title.trim()) { setError("Title required"); return; }
    setSaving(true);
    const { data: tenantData } = await supabase.from("sustainability_initiative_categories").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      title: form.title.trim(),
      category_id: form.category_id || null,
      status: form.status,
      target_value: form.target_value ? parseFloat(form.target_value) : null,
      current_value: form.current_value ? parseFloat(form.current_value) : null,
      owner: form.owner.trim() || null,
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      description: form.description.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { error } = await supabase.from("sustainability_initiatives").insert(payload);
    setSaving(false);
    if (error) setError(`Failed: ${error.message}`);
    else navigate("/sustainability/initiatives");
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Initiative</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Create sustainability initiative with category, target, owner, dates. Tracks progress target vs current.</Typography>
      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {categories.length === 0 && <Alert severity="warning" sx={{ mb: 2 }}>No Initiative Categories found. Go to Admin → Initiative Categories and create Energy Efficiency, Waste Reduction etc.</Alert>}

      <Card><CardContent><Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}><Grid container spacing={2}><Grid item xs={12}><TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required placeholder="e.g. Reduce carbon by 20% in 2026" /></Grid><Grid item xs={6}><TextField select label="Category" value={form.category_id} onChange={e => setForm({ ...form, category_id: e.target.value })} fullWidth><MenuItem value="">-- None --</MenuItem>{categories.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}</TextField></Grid><Grid item xs={6}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="planned">Planned</MenuItem><MenuItem value="in_progress">In Progress</MenuItem><MenuItem value="completed">Completed</MenuItem><MenuItem value="on_hold">On Hold</MenuItem></TextField></Grid><Grid item xs={4}><TextField label="Target Value" type="number" value={form.target_value} onChange={e => setForm({ ...form, target_value: e.target.value })} fullWidth placeholder="e.g. 100" /></Grid><Grid item xs={4}><TextField label="Current Value" type="number" value={form.current_value} onChange={e => setForm({ ...form, current_value: e.target.value })} fullWidth placeholder="e.g. 20" /></Grid><Grid item xs={4}><TextField label="Owner" value={form.owner} onChange={e => setForm({ ...form, owner: e.target.value })} fullWidth placeholder="Person responsible" /></Grid><Grid item xs={6}><TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={6}><TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={12}><TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={3} placeholder="Scope, actions, expected impact..." /></Grid></Grid><Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}><Button variant="outlined" onClick={() => navigate("/sustainability/initiatives")}>Cancel</Button><Button type="submit" variant="contained" disabled={saving}>{saving ? "Creating..." : "Create Initiative"}</Button></Box></Box></CardContent></Card>
    </Box>
  );
}
