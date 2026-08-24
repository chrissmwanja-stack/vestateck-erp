import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import { Box, Card, CardContent, Chip, CircularProgress, Grid, Typography, Button, Breadcrumbs, Link, Alert } from "@mui/material";
import { ArrowBack, OpenInNew } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface TenderRecord {
  id: string;
  tender_no: string | null;
  title: string;
  status: string;
  submission_deadline: string | null;
  estimated_value: number | null;
  currency: string;
  portal_url: string | null;
  description: string | null;
  created_at: string;
  updated_at: string;
  bd_clients?: { name: string } | null;
  bd_tender_types?: { name: string } | null;
}

export default function TenderDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [record, setRecord] = useState<TenderRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);

  useEffect(() => {
    if (!id) return;
    const fetchOne = async () => {
      setLoading(true);
      const { data, error } = await supabase.from("bd_tenders").select("*, bd_clients(name), bd_tender_types(name)").eq("id", id).single();
      if (error || !data) {
        setNotFound(true);
      } else {
        const normalized = {
          ...data,
          bd_clients: Array.isArray(data.bd_clients) ? data.bd_clients[0] ?? null : data.bd_clients ?? null,
          bd_tender_types: Array.isArray(data.bd_tender_types) ? data.bd_tender_types[0] ?? null : data.bd_tender_types ?? null,
        };
        setRecord(normalized as TenderRecord);
      }
      setLoading(false);
    };
    fetchOne();
  }, [id]);

  const getStatusColor = (s: string) => {
    if (s === 'awarded') return 'success';
    if (s === 'lost' || s === 'cancelled') return 'error';
    if (s === 'submitted' || s === 'under_evaluation') return 'primary';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (notFound || !record) {
    return (
      <Box sx={{ p: 3, maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>Tender not found.</Alert>
        <Button startIcon={<ArrowBack />} onClick={() => navigate("/business-development/tenders")}>Back to Tenders</Button>
      </Box>
    );
  }

  const msToDeadline = record.submission_deadline ? new Date(record.submission_deadline).getTime() - Date.now() : null;
  const daysToDeadline = msToDeadline != null ? Math.ceil(msToDeadline / (24 * 60 * 60 * 1000)) : null;
  const isNearDeadline = daysToDeadline != null && daysToDeadline > 0 && daysToDeadline <= 3;
  const isPastDeadline = daysToDeadline != null && daysToDeadline <= 0;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/business-development/tenders" underline="hover" color="inherit">Tenders</Link>
        <Typography color="text.primary">{record.tender_no || record.title}</Typography>
      </Breadcrumbs>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3, flexWrap: "wrap", gap: 1 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{record.title}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{record.tender_no || "-"}</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          {isNearDeadline && <Chip label="Deadline near" color="warning" />}
          {isPastDeadline && <Chip label="Deadline passed" color="error" variant="outlined" />}
          <Chip label={record.status} color={getStatusColor(record.status) as any} sx={{ textTransform: "capitalize" }} />
        </Box>
      </Box>

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} md={7}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Tender Info</Typography>
            <Grid container spacing={2}>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Client</Typography><Typography>{record.bd_clients?.name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Type</Typography><Typography>{record.bd_tender_types?.name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Submission Deadline</Typography><Typography>{record.submission_deadline ? new Date(record.submission_deadline).toLocaleString() : "-"}</Typography></Grid>
              <Grid item xs={6}>
                <Typography variant="caption" color="text.secondary">Tender Portal</Typography>
                {record.portal_url ? (
                  <Link href={record.portal_url} target="_blank" rel="noopener noreferrer" underline="hover" sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
                    Open portal <OpenInNew fontSize="inherit" />
                  </Link>
                ) : <Typography>-</Typography>}
              </Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Created</Typography><Typography>{new Date(record.created_at).toLocaleDateString()}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Last Updated</Typography><Typography>{new Date(record.updated_at).toLocaleDateString()}</Typography></Grid>
            </Grid>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={5}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Estimated Value</Typography>
            <Typography variant="h5" fontWeight={700}>{record.estimated_value ? `${record.currency} ${Number(record.estimated_value).toLocaleString()}` : "-"}</Typography>
            {daysToDeadline != null && (
              <Typography variant="body2" color={isPastDeadline ? "error.main" : isNearDeadline ? "warning.main" : "text.secondary"} sx={{ mt: 2 }}>
                {isPastDeadline ? `Deadline passed ${Math.abs(daysToDeadline)} day${Math.abs(daysToDeadline) === 1 ? "" : "s"} ago` : `${daysToDeadline} day${daysToDeadline === 1 ? "" : "s"} to deadline`}
              </Typography>
            )}
          </CardContent></Card>
        </Grid>
      </Grid>

      <Card><CardContent>
        <Typography variant="subtitle2" color="text.secondary" gutterBottom>Description</Typography>
        <Typography variant="body2" sx={{ whiteSpace: "pre-wrap" }}>{record.description || "-"}</Typography>
      </CardContent></Card>
    </Box>
  );
}
