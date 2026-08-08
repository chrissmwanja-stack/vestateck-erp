import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, TextField, Typography, MenuItem, Grid, Alert, InputAdornment, CircularProgress } from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface ContractType { id: string; name: string; }

export default function NewContract() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [types, setTypes] = useState<ContractType[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const [form, setForm] = useState({
    title: "",
    type_id: "",
    party_name: "",
    status: "draft",
    start_date: "",
    end_date: "",
    value: "",
    currency: "UGX",
  });

  useEffect(() => {
    const fetchTypes = async () => {
      setLoading(true);
      const { data } = await supabase.from("law_contract_types").select("id, name").eq("is_active", true).order("name");
      if (data) setTypes(data as ContractType[]);
      setLoading(false);
    };
    fetchTypes();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    if (!form.title.trim() || !form.party_name.trim()) {
      setError("Title and Party Name are required.");
      return;
    }
    setSaving(true);
    const { data: tenantData } = await supabase.from("law_contract_types").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      title: form.title.trim(),
      type_id: form.type_id || null,
      party_name: form.party_name.trim(),
      status: form.status,
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      value: form.value ? parseFloat(form.value) : null,
      currency: form.currency,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { data, error } = await supabase.from("law_contracts").insert(payload).select("contract_no").single();
    setSaving(false);
    if (error) setError(`Failed: ${error.message}`);
    else {
      setSuccess(`Contract ${data?.contract_no || ""} created as Draft!`);
      setTimeout(() => navigate("/law-compliance/contracts"), 1500);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Contract</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Create contract with type lookup (NDA, Service, Lease). Contract No auto LAW-C-2026-0001. Tracks expiry.</Typography>

      {types.length === 0 && <Alert severity="warning" sx={{ mb: 3 }}>No Contract Types found. Go to Admin → Contract Types and create NDA, Service Agreement, Lease, etc.</Alert>}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {success && <Alert severity="success" sx={{ mb: 2 }}>{success}</Alert>}

      <Card>
        <CardContent>
          <Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}>
            <Grid container spacing={2}>
              <Grid item xs={12}>
                <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required placeholder="e.g. Office Lease Agreement - Kampala" />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField label="Party Name *" value={form.party_name} onChange={e => setForm({ ...form, party_name: e.target.value })} fullWidth required placeholder="e.g. Acme Properties Ltd" />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Contract Type" value={form.type_id} onChange={e => setForm({ ...form, type_id: e.target.value })} fullWidth helperText={`${types.length} active types`}>
                  <MenuItem value="">-- None --</MenuItem>
                  {types.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={4}>
                <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth>
                  <MenuItem value="draft">Draft</MenuItem>
                  <MenuItem value="pending_approval">Pending Approval</MenuItem>
                  <MenuItem value="active">Active</MenuItem>
                  <MenuItem value="expired">Expired</MenuItem>
                  <MenuItem value="terminated">Terminated</MenuItem>
                </TextField>
              </Grid>
              <Grid item xs={12} sm={4}>
                <TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
              </Grid>
              <Grid item xs={12} sm={4}>
                <TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} helperText="For expiry tracking report" />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField label="Value" type="number" value={form.value} onChange={e => setForm({ ...form, value: e.target.value })} fullWidth InputProps={{ startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment> }} />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Currency" value={form.currency} onChange={e => setForm({ ...form, currency: e.target.value })} fullWidth>
                  <MenuItem value="USD">USD</MenuItem>
                  <MenuItem value="UGX">UGX</MenuItem>
                  <MenuItem value="EUR">EUR</MenuItem>
                </TextField>
              </Grid>
            </Grid>
            <Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}>
              <Button variant="outlined" onClick={() => navigate("/law-compliance/contracts")}>Cancel</Button>
              <Button type="submit" variant="contained" disabled={saving}>{saving ? "Creating..." : "Create Contract"}</Button>
            </Box>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}
