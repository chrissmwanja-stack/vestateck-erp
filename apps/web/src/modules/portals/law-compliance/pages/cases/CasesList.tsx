import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, IconButton, Tooltip } from "@mui/material";
import { Add, Visibility } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Case {
  id: string;
  case_no: string;
  title: string;
  status: string;
  lawyer_name: string | null;
  created_at: string;
  law_case_types?: { name: string } | null;
}

export default function CasesList() {
  const navigate = useNavigate();
  const [cases, setCases] = useState<Case[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");

  const fetchCases = async () => {
    setLoading(true);
    let query = supabase.from("law_cases").select("*, law_case_types(name)").order("created_at", { ascending: false });
    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    const { data } = await query;
    if (data) setCases(data as Case[]);
    setLoading(false);
  };

  useEffect(() => { fetchCases(); }, [statusFilter]);

  const getStatusColor = (s: string) => {
    if (s === 'open') return 'primary';
    if (s === 'closed') return 'success';
    if (s === 'on_hold') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Legal Cases</Typography>
          <Typography variant="body2" color="text.secondary">{cases.length} cases • Case No auto LAW-CASE-2026-0001</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/law-compliance/cases/new")}>New Case</Button>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2 }}>
          <TextField select label="Status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} size="small" sx={{ minWidth: 200 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="open">Open</MenuItem>
            <MenuItem value="in_progress">In Progress</MenuItem>
            <MenuItem value="closed">Closed</MenuItem>
            <MenuItem value="on_hold">On Hold</MenuItem>
          </TextField>
        </CardContent>
      </Card>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Case No</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Lawyer</TableCell>
                <TableCell>Created</TableCell>
                <TableCell align="right">View</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {cases.length === 0 ? (
                <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No cases yet. Create first case — needs Case Type lookup.</Typography></TableCell></TableRow>
              ) : (
                cases.map(c => (
                  <TableRow key={c.id} hover>
                    <TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{c.case_no}</Typography></TableCell>
                    <TableCell><Typography fontWeight={600} variant="body2">{c.title}</Typography></TableCell>
                    <TableCell><Chip label={c.law_case_types?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell><Chip label={c.status} size="small" color={getStatusColor(c.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>{c.lawyer_name || "-"}</TableCell>
                    <TableCell>{new Date(c.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right"><Tooltip title="View"><IconButton size="small"><Visibility fontSize="small" /></IconButton></Tooltip></TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
}
