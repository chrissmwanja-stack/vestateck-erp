import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import { Box, Card, CardContent, Chip, CircularProgress, Grid, Typography, Table, TableBody, TableCell, TableHead, TableRow, Button, Breadcrumbs, Link, Alert } from "@mui/material";
import { ArrowBack } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface CaseRecord {
  id: string;
  case_no: string;
  title: string;
  status: string;
  description: string | null;
  lawyer_name: string | null;
  created_at: string;
  law_case_types?: { name: string } | null;
}

interface Hearing {
  id: string;
  hearing_date: string;
  location: string | null;
  outcome: string | null;
  notes: string | null;
}

export default function CaseDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [record, setRecord] = useState<CaseRecord | null>(null);
  const [hearings, setHearings] = useState<Hearing[]>([]);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);

  useEffect(() => {
    if (!id) return;
    const fetchAll = async () => {
      setLoading(true);
      const [caseRes, hearingsRes] = await Promise.all([
        supabase.from("law_cases").select("*, law_case_types(name)").eq("id", id).single(),
        supabase.from("law_case_hearings").select("id, hearing_date, location, outcome, notes").eq("case_id", id).order("hearing_date", { ascending: false }),
      ]);

      if (caseRes.error || !caseRes.data) {
        setNotFound(true);
      } else {
        const normalized = {
          ...caseRes.data,
          law_case_types: Array.isArray(caseRes.data.law_case_types) ? caseRes.data.law_case_types[0] ?? null : caseRes.data.law_case_types ?? null,
        };
        setRecord(normalized as CaseRecord);
      }
      if (hearingsRes.data) setHearings(hearingsRes.data as Hearing[]);
      setLoading(false);
    };
    fetchAll();
  }, [id]);

  const getStatusColor = (s: string) => {
    if (s === 'open') return 'primary';
    if (s === 'closed') return 'success';
    if (s === 'on_hold') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (notFound || !record) {
    return (
      <Box sx={{ p: 3, maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>Case not found.</Alert>
        <Button startIcon={<ArrowBack />} onClick={() => navigate("/law-compliance/cases")}>Back to Cases</Button>
      </Box>
    );
  }

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/law-compliance/cases" underline="hover" color="inherit">Cases</Link>
        <Typography color="text.primary">{record.case_no}</Typography>
      </Breadcrumbs>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{record.title}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{record.case_no}</Typography>
        </Box>
        <Chip label={record.status} color={getStatusColor(record.status) as any} sx={{ textTransform: "capitalize" }} />
      </Box>

      <Card sx={{ mb: 3 }}><CardContent>
        <Typography variant="subtitle2" color="text.secondary" gutterBottom>Case Info</Typography>
        <Grid container spacing={2}>
          <Grid item xs={6}><Typography variant="caption" color="text.secondary">Type</Typography><Typography>{record.law_case_types?.name || "-"}</Typography></Grid>
          <Grid item xs={6}><Typography variant="caption" color="text.secondary">Lawyer</Typography><Typography>{record.lawyer_name || "-"}</Typography></Grid>
          <Grid item xs={6}><Typography variant="caption" color="text.secondary">Opened</Typography><Typography>{new Date(record.created_at).toLocaleDateString()}</Typography></Grid>
          <Grid item xs={12}><Typography variant="caption" color="text.secondary">Description</Typography><Typography variant="body2">{record.description || "-"}</Typography></Grid>
        </Grid>
      </CardContent></Card>

      <Typography variant="subtitle1" fontWeight={700} sx={{ mb: 1 }}>Hearings ({hearings.length})</Typography>
      <Card><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Location</TableCell><TableCell>Outcome</TableCell><TableCell>Notes</TableCell></TableRow></TableHead>
        <TableBody>{hearings.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No hearings recorded for this case yet.</Typography></TableCell></TableRow> : hearings.map(h => <TableRow key={h.id} hover><TableCell>{new Date(h.hearing_date).toLocaleDateString()}</TableCell><TableCell>{h.location || "-"}</TableCell><TableCell>{h.outcome || "-"}</TableCell><TableCell>{h.notes || "-"}</TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>
    </Box>
  );
}