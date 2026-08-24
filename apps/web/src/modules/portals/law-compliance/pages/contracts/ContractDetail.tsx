import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import { Box, Card, CardContent, Chip, CircularProgress, Grid, Typography, Button, Breadcrumbs, Link, Alert } from "@mui/material";
import { ArrowBack } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface ContractRecord {
  id: string;
  contract_no: string;
  title: string;
  party_name: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
  value: number | null;
  currency: string;
  created_at: string;
  updated_at: string;
  law_contract_types?: { name: string } | null;
}

export default function ContractDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [record, setRecord] = useState<ContractRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);

  useEffect(() => {
    if (!id) return;
    const fetchOne = async () => {
      setLoading(true);
      const { data, error } = await supabase.from("law_contracts").select("*, law_contract_types(name)").eq("id", id).single();
      if (error || !data) {
        setNotFound(true);
      } else {
        const normalized = {
          ...data,
          law_contract_types: Array.isArray(data.law_contract_types) ? data.law_contract_types[0] ?? null : data.law_contract_types ?? null,
        };
        setRecord(normalized as ContractRecord);
      }
      setLoading(false);
    };
    fetchOne();
  }, [id]);

  const getStatusColor = (s: string) => {
    if (s === 'active') return 'success';
    if (s === 'expired' || s === 'terminated') return 'error';
    if (s === 'pending_approval') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (notFound || !record) {
    return (
      <Box sx={{ p: 3, maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>Contract not found.</Alert>
        <Button startIcon={<ArrowBack />} onClick={() => navigate("/law-compliance/contracts")}>Back to Contracts</Button>
      </Box>
    );
  }

  const msToEnd = record.end_date ? new Date(record.end_date).getTime() - Date.now() : null;
  const daysToEnd = msToEnd != null ? Math.ceil(msToEnd / (24 * 60 * 60 * 1000)) : null;
  const isExpiringSoon = daysToEnd != null && daysToEnd > 0 && daysToEnd <= 30; // matches ContractsList + ExpiryReport window
  const isPastEnd = daysToEnd != null && daysToEnd <= 0;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/law-compliance/contracts" underline="hover" color="inherit">Contracts</Link>
        <Typography color="text.primary">{record.contract_no}</Typography>
      </Breadcrumbs>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3, flexWrap: "wrap", gap: 1 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{record.title}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{record.contract_no}</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          {isExpiringSoon && <Chip label="Expiring soon" color="warning" />}
          {isPastEnd && record.status !== "terminated" && <Chip label="Past end date" color="error" variant="outlined" />}
          <Chip label={record.status} color={getStatusColor(record.status) as any} sx={{ textTransform: "capitalize" }} />
        </Box>
      </Box>

      <Grid container spacing={2}>
        <Grid item xs={12} md={7}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Contract Info</Typography>
            <Grid container spacing={2}>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Party</Typography><Typography>{record.party_name}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Type</Typography><Typography>{record.law_contract_types?.name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Start Date</Typography><Typography>{record.start_date ? new Date(record.start_date).toLocaleDateString() : "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">End Date</Typography><Typography>{record.end_date ? new Date(record.end_date).toLocaleDateString() : "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Created</Typography><Typography>{new Date(record.created_at).toLocaleDateString()}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Last Updated</Typography><Typography>{new Date(record.updated_at).toLocaleDateString()}</Typography></Grid>
            </Grid>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={5}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Contract Value</Typography>
            <Typography variant="h5" fontWeight={700}>{record.value ? `${record.currency} ${Number(record.value).toLocaleString()}` : "-"}</Typography>
            {daysToEnd != null && (
              <Typography variant="body2" color={isPastEnd ? "error.main" : isExpiringSoon ? "warning.main" : "text.secondary"} sx={{ mt: 2 }}>
                {isPastEnd ? `Ended ${Math.abs(daysToEnd)} day${Math.abs(daysToEnd) === 1 ? "" : "s"} ago` : `${daysToEnd} day${daysToEnd === 1 ? "" : "s"} remaining`}
              </Typography>
            )}
          </CardContent></Card>
        </Grid>
      </Grid>
    </Box>
  );
}
