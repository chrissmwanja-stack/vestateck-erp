import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Proposal { id: string; proposal_no: string; title: string; status: string; total_value: number; currency: string; created_at: string; bd_clients?: { name: string } | null; }

export default function ProposalApprovals() {
  const [proposals, setProposals] = useState<Proposal[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchData = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_proposals").select("*, bd_clients(name)").in("status", ["pending_approval", "in_review"]).order("created_at", { ascending: true });
    if (data) setProposals(data as Proposal[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleDecision = async (id: string, decision: 'approved' | 'rejected') => {
    if (!confirm(`Mark proposal as ${decision}?`)) return;
    const { error } = await supabase.from("bd_proposals").update({ status: decision }).eq("id", id);
    if (!error) fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Proposal Approvals</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Proposals pending approval. Same pattern as Material Request Approval and Ticket Approvals. Approve → status becomes Approved → can be Sent.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Proposal No</TableCell><TableCell>Title</TableCell><TableCell>Client</TableCell><TableCell>Status</TableCell><TableCell>Value</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{proposals.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No proposals pending approval. Proposals in In Review or Pending Approval appear here.</Typography></TableCell></TableRow> : proposals.map(p => <TableRow key={p.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{p.proposal_no}</Typography></TableCell><TableCell>{p.title}</TableCell><TableCell>{p.bd_clients?.name || "-"}</TableCell><TableCell><Chip label={p.status} size="small" color="warning" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{p.currency} {Number(p.total_value).toLocaleString()}</TableCell><TableCell align="right"><Button size="small" variant="contained" color="success" sx={{ mr: 1 }} onClick={() => handleDecision(p.id, 'approved')}>Approve</Button><Button size="small" variant="outlined" color="error" onClick={() => handleDecision(p.id, 'rejected')}>Reject</Button></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
