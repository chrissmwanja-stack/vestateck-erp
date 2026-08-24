import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, TextField, Typography, MenuItem, Grid, Alert, CircularProgress } from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface CaseType { id: string; name: string; }

export default function NewCase() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [types, setTypes] = useState<CaseType[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const [form, setForm] = useState({
    title: "",
    type_id: "",
    status: "open",
    lawyer_name: "",
    description: "",
  });

  useEffect(() => {
    const fetchTypes = async () => {
      setLoading(true);
      const { data } = await supabase.from("law_case_types").select("id, name").eq("is_active", true).order("name");
      if (data) setTypes(data as CaseType[]);
      setLoading(false);
    };
    fetchTypes();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    if (!form.title.trim()) {
      setError("Title is required.");
      return;
    }
    setSaving(true);
    const { data: tenantData } = await supabase.from("law_case_types").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      title: form.title.trim(),
      type_id: form.type_id || null,
      status: form.status,
      lawyer_name: form.lawyer_name.trim() || null,
      description: form.description.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { data, error } = await supabase.from("law_cases").insert(payload).select("case_no").single();
    setSaving(false);
    if (error) setError(`Failed: ${error.message}`);
    else {
      setSuccess(`Case ${data?.case_no || ""} created!`);
      setTimeout(() => navigate("/law-compliance/cases"), 1500);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Case</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Open a legal case with type lookup. Case No auto LAW-CASE-2026-0001.</Typography>

      {types.length === 0 && <Alert severity="warning" sx={{ mb: 3 }}>No Case Types found. Go to Admin → Case Types and create one first (or leave blank).</Alert>}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {success && <Alert severity="success" sx={{ mb: 2 }}>{success}</Alert>}

      <Card>
        <CardContent>
          <Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}>
            <Grid container spacing={2}>
              <Grid item xs={12}>
                <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required placeholder="e.g. Nakato v. Vestateck Ltd - Land Dispute" />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Case Type" value={form.type_id} onChange={e => setForm({ ...form, type_id: e.target.value })} fullWidth helperText={`${types.length} active types`}>
                  <MenuItem value="">-- None --</MenuItem>
                  {types.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth>
                  <MenuItem value="open">Open</MenuItem>
                  <MenuItem value="in_progress">In Progress</MenuItem>
                  <MenuItem value="on_hold">On Hold</MenuItem>
                  <MenuItem value="closed">Closed</MenuItem>
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField label="Lawyer" value={form.lawyer_name} onChange={e => setForm({ ...form, lawyer_name: e.target.value })} fullWidth placeholder="e.g. Robert Ssentongo" />
              </Grid>
              <Grid item xs={12}>
                <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={4} placeholder="Case background, parties, claim summary..." />
              </Grid>
            </Grid>
            <Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}>
              <Button variant="outlined" onClick={() => navigate("/law-compliance/cases")}>Cancel</Button>
              <Button type="submit" variant="contained" disabled={saving}>{saving ? "Creating..." : "Create Case"}</Button>
            </Box>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}