import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, IconButton, Tooltip } from "@mui/material";
import { Add, Visibility } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Proposal {
  id: string;
  proposal_no: string;
  title: string;
  status: string;
  total_value: number;
  currency: string;
  version: number;
  valid_until: string | null;
  created_at: string;
  bd_clients?: { name: string } | null;
  bd_proposal_types?: { name: string } | null;
}

export default function ProposalsList() {
  const navigate = useNavigate();
  const [proposals, setProposals] = useState<Proposal[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");

  const fetchProposals = async () => {
    setLoading(true);
    let query = supabase.from("bd_proposals").select("*, bd_clients(name), bd_proposal_types(name)").order("created_at", { ascending: false });
    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    const { data } = await query;
    if (data) setProposals(data as Proposal[]);
    setLoading(false);
  };

  useEffect(() => { fetchProposals(); }, [statusFilter]);

  const getStatusColor = (s: string) => {
    if (s === 'accepted') return 'success';
    if (s === 'rejected' || s === 'expired') return 'error';
    if (s === 'sent' || s === 'approved') return 'primary';
    if (s === 'pending_approval' || s === 'in_review') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2, flexWrap: "wrap", gap: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Proposals</Typography>
          <Typography variant="body2" color="text.secondary">{proposals.length} proposals • Proposal No auto BD-P-2026-0001</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/business-development/proposals/new")}>New Proposal</Button>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2 }}>
          <TextField select label="Status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} size="small" sx={{ minWidth: 200 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="draft">Draft</MenuItem>
            <MenuItem value="in_review">In Review</MenuItem>
            <MenuItem value="pending_approval">Pending Approval</MenuItem>
            <MenuItem value="approved">Approved</MenuItem>
            <MenuItem value="sent">Sent</MenuItem>
            <MenuItem value="accepted">Accepted</MenuItem>
            <MenuItem value="rejected">Rejected</MenuItem>
            <MenuItem value="expired">Expired</MenuItem>
          </TextField>
        </CardContent>
      </Card>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Proposal No</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Value</TableCell>
                <TableCell>Version</TableCell>
                <TableCell>Valid Until</TableCell>
                <TableCell align="right">View</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {proposals.length === 0 ? (
                <TableRow><TableCell colSpan={9} sx={{ textAlign: "center", py: 6 }}><Typography color="text.secondary">No proposals yet. Create first via New Proposal — needs Client + Opportunity.</Typography></TableCell></TableRow>
              ) : (
                proposals.map(p => (
                  <TableRow key={p.id} hover>
                    <TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{p.proposal_no}</Typography></TableCell>
                    <TableCell><Typography fontWeight={600} variant="body2">{p.title}</Typography></TableCell>
                    <TableCell>{p.bd_clients?.name || "-"}</TableCell>
                    <TableCell><Chip label={p.bd_proposal_types?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell><Chip label={p.status} size="small" color={getStatusColor(p.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>{p.currency} {Number(p.total_value).toLocaleString()}</TableCell>
                    <TableCell>v{p.version}</TableCell>
                    <TableCell>{p.valid_until ? new Date(p.valid_until).toLocaleDateString() : "-"}</TableCell>
                    <TableCell align="right">
                      <Tooltip title="View"><IconButton size="small"><Visibility fontSize="small" /></IconButton></Tooltip>
                    </TableCell>
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
