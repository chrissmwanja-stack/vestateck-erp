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
} from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface LeadSource {
  id: string;
  name: string;
  is_active: boolean;
}

type LeadStatus = 'new' | 'contacted' | 'qualified' | 'unqualified' | 'converted' | 'lost';

export default function NewLead() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [sources, setSources] = useState<LeadSource[]>([]);
  const [loadingSources, setLoadingSources] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const [form, setForm] = useState({
    company_name: "",
    contact_name: "",
    email: "",
    phone: "",
    source_id: "",
    status: "new" as LeadStatus,
    estimated_value: "",
    currency: "USD",
    notes: "",
  });

  useEffect(() => {
    const fetchSources = async () => {
      setLoadingSources(true);
      const { data, error } = await supabase
        .from("bd_lead_sources")
        .select("id, name, is_active")
        .eq("is_active", true)
        .order("name");
      
      if (error) {
        setError(`Failed to load lead sources: ${error.message}. Run migration and create sources in Admin -> Lead Sources.`);
      } else {
        setSources(data as LeadSource[]);
        if (data && data.length > 0 && !form.source_id) {
          setForm(f => ({ ...f, source_id: data[0].id }));
        }
      }
      setLoadingSources(false);
    };
    fetchSources();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSuccess(null);

    if (!form.company_name.trim() || !form.contact_name.trim() || !form.source_id) {
      setError("Company name, Contact name, and Source are required.");
      return;
    }

    setSaving(true);

    // Get tenant_id from first source or session - adjust to your actual tenant logic
    // Your MaterialLookupsAdmin fetches appUser to get tenant_id, do same here if needed
    const { data: existing } = await supabase.from("bd_lead_sources").select("tenant_id").limit(1).single();
    const tenant_id = existing?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;

    const payload: any = {
      company_name: form.company_name.trim(),
      contact_name: form.contact_name.trim(),
      email: form.email.trim() || null,
      phone: form.phone.trim() || null,
      source_id: form.source_id,
      status: form.status,
      estimated_value: form.estimated_value ? parseFloat(form.estimated_value) : null,
      currency: form.currency,
      notes: form.notes.trim() || null,
      created_by: session?.user?.id,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    const { data, error } = await supabase.from("bd_leads").insert(payload).select("lead_no").single();

    setSaving(false);

    if (error) {
      setError(`Failed to create lead: ${error.message}`);
    } else {
      setSuccess(`Lead ${data?.lead_no || ""} created successfully! BD-L-... auto-generated.`);
      // Reset form but keep source
      setForm({
        company_name: "",
        contact_name: "",
        email: "",
        phone: "",
        source_id: form.source_id,
        status: "new",
        estimated_value: "",
        currency: "USD",
        notes: "",
      });
      setTimeout(() => navigate("/business-development/leads"), 1500);
    }
  };

  if (loadingSources) {
    return (
      <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>New Lead</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Create a new business lead. Source dropdown is backed by Admin → Lead Sources (the table you just populated). Lead No auto-generates BD-L-2026-0001 via trigger.
      </Typography>

      {sources.length === 0 && (
        <Alert severity="warning" sx={{ mb: 3 }}>
          No active Lead Sources found. Go to <b>Business Development → Admin → Lead Sources</b> and create at least one (e.g. Referral, Website, Tender Portal) before creating a lead.
        </Alert>
      )}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {success && <Alert severity="success" sx={{ mb: 2 }}>{success}</Alert>}

      <Card>
        <CardContent>
          <Box component="form" onSubmit={handleSubmit} sx={{ display: "flex", flexDirection: "column", gap: 2.5 }}>
            <Grid container spacing={2}>
              <Grid item xs={12} sm={6}>
                <TextField
                  label="Company Name *"
                  value={form.company_name}
                  onChange={(e) => setForm({ ...form, company_name: e.target.value })}
                  fullWidth
                  required
                  placeholder="e.g. Acme Corporation"
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  label="Contact Name *"
                  value={form.contact_name}
                  onChange={(e) => setForm({ ...form, contact_name: e.target.value })}
                  fullWidth
                  required
                  placeholder="e.g. John Doe"
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  label="Email"
                  type="email"
                  value={form.email}
                  onChange={(e) => setForm({ ...form, email: e.target.value })}
                  fullWidth
                  placeholder="john@acme.com"
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  label="Phone"
                  value={form.phone}
                  onChange={(e) => setForm({ ...form, phone: e.target.value })}
                  fullWidth
                  placeholder="+256 ..."
                />
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  select
                  label="Source *"
                  value={form.source_id}
                  onChange={(e) => setForm({ ...form, source_id: e.target.value })}
                  fullWidth
                  required
                  helperText={`${sources.length} active sources from bd_lead_sources`}
                >
                  {sources.map((s) => (
                    <MenuItem key={s.id} value={s.id}>{s.name}</MenuItem>
                  ))}
                </TextField>
              </Grid>
              <Grid item xs={12} sm={3}>
                <TextField
                  select
                  label="Status"
                  value={form.status}
                  onChange={(e) => setForm({ ...form, status: e.target.value as LeadStatus })}
                  fullWidth
                >
                  <MenuItem value="new">New</MenuItem>
                  <MenuItem value="contacted">Contacted</MenuItem>
                  <MenuItem value="qualified">Qualified</MenuItem>
                  <MenuItem value="unqualified">Unqualified</MenuItem>
                  <MenuItem value="converted">Converted</MenuItem>
                  <MenuItem value="lost">Lost</MenuItem>
                </TextField>
              </Grid>
              <Grid item xs={12} sm={3}>
                <TextField
                  select
                  label="Currency"
                  value={form.currency}
                  onChange={(e) => setForm({ ...form, currency: e.target.value })}
                  fullWidth
                >
                  <MenuItem value="USD">USD</MenuItem>
                  <MenuItem value="UGX">UGX</MenuItem>
                  <MenuItem value="EUR">EUR</MenuItem>
                </TextField>
              </Grid>
              <Grid item xs={12} sm={6}>
                <TextField
                  label="Estimated Value"
                  type="number"
                  value={form.estimated_value}
                  onChange={(e) => setForm({ ...form, estimated_value: e.target.value })}
                  fullWidth
                  InputProps={{
                    startAdornment: <InputAdornment position="start">{form.currency}</InputAdornment>,
                  }}
                  placeholder="50000"
                />
              </Grid>
              <Grid item xs={12}>
                <TextField
                  label="Notes"
                  value={form.notes}
                  onChange={(e) => setForm({ ...form, notes: e.target.value })}
                  fullWidth
                  multiline
                  rows={3}
                  placeholder="How was this lead generated? Any context?"
                />
              </Grid>
            </Grid>

            <Box sx={{ display: "flex", gap: 2, justifyContent: "flex-end", mt: 2 }}>
              <Button variant="outlined" onClick={() => navigate("/business-development/leads")}>Cancel</Button>
              <Button type="submit" variant="contained" disabled={saving || sources.length === 0}>
                {saving ? <><CircularProgress size={20} sx={{ mr: 1 }} /> Creating...</> : "Create Lead"}
              </Button>
            </Box>
          </Box>
        </CardContent>
      </Card>

      <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}>
        <Typography variant="caption" fontWeight={600}>This unblocks:</Typography>
        <Typography variant="caption" component="div" color="text.secondary">
          <ul style={{ margin: "4px 0", paddingLeft: "18px" }}>
            <li>Lead No auto-generates via trigger `generate_bd_lead_no()` → BD-L-YYYY-0001</li>
            <li>Source dropdown now has values because you built Lead Sources Admin (same fix as Material Classification)</li>
            <li>Next: Leads list page that reads from bd_leads with filters</li>
            <li>Then: New Opportunity form that links to Client + Lead</li>
          </ul>
        </Typography>
      </Box>
    </Box>
  );
}
