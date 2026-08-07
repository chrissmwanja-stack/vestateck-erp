import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Contract {
  id: string;
  contract_no: string;
  title: string;
  party_name: string;
  status: string;
  created_at: string;
  law_contract_types?: { name: string } | null;
}

export default function ContractApprovals() {
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchContracts = async () => {
    setLoading(true);
    const { data } = await supabase.from("law_contracts").select("*, law_contract_types(name)").in("status", ["pending_approval", "draft"]).order("created_at", { ascending: true });
    if (data) setContracts(data as Contract[]);
    setLoading(false);
  };

  useEffect(() => { fetchContracts(); }, []);

  const handleDecision = async (id: string, status: 'active' | 'terminated') => {
    if (!confirm(`Mark contract as ${status}?`)) return;
    const { error } = await supabase.from("law_contracts").update({ status }).eq("id", id);
    if (!error) fetchContracts();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Contract Approvals</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Contracts pending approval. Same pattern as Material Request Approval, Proposal Approvals, Leave Approvals.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Contract No</TableCell><TableCell>Title</TableCell><TableCell>Party</TableCell><TableCell>Type</TableCell><TableCell>Status</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{contracts.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No contracts pending approval. Contracts in Draft or Pending Approval appear here.</Typography></TableCell></TableRow> : contracts.map(c => <TableRow key={c.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{c.contract_no}</Typography></TableCell><TableCell>{c.title}</TableCell><TableCell>{c.party_name}</TableCell><TableCell><Chip label={c.law_contract_types?.name || "-"} size="small" variant="outlined" /></TableCell><TableCell><Chip label={c.status} size="small" color="warning" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell align="right"><Button size="small" variant="contained" color="success" sx={{ mr: 1 }} onClick={() => handleDecision(c.id, 'active')}>Approve</Button><Button size="small" variant="outlined" color="error" onClick={() => handleDecision(c.id, 'terminated')}>Reject</Button></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
