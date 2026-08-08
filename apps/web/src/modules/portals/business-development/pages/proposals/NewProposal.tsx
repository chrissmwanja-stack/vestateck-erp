import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, TextField, Typography, MenuItem, Grid, Alert, InputAdornment, CircularProgress } from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Client { id: string; name: string; }
interface Opportunity { id: string; title: string; opportunity_no: string; }
interface ProposalType { id: string; name: string; }
interface ProposalTemplate { id: string; name: string; content: string | null; }

// Fills recognized {{token}} placeholders from the current form state.
// Tokens with no known source (e.g. {{scope}}) are left as-is so the
// author can fill them in manually.
const fillPlaceholders = (content: string, values: Record<string, string>) => {
  return content.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (match, key) => {
    return key in values && values[key] ? values[key] : match;
  });
};

export default function NewProposal() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [clients, setClients] = useState<Client[]>([]);
  const [opportunities, setOpportunities] = useState<Opportunity[]>([]);
  const [types, setTypes] = useState<ProposalType[]>([]);
  const [templates, setTemplates] = useState<ProposalTemplate[]>([]);
  const [templateId, setTemplateId] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const [form, setForm] = useState({
    title: "",
    client_id: "",
    opportunity_id: "",
    type_id: "",
    total_value: "",
    currency: "UGX",
    valid_until: "",
    content: "",
  });

  useEffect(() => {
    const fetchLookups = async () => {
      setLoading(true);
      const [clientsRes, oppsRes, typesRes, templatesRes] = await Promise.all([
        supabase.from("bd_clients").select("id, name").eq("is_active", true).order("name"),
        supabase.from("bd_opportunities").select("id, title, opportunity_no").order("created_at", { ascending: false }).limit(100),
        supabase.from("bd_proposal_types").select("id, name").eq("is_active", true).order("name"),
        supabase.from("bd_proposal_templates").select("id, name, content").eq("is_active", true).order("name"),
      ]);
      if (clientsRes.data) setClients(clientsRes.data as Client[]);
      if (oppsRes.data) setOpportunities(oppsRes.data as Opportunity[]);
      if (typesRes.data) setTypes(typesRes.data as ProposalType[]);
      if (templatesRes.data) setTemplates(templatesRes.data as ProposalTemplate[]);
      setLoading(false);
    };
    fetchLookups();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    if (!form.title.trim() || !form.client_id || !form.total_value) {
      setError("Title, Client, and Total Value are required.");
      return;
    }
    setSaving(true);
    const { data: tenantData } = await supabase.from("bd_clients").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      title: form.title.trim(),
      client_id: form.client_id,
      opportunity_id: form.opportunity_id || null,
      type_id: form.type_id || null,
      total_value: parseFloat(form.total_value),
      currency: form.currency,
      valid_until: form.valid_until || null,
      content: form.content.trim() || null,
      created_by: session?.user?.id,
      status: "draft",
      version: 1,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { data, error } = await supabase.from("bd_proposals").insert(payload).select("proposal_no").single();
    setSaving(false);
    if (error) setError(`Failed: ${error.message}`);
    else {
      setSuccess(`Proposal ${data?.proposal_no || ""} created as Draft!`);
      setTimeout(() => navigate("/business-development/proposals"), 1500);
    }
  };

  const handleTemplateChange = (id: string) => {
    setTemplateId(id);
    const template = templates.find(t => t.id === id);
    if (!template) return;
    if (form.content.trim() && !confirm("Replace the current content with this template? Your edits will be lost.")) return;
    setForm({ ...form, content: template.content || "" });
  };

  const handleFillPlaceholders = () => {
    if (!form.content) return;
    const client = clients.find(c => c.id === form.client_id);
    const filled = fillPlaceholders(form.content, {
      client_name: client?.name || "",
      project_title: form.title,
      title: form.title,
      total_value: form.total_value,
      currency: form.currency,
      valid_until: form.valid_until,
    });
    setForm({ ...form, content: filled });
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 950 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Proposal</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Create proposal linked to Opportunity and Client. Proposal No auto BD-P-2026-0001. Status starts Draft → In Review → Pending Approval → Approved → Sent → Accepted/Rejected.
      </Typography>

      {clients.length === 0 && <Alert severity="warning" sx={{ mb: 3 }}>No Clients found. Create client first in Client Management → Clients.</Alert>}
      {types.length === 0 && <Alert severity="warning" sx={{ mb: 3 }}>No Proposal Types found. Go to Admin → Proposal Types and create Technical, Financial, Combined.</Alert>}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {success && <Alert severity="success" sx={{ mb: 2 }}>{success}</Alert>}

      <Card>
        <CardContent>
          <Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}>
            <Grid container spacing={2}>
              <Grid item xs={12}>
                <TextField label="Proposal Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required placeholder="e.g. Acme Corp - Supply and Installation Proposal" />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Client *" value={form.client_id} onChange={e => setForm({ ...form, client_id: e.target.value })} fullWidth required helperText={`${clients.length} clients`}>
                  {clients.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField select label="Link to Opportunity (optional)" value={form.opportunity_id} onChange={e => setForm({ ...form, opportunity_id: e.target.value })} fullWidth helperText="Links proposal to pipeline">
                  <MenuItem value="">-- No link --</MenuItem>
                  {opportunities.map(o => <MenuItem key={o.id} value={o.id}>{o.opportunity_no} - {o.title}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={4}>
                <TextField select label="Proposal Type" value={form.type_id} onChange={e => setForm({ ...form, type_id: e.target.value })} fullWidth helperText={`${types.length} types`}>
                  <MenuItem value="">-- None --</MenuItem>
                  {types.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={4}>
                <TextField label="Total Value *" type="number" value={form.total_value} onChange={e => setForm({ ...form, total_value: e.target.value })} fullWidth required InputProps={{ startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment> }} />
              </Grid>
              <Grid item xs={12} sm={4}>
                <TextField select label="Currency" value={form.currency} onChange={e => setForm({ ...form, currency: e.target.value })} fullWidth>
                  <MenuItem value="USD">USD</MenuItem>
                  <MenuItem value="UGX">UGX</MenuItem>
                  <MenuItem value="EUR">EUR</MenuItem>
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField label="Valid Until" type="date" value={form.valid_until} onChange={e => setForm({ ...form, valid_until: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} helperText="Proposal expiry date" />
              </Grid>
              <Grid item xs={12} sm={8}>
                <TextField select label="Start from Template" value={templateId} onChange={e => handleTemplateChange(e.target.value)} fullWidth helperText={templates.length === 0 ? "No templates yet — create one in Proposals → Templates" : `${templates.length} templates`}>
                  <MenuItem value="">-- Blank --</MenuItem>
                  {templates.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={4} sx={{ display: "flex", alignItems: "center" }}>
                <Button variant="outlined" onClick={handleFillPlaceholders} disabled={!form.content} fullWidth>
                  Fill Placeholders
                </Button>
              </Grid>
              <Grid item xs={12}>
                <TextField label="Proposal Content / Scope" value={form.content} onChange={e => setForm({ ...form, content: e.target.value })} fullWidth multiline rows={8} placeholder="Scope of work, deliverables, terms, etc. Can use markdown or later rich editor." helperText="Pick a template above to start from {{placeholder}} content, then use Fill Placeholders to substitute client, title, value, currency and valid-until where recognized." />
              </Grid>
            </Grid>
            <Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}>
              <Button variant="outlined" onClick={() => navigate("/business-development/proposals")}>Cancel</Button>
              <Button type="submit" variant="contained" disabled={saving || clients.length === 0}>{saving ? "Creating..." : "Create Proposal as Draft"}</Button>
            </Box>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}