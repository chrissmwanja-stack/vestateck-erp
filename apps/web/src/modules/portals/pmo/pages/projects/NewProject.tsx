import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, TextField, Typography, MenuItem, Grid, Alert, CircularProgress, InputAdornment } from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Category { id: string; name: string; }

export default function NewProject() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [categories, setCategories] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", category_id: "", client_name: "", status: "not_started", budget: "", currency: "USD", start_date: "", end_date: "", description: "" });

  useEffect(() => {
    const fetchCats = async () => {
      setLoading(true);
      const { data } = await supabase.from("pmo_project_categories").select("id, name").eq("is_active", true).order("name");
      if (data) setCategories(data as Category[]);
      setLoading(false);
    };
    fetchCats();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) { setError("Project name required"); return; }
    setSaving(true);
    const { data: tenantData } = await supabase.from("pmo_project_categories").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      name: form.name.trim(),
      category_id: form.category_id || null,
      client_name: form.client_name.trim() || null,
      status: form.status,
      budget: form.budget ? parseFloat(form.budget) : null,
      currency: form.currency,
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      description: form.description.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { error } = await supabase.from("pmo_projects").insert(payload);
    setSaving(false);
    if (error) setError(`Failed: ${error.message}`);
    else navigate("/pmo/projects");
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Project</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Create project with category lookup. Project No auto PMO-P-2026-0001 via trigger.</Typography>
      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {categories.length === 0 && <Alert severity="warning" sx={{ mb: 2 }}>No Project Categories found. Go to Admin → Categories and create Infrastructure, Building, etc.</Alert>}
      <Card><CardContent><Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}><Grid container spacing={2}><Grid item xs={12}><TextField label="Project Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth required placeholder="e.g. Kampala Office Complex" /></Grid><Grid item xs={12} sm={6}><TextField label="Client Name" value={form.client_name} onChange={e => setForm({ ...form, client_name: e.target.value })} fullWidth placeholder="Client/customer" /></Grid><Grid item xs={12} sm={6}><TextField select label="Category" value={form.category_id} onChange={e => setForm({ ...form, category_id: e.target.value })} fullWidth helperText={`${categories.length} categories`}><MenuItem value="">-- None --</MenuItem>{categories.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}</TextField></Grid><Grid item xs={12} sm={4}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="not_started">Not Started</MenuItem><MenuItem value="in_progress">In Progress</MenuItem><MenuItem value="on_hold">On Hold</MenuItem><MenuItem value="completed">Completed</MenuItem><MenuItem value="cancelled">Cancelled</MenuItem></TextField></Grid><Grid item xs={12} sm={4}><TextField label="Budget" type="number" value={form.budget} onChange={e => setForm({ ...form, budget: e.target.value })} fullWidth InputProps={{ startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment> }} /></Grid><Grid item xs={12} sm={4}><TextField select label="Currency" value={form.currency} onChange={e => setForm({ ...form, currency: e.target.value })} fullWidth><MenuItem value="USD">USD</MenuItem><MenuItem value="UGX">UGX</MenuItem><MenuItem value="EUR">EUR</MenuItem></TextField></Grid><Grid item xs={12} sm={6}><TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={12} sm={6}><TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={12}><TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={3} placeholder="Scope, objectives..." /></Grid></Grid><Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}><Button variant="outlined" onClick={() => navigate("/pmo/projects")}>Cancel</Button><Button type="submit" variant="contained" disabled={saving}>{saving ? "Creating..." : "Create Project"}</Button></Box></Box></CardContent></Card>
    </Box>
  );
}
