import { useEffect, useState } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  TextField,
  Typography,
  MenuItem,
  Grid,
  Alert,
  InputAdornment,
  CircularProgress,
  Chip,
} from "@mui/material";
import { useNavigate, useSearchParams } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Client {
  id: string;
  name: string;
}
interface Lead {
  id: string;
  company_name: string;
  lead_no: string;
}
interface Stage {
  id: string;
  stage: string;
  label: string;
  probability_default: number;
  color: string;
  order_index: number;
  is_active: boolean;
}

export default function NewOpportunity() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const preselectedLeadId = searchParams.get("lead_id");

  const [clients, setClients] = useState<Client[]>([]);
  const [leads, setLeads] = useState<Lead[]>([]);
  const [stages, setStages] = useState<Stage[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const [form, setForm] = useState({
    title: "",
    client_id: "",
    lead_id: preselectedLeadId || "",
    stage: "identification",
    probability: 10,
    estimated_value: "",
    currency: "USD",
    expected_close_date: "",
    description: "",
  });

  useEffect(() => {
    const fetchLookups = async () => {
      setLoading(true);
      const [clientsRes, leadsRes, stagesRes] = await Promise.all([
        supabase.from("bd_clients").select("id, name").eq("is_active", true).order("name"),
        supabase.from("bd_leads").select("id, company_name, lead_no").order("created_at", { ascending: false }).limit(100),
        supabase.from("bd_opportunity_stages").select("*").eq("is_active", true).order("order_index"),
      ]);

      if (clientsRes.data) setClients(clientsRes.data as Client[]);
      if (leadsRes.data) setLeads(leadsRes.data as Lead[]);
      if (stagesRes.data) {
        setStages(stagesRes.data as Stage[]);
        if (stagesRes.data.length > 0 && !form.stage) {
          const first = stagesRes.data[0] as Stage;
          setForm(f => ({ ...f, stage: first.stage, probability: first.probability_default }));
        }
      }
      setLoading(false);
    };
    fetchLookups();
  }, []);

  const handleStageChange = (stageValue: string) => {
    const stage = stages.find(s => s.stage === stageValue);
    setForm(f => ({
      ...f,
      stage: stageValue,
      probability: stage ? stage.probability_default : f.probability,
    }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSuccess(null);

    if (!form.title.trim() || !form.client_id || !form.estimated_value) {
      setError("Title, Client, and Estimated Value are required.");
      return;
    }

    setSaving(true);
    const { data: tenantData } = await supabase.from("bd_clients").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      title: form.title.trim(),
      client_id: form.client_id,
      lead_id: form.lead_id || null,
      stage: form.stage,
      probability: form.probability,
      estimated_value: parseFloat(form.estimated_value),
      currency: form.currency,
      expected_close_date: form.expected_close_date || null,
      description: form.description.trim() || null,
      created_by: session?.user?.id,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { data, error } = await supabase.from("bd_opportunities").insert(payload).select("opportunity_no").single();
    setSaving(false);

    if (error) setError(`Failed: ${error.message}`);
    else {
      setSuccess(`Opportunity ${data?.opportunity_no || ""} created! Weighted value = ${form.currency} ${(parseFloat(form.estimated_value) * form.probability / 100).toLocaleString()}`);
      setTimeout(() => navigate("/business-development/opportunities"), 1500);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 950 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Opportunity</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Convert a lead or create direct opportunity. Stage drives Pipeline Board column and weighted forecast (value × probability). No client? Create first in Clients list.
      </Typography>

      {clients.length === 0 && (
        <Alert severity="warning" sx={{ mb: 3 }}>
          No active Clients found. Go to <b>Business Development → Client Management → Clients</b> and create at least one client before creating opportunity.
        </Alert>
      )}
      {stages.length === 0 && (
        <Alert severity="warning" sx={{ mb: 3 }}>
          No active Opportunity Stages found. Go to <b>Admin → Opportunity Stages</b> and Seed Default 6 Stages.
        </Alert>
      )}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {success && <Alert severity="success" sx={{ mb: 2 }}>{success}</Alert>}

      <Card>
        <CardContent>
          <Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}>
            <Grid container spacing={2}>
              <Grid item xs={12}>
                <TextField label="Opportunity Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required placeholder="e.g. Acme Corp - 100 Units Supply" />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Client *" value={form.client_id} onChange={e => setForm({ ...form, client_id: e.target.value })} fullWidth required helperText={`${clients.length} clients`}>
                  {clients.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Link to Lead (optional)" value={form.lead_id} onChange={e => setForm({ ...form, lead_id: e.target.value })} fullWidth helperText="Preselected if you clicked Convert">
                  <MenuItem value="">-- No lead link --</MenuItem>
                  {leads.map(l => <MenuItem key={l.id} value={l.id}>{l.lead_no} - {l.company_name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Stage *" value={form.stage} onChange={e => handleStageChange(e.target.value)} fullWidth>
                  {stages.map(s => (
                    <MenuItem key={s.id} value={s.stage}>
                      <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                        <Box sx={{ width: 12, height: 12, borderRadius: "50%", bgcolor: s.color }} />
                        {s.label} ({s.probability_default}%)
                      </Box>
                    </MenuItem>
                  ))}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={3}>
                <TextField label="Probability %" type="number" value={form.probability} onChange={e => setForm({ ...form, probability: parseInt(e.target.value) || 0 })} fullWidth InputProps={{ inputProps: { min: 0, max: 100 } }} helperText="Auto from stage, editable" />
              </Grid>
              <Grid item xs={12} sm={3}>
                <TextField select label="Currency" value={form.currency} onChange={e => setForm({ ...form, currency: e.target.value })} fullWidth>
                  <MenuItem value="USD">USD</MenuItem>
                  <MenuItem value="UGX">UGX</MenuItem>
                  <MenuItem value="EUR">EUR</MenuItem>
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField label="Estimated Value *" type="number" value={form.estimated_value} onChange={e => setForm({ ...form, estimated_value: e.target.value })} fullWidth required InputProps={{ startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment> }} />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField label="Expected Close Date" type="date" value={form.expected_close_date} onChange={e => setForm({ ...form, expected_close_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
              </Grid>
              <Grid item xs={12}>
                <Box sx={{ p: 1.5, bgcolor: "grey.50", borderRadius: 1, display: "flex", gap: 1, alignItems: "center" }}>
                  <Typography variant="body2">Weighted Forecast:</Typography>
                  <Chip label={`${form.currency} ${form.estimated_value ? (parseFloat(form.estimated_value) * form.probability / 100).toLocaleString() : "0"}`} color="primary" size="small" />
                  <Typography variant="caption" color="text.secondary">= {form.estimated_value || 0} × {form.probability}% ({stages.find(s => s.stage === form.stage)?.label || form.stage})</Typography>
                </Box>
              </Grid>
              <Grid item xs={12}>
                <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={3} placeholder="Scope, requirements, competitor info..." />
              </Grid>
            </Grid>
            <Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}>
              <Button variant="outlined" onClick={() => navigate("/business-development/opportunities")}>Cancel</Button>
              <Button type="submit" variant="contained" disabled={saving || clients.length === 0}>{saving ? "Creating..." : "Create Opportunity"}</Button>
            </Box>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}
