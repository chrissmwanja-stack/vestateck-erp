import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

const STATUS_ORDER = ["draft", "in_review", "pending_approval", "approved", "sent", "accepted"];

export default function ProposalTracking() {
  const [proposals, setProposals] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("bd_proposals").select("proposal_no, title, status, created_at, updated_at, bd_clients(name)").order("updated_at", { ascending: false }).limit(50);
      if (data) setProposals(data);
      setLoading(false);
    };
    fetch();
  }, []);

  const getProgress = (status: string) => {
    const idx = STATUS_ORDER.indexOf(status);
    return idx >= 0 ? ((idx + 1) / STATUS_ORDER.length) * 100 : 0;
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Proposal Tracking</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Status timeline tracker: draft → in_review → pending_approval → approved → sent → accepted/rejected. Shows where each proposal is in workflow.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Proposal</TableCell><TableCell>Client</TableCell><TableCell>Status Timeline</TableCell><TableCell>Progress</TableCell><TableCell>Last Update</TableCell></TableRow></TableHead><TableBody>{proposals.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No proposals to track. Create proposals via New Proposal.</Typography></TableCell></TableRow> : proposals.map(p => (
        <TableRow key={p.proposal_no} hover>
          <TableCell><Typography fontFamily="monospace" fontWeight={600}>{p.proposal_no}</Typography><Typography variant="caption" sx={{ display: "block" }}>{p.title}</Typography></TableCell>
          <TableCell>{p.bd_clients?.name || "-"}</TableCell>
          <TableCell>
            <Box sx={{ display: "flex", gap: 0.5, flexWrap: "wrap", maxWidth: 300 }}>
              {STATUS_ORDER.map(s => (
                <Chip key={s} label={s} size="small" variant={STATUS_ORDER.indexOf(s) <= STATUS_ORDER.indexOf(p.status) ? "filled" : "outlined"} color={s === p.status ? "primary" : STATUS_ORDER.indexOf(s) < STATUS_ORDER.indexOf(p.status) ? "success" : "default"} sx={{ fontSize: 10, height: 20 }} />
              ))}
            </Box>
          </TableCell>
          <TableCell><Box sx={{ minWidth: 100 }}><LinearProgress variant="determinate" value={getProgress(p.status)} sx={{ height: 6, borderRadius: 1, mb: 0.5 }} /><Typography variant="caption">{getProgress(p.status).toFixed(0)}%</Typography></Box></TableCell>
          <TableCell><Typography variant="caption">{new Date(p.updated_at).toLocaleString()}</Typography></TableCell>
        </TableRow>
      ))}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
