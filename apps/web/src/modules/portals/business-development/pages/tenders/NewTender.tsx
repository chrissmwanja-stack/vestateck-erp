import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, TextField, Typography, MenuItem, Grid, Alert, InputAdornment, CircularProgress } from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Client { id: string; name: string; }
interface TenderType { id: string; name: string; }

export default function NewTender() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [clients, setClients] = useState<Client[]>([]);
  const [types, setTypes] = useState<TenderType[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const [form, setForm] = useState({
    title: "",
    tender_no: "",
    client_id: "",
    type_id: "",
    submission_deadline: "",
    estimated_value: "",
    currency: "UGX",
    portal_url: "",
    description: "",
  });

  useEffect(() => {
    const fetchLookups = async () => {
      setLoading(true);
      const [clientsRes, typesRes] = await Promise.all([
        supabase.from("bd_clients").select("id, name").eq("is_active", true).order("name"),
        supabase.from("bd_tender_types").select("id, name").eq("is_active", true).order("name"),
      ]);
      if (clientsRes.data) setClients(clientsRes.data as Client[]);
      if (typesRes.data) setTypes(typesRes.data as TenderType[]);
      setLoading(false);
    };
    fetchLookups();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    if (!form.title.trim()) { setError("Title is required."); return; }
    setSaving(true);
    const { data: tenantData } = await supabase.from("bd_clients").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      title: form.title.trim(),
      tender_no: form.tender_no.trim() || null,
      client_id: form.client_id || null,
      type_id: form.type_id || null,
      submission_deadline: form.submission_deadline ? new Date(form.submission_deadline).toISOString() : null,
      estimated_value: form.estimated_value ? parseFloat(form.estimated_value) : null,
      currency: form.currency,
      portal_url: form.portal_url.trim() || null,
      description: form.description.trim() || null,
      created_by: session?.user?.id,
      status: "open",
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { data, error } = await supabase.from("bd_tenders").insert(payload).select("tender_no").single();
    setSaving(false);
    if (error) setError(`Failed: ${error.message}`);
    else {
      setSuccess(`Tender ${data?.tender_no || form.title} created!`);
      setTimeout(() => navigate("/business-development/tenders"), 1500);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 950 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Tender</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Track external tender notices. Link to client, set deadline, later link to proposal submission.</Typography>

      {clients.length === 0 && <Alert severity="warning" sx={{ mb: 2 }}>No Clients found. Create client first.</Alert>}
      {types.length === 0 && <Alert severity="warning" sx={{ mb: 2 }}>No Tender Types found. Go to Admin → Tender Types and create Public, Private, etc.</Alert>}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {success && <Alert severity="success" sx={{ mb: 2 }}>{success}</Alert>}

      <Card>
        <CardContent>
          <Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}>
            <Grid container spacing={2}>
              <Grid item xs={12} sm={8}>
                <TextField label="Tender Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required placeholder="e.g. Construction of 10 Classrooms" />
              </Grid>
              <Grid item xs={12} sm={4}>
                <TextField label="Tender No / Ref" value={form.tender_no} onChange={e => setForm({ ...form, tender_no: e.target.value })} fullWidth placeholder="External ref, e.g. MOES/2026/001" helperText="Optional, auto if blank" />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Client" value={form.client_id} onChange={e => setForm({ ...form, client_id: e.target.value })} fullWidth helperText={`${clients.length} clients`}>
                  <MenuItem value="">-- None --</MenuItem>
                  {clients.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Tender Type" value={form.type_id} onChange={e => setForm({ ...form, type_id: e.target.value })} fullWidth helperText={`${types.length} types`}>
                  <MenuItem value="">-- None --</MenuItem>
                  {types.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField label="Submission Deadline" type="datetime-local" value={form.submission_deadline} onChange={e => setForm({ ...form, submission_deadline: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
              </Grid>
              <Grid item xs={12} sm={3}>
                <TextField label="Estimated Value" type="number" value={form.estimated_value} onChange={e => setForm({ ...form, estimated_value: e.target.value })} fullWidth InputProps={{ startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment> }} />
              </Grid>
              <Grid item xs={12} sm={3}>
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
                <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={4} placeholder="Scope, eligibility, site visit dates..." />
              </Grid>
            </Grid>
            <Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}>
              <Button variant="outlined" onClick={() => navigate("/business-development/tenders")}>Cancel</Button>
              <Button type="submit" variant="contained" disabled={saving}>{saving ? "Creating..." : "Create Tender"}</Button>
            </Box>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}
