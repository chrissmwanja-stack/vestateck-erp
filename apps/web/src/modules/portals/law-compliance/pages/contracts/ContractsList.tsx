import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, TextField, MenuItem, IconButton, Tooltip } from "@mui/material";
import { Add, Visibility } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Contract {
  id: string;
  contract_no: string;
  title: string;
  party_name: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
  value: number | null;
  currency: string;
  law_contract_types?: { name: string } | null;
}

export default function ContractsList() {
  const navigate = useNavigate();
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");

  const fetchContracts = async () => {
    setLoading(true);
    let query = supabase.from("law_contracts").select("*, law_contract_types(name)").order("created_at", { ascending: false });
    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    const { data } = await query;
    if (data) setContracts(data as Contract[]);
    setLoading(false);
  };

  useEffect(() => { fetchContracts(); }, [statusFilter]);

  const getStatusColor = (s: string) => {
    if (s === 'active') return 'success';
    if (s === 'expired' || s === 'terminated') return 'error';
    if (s === 'pending_approval') return 'warning';
    return 'default';
  };

  const isExpiringSoon = (endDate: string | null) => {
    if (!endDate) return false;
    const diff = new Date(endDate).getTime() - new Date().getTime();
    return diff > 0 && diff < 30 * 24 * 60 * 60 * 1000; // 30 days
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Contracts</Typography>
          <Typography variant="body2" color="text.secondary">{contracts.length} contracts • Contract No auto LAW-C-2026-0001 • Expiry tracking</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/law-compliance/contracts/new")}>New Contract</Button>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2 }}>
          <TextField select label="Status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} size="small" sx={{ minWidth: 200 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="draft">Draft</MenuItem>
            <MenuItem value="pending_approval">Pending Approval</MenuItem>
            <MenuItem value="active">Active</MenuItem>
            <MenuItem value="expired">Expired</MenuItem>
            <MenuItem value="terminated">Terminated</MenuItem>
          </TextField>
        </CardContent>
      </Card>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Contract No</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Party</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Start</TableCell>
                <TableCell>End</TableCell>
                <TableCell>Value</TableCell>
                <TableCell align="right">View</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {contracts.length === 0 ? (
                <TableRow><TableCell colSpan={9} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No contracts yet. Create first via New Contract — needs Contract Type lookup you built.</Typography></TableCell></TableRow>
              ) : (
                contracts.map(c => (
                  <TableRow key={c.id} hover sx={{ bgcolor: isExpiringSoon(c.end_date) ? "warning.light" : "inherit" }}>
                    <TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{c.contract_no}</Typography></TableCell>
                    <TableCell><Typography fontWeight={600} variant="body2">{c.title}</Typography></TableCell>
                    <TableCell>{c.party_name}</TableCell>
                    <TableCell><Chip label={c.law_contract_types?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell><Chip label={c.status} size="small" color={getStatusColor(c.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>{c.start_date ? new Date(c.start_date).toLocaleDateString() : "-"}</TableCell>
                    <TableCell>
                      {c.end_date ? (
                        <Box>
                          <Typography variant="body2">{new Date(c.end_date).toLocaleDateString()}</Typography>
                          {isExpiringSoon(c.end_date) && <Chip label="Expiring soon" size="small" color="warning" sx={{ mt: 0.5 }} />}
                        </Box>
                      ) : "-"}
                    </TableCell>
                    <TableCell>{c.value ? `${c.currency} ${Number(c.value).toLocaleString()}` : "-"}</TableCell>
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
