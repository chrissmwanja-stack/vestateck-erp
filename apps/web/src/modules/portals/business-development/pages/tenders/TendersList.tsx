import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, IconButton, Tooltip } from "@mui/material";
import { Add, Visibility } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Tender {
  id: string;
  tender_no: string;
  title: string;
  status: string;
  submission_deadline: string | null;
  estimated_value: number | null;
  currency: string;
  created_at: string;
  bd_clients?: { name: string } | null;
  bd_tender_types?: { name: string } | null;
}

export default function TendersList() {
  const navigate = useNavigate();
  const [tenders, setTenders] = useState<Tender[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");

  const fetchTenders = async () => {
    setLoading(true);
    let query = supabase.from("bd_tenders").select("*, bd_clients(name), bd_tender_types(name)").order("submission_deadline", { ascending: true, nullsFirst: false });
    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    const { data } = await query;
    if (data) setTenders(data as Tender[]);
    setLoading(false);
  };

  useEffect(() => { fetchTenders(); }, [statusFilter]);

  const getStatusColor = (s: string) => {
    if (s === 'awarded') return 'success';
    if (s === 'lost' || s === 'cancelled') return 'error';
    if (s === 'submitted' || s === 'under_evaluation') return 'primary';
    return 'default';
  };

  const isNearDeadline = (deadline: string | null) => {
    if (!deadline) return false;
    const diff = new Date(deadline).getTime() - new Date().getTime();
    return diff > 0 && diff < 3 * 24 * 60 * 60 * 1000; // 3 days
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Tenders</Typography>
          <Typography variant="body2" color="text.secondary">{tenders.length} tenders • Tracks deadline, submissions, award status</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/business-development/tenders/new")}>New Tender</Button>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2 }}>
          <TextField select label="Status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} size="small" sx={{ minWidth: 200 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="open">Open</MenuItem>
            <MenuItem value="submitted">Submitted</MenuItem>
            <MenuItem value="under_evaluation">Under Evaluation</MenuItem>
            <MenuItem value="awarded">Awarded</MenuItem>
            <MenuItem value="lost">Lost</MenuItem>
            <MenuItem value="cancelled">Cancelled</MenuItem>
          </TextField>
        </CardContent>
      </Card>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Tender No</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Deadline</TableCell>
                <TableCell>Value</TableCell>
                <TableCell align="right">View</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {tenders.length === 0 ? (
                <TableRow><TableCell colSpan={8} sx={{ textAlign: "center", py: 6 }}><Typography color="text.secondary">No tenders yet. Create first via New Tender.</Typography></TableCell></TableRow>
              ) : (
                tenders.map(t => (
                  <TableRow key={t.id} hover sx={{ bgcolor: isNearDeadline(t.submission_deadline) ? "warning.light" : "inherit" }}>
                    <TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{t.tender_no || "-"}</Typography></TableCell>
                    <TableCell><Typography fontWeight={600} variant="body2">{t.title}</Typography></TableCell>
                    <TableCell>{t.bd_clients?.name || "-"}</TableCell>
                    <TableCell><Chip label={t.bd_tender_types?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell><Chip label={t.status} size="small" color={getStatusColor(t.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>
                      {t.submission_deadline ? (
                        <Box>
                          <Typography variant="body2">{new Date(t.submission_deadline).toLocaleDateString()}</Typography>
                          {isNearDeadline(t.submission_deadline) && <Chip label="Due soon" size="small" color="warning" sx={{ mt: 0.5 }} />}
                        </Box>
                      ) : "-"}
                    </TableCell>
                    <TableCell>{t.estimated_value ? `${t.currency} ${Number(t.estimated_value).toLocaleString()}` : "-"}</TableCell>
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
