import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import { Box, Card, CardContent, Chip, CircularProgress, Grid, Typography, Table, TableBody, TableCell, TableHead, TableRow, Button, Breadcrumbs, Link, Alert } from "@mui/material";
import { ArrowBack } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface LeadRecord {
  id: string;
  lead_no: string;
  company_name: string;
  contact_name: string;
  email: string | null;
  phone: string | null;
  status: string;
  estimated_value: number | null;
  currency: string;
  notes: string | null;
  created_at: string;
  updated_at: string;
  bd_lead_sources?: { name: string } | null;
}

interface Opportunity {
  id: string;
  opportunity_no: string | null;
  title: string;
  stage: string;
  probability: number | null;
  estimated_value: number | null;
  currency: string;
  expected_close_date: string | null;
}

export default function LeadDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [lead, setLead] = useState<LeadRecord | null>(null);
  const [opportunities, setOpportunities] = useState<Opportunity[]>([]);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);

  useEffect(() => {
    if (!id) return;
    const fetchAll = async () => {
      setLoading(true);
      const [leadRes, oppsRes] = await Promise.all([
        supabase.from("bd_leads").select("*, bd_lead_sources(name)").eq("id", id).single(),
        supabase.from("bd_opportunities").select("id, opportunity_no, title, stage, probability, estimated_value, currency, expected_close_date").eq("lead_id", id).order("created_at", { ascending: false }),
      ]);

      if (leadRes.error || !leadRes.data) {
        setNotFound(true);
      } else {
        const normalized = {
          ...leadRes.data,
          bd_lead_sources: Array.isArray(leadRes.data.bd_lead_sources) ? leadRes.data.bd_lead_sources[0] ?? null : leadRes.data.bd_lead_sources ?? null,
        };
        setLead(normalized as LeadRecord);
      }
      if (oppsRes.data) setOpportunities(oppsRes.data as Opportunity[]);
      setLoading(false);
    };
    fetchAll();
  }, [id]);

  const getStatusColor = (status: string) => {
    switch (status) {
      case "new": return "default";
      case "contacted": return "info";
      case "qualified": return "success";
      case "unqualified": return "warning";
      case "converted": return "primary";
      case "lost": return "error";
      default: return "default";
    }
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (notFound || !lead) {
    return (
      <Box sx={{ p: 3, maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>Lead not found.</Alert>
        <Button startIcon={<ArrowBack />} onClick={() => navigate("/business-development/leads")}>Back to Leads</Button>
      </Box>
    );
  }

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/business-development/leads" underline="hover" color="inherit">Leads</Link>
        <Typography color="text.primary">{lead.company_name}</Typography>
      </Breadcrumbs>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{lead.company_name}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{lead.lead_no}</Typography>
        </Box>
        <Chip label={lead.status} color={getStatusColor(lead.status) as any} sx={{ textTransform: "capitalize" }} />
      </Box>

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} md={7}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Lead Info</Typography>
            <Grid container spacing={2}>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Contact</Typography><Typography>{lead.contact_name}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Email</Typography><Typography>{lead.email || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Phone</Typography><Typography>{lead.phone || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Source</Typography><Typography>{lead.bd_lead_sources?.name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Created</Typography><Typography>{new Date(lead.created_at).toLocaleDateString()}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Last Updated</Typography><Typography>{new Date(lead.updated_at).toLocaleDateString()}</Typography></Grid>
              <Grid item xs={12}><Typography variant="caption" color="text.secondary">Notes</Typography><Typography variant="body2">{lead.notes || "-"}</Typography></Grid>
            </Grid>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={5}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Estimated Value</Typography>
            <Typography variant="h5" fontWeight={700}>{lead.estimated_value ? `${lead.currency} ${Number(lead.estimated_value).toLocaleString()}` : "-"}</Typography>
          </CardContent></Card>
        </Grid>
      </Grid>

      <Typography variant="subtitle1" fontWeight={700} sx={{ mb: 1 }}>Opportunities from this Lead ({opportunities.length})</Typography>
      <Card><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Opportunity No</TableCell><TableCell>Title</TableCell><TableCell>Stage</TableCell><TableCell>Probability</TableCell><TableCell>Value</TableCell><TableCell>Expected Close</TableCell></TableRow></TableHead>
        <TableBody>{opportunities.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No opportunities for this lead yet. Convert it from the Leads list.</Typography></TableCell></TableRow> : opportunities.map(o => <TableRow key={o.id} hover><TableCell><Typography fontFamily="monospace" variant="body2">{o.opportunity_no || "-"}</Typography></TableCell><TableCell><Typography fontWeight={600} variant="body2">{o.title}</Typography></TableCell><TableCell><Chip label={o.stage} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{o.probability != null ? `${o.probability}%` : "-"}</TableCell><TableCell>{o.estimated_value ? `${o.currency} ${Number(o.estimated_value).toLocaleString()}` : "-"}</TableCell><TableCell>{o.expected_close_date ? new Date(o.expected_close_date).toLocaleDateString() : "-"}</TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>
    </Box>
  );
}
