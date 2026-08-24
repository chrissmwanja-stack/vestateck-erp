import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import { Box, Card, CardContent, Chip, CircularProgress, Grid, Typography, Button, Breadcrumbs, Link, Alert } from "@mui/material";
import { ArrowBack } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface ProposalRecord {
  id: string;
  proposal_no: string | null;
  title: string;
  status: string;
  total_value: number;
  currency: string;
  version: number;
  valid_until: string | null;
  content: string | null;
  decided_at: string | null;
  decision_notes: string | null;
  created_at: string;
  updated_at: string;
  bd_clients?: { name: string } | null;
  bd_proposal_types?: { name: string } | null;
  bd_opportunities?: { title: string; opportunity_no: string | null } | null;
}

export default function ProposalDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [record, setRecord] = useState<ProposalRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);

  useEffect(() => {
    if (!id) return;
    const fetchOne = async () => {
      setLoading(true);
      const { data, error } = await supabase.from("bd_proposals").select("*, bd_clients(name), bd_proposal_types(name), bd_opportunities(title, opportunity_no)").eq("id", id).single();
      if (error || !data) {
        setNotFound(true);
      } else {
        const normalized = {
          ...data,
          bd_clients: Array.isArray(data.bd_clients) ? data.bd_clients[0] ?? null : data.bd_clients ?? null,
          bd_proposal_types: Array.isArray(data.bd_proposal_types) ? data.bd_proposal_types[0] ?? null : data.bd_proposal_types ?? null,
          bd_opportunities: Array.isArray(data.bd_opportunities) ? data.bd_opportunities[0] ?? null : data.bd_opportunities ?? null,
        };
        setRecord(normalized as ProposalRecord);
      }
      setLoading(false);
    };
    fetchOne();
  }, [id]);

  const getStatusColor = (s: string) => {
    if (s === 'accepted') return 'success';
    if (s === 'rejected' || s === 'expired') return 'error';
    if (s === 'sent' || s === 'approved') return 'primary';
    if (s === 'pending_approval' || s === 'in_review') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (notFound || !record) {
    return (
      <Box sx={{ p: 3, maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>Proposal not found.</Alert>
        <Button startIcon={<ArrowBack />} onClick={() => navigate("/business-development/proposals")}>Back to Proposals</Button>
      </Box>
    );
  }

  const isValidUntilPast = record.valid_until != null && new Date(record.valid_until).getTime() < Date.now();

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/business-development/proposals" underline="hover" color="inherit">Proposals</Link>
        <Typography color="text.primary">{record.proposal_no || record.title}</Typography>
      </Breadcrumbs>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3, flexWrap: "wrap", gap: 1 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{record.title}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{record.proposal_no || "-"}</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          <Chip label={`Version ${record.version}`} variant="outlined" />
          <Chip label={record.status} color={getStatusColor(record.status) as any} sx={{ textTransform: "capitalize" }} />
        </Box>
      </Box>

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} md={7}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Proposal Info</Typography>
            <Grid container spacing={2}>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Client</Typography><Typography>{record.bd_clients?.name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Type</Typography><Typography>{record.bd_proposal_types?.name || "-"}</Typography></Grid>
              <Grid item xs={6}>
                <Typography variant="caption" color="text.secondary">Opportunity</Typography>
                <Typography>{record.bd_opportunities ? `${record.bd_opportunities.opportunity_no ? record.bd_opportunities.opportunity_no + " — " : ""}${record.bd_opportunities.title}` : "-"}</Typography>
              </Grid>
              <Grid item xs={6}>
                <Typography variant="caption" color="text.secondary">Valid Until</Typography>
                <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                  <Typography>{record.valid_until ? new Date(record.valid_until).toLocaleDateString() : "-"}</Typography>
                  {isValidUntilPast && <Chip label="Expired" size="small" color="error" variant="outlined" />}
                </Box>
              </Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Created</Typography><Typography>{new Date(record.created_at).toLocaleDateString()}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Last Updated</Typography><Typography>{new Date(record.updated_at).toLocaleDateString()}</Typography></Grid>
            </Grid>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={5}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Total Value</Typography>
            <Typography variant="h5" fontWeight={700}>{`${record.currency} ${Number(record.total_value).toLocaleString()}`}</Typography>
          </CardContent></Card>
        </Grid>
      </Grid>

      {record.decided_at && (
        <Alert severity={record.status === "accepted" ? "success" : record.status === "rejected" ? "error" : "info"} sx={{ mb: 3 }}>
          Decision recorded on {new Date(record.decided_at).toLocaleDateString()}.
          {record.decision_notes ? ` ${record.decision_notes}` : ""}
        </Alert>
      )}

      <Card><CardContent>
        <Typography variant="subtitle2" color="text.secondary" gutterBottom>Proposal Content / Scope</Typography>
        <Typography variant="body2" sx={{ whiteSpace: "pre-wrap" }}>{record.content || "-"}</Typography>
      </CardContent></Card>
    </Box>
  );
}
