import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Proposal {
  id: string;
  status: string;
  total_value: number;
  created_at: string;
  updated_at: string;
}

interface StatusAgg {
  status: string;
  label: string;
  count: number;
  totalValue: number;
  avgValue: number;
  avgDays: number;
}

export default function ProposalStatusReport() {
  const [aggs, setAggs] = useState<StatusAgg[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_proposals").select("status, total_value, created_at, updated_at");
    const proposals = (data as Proposal[]) || [];

    const map: Record<string, { count: number; totalValue: number; totalDays: number }> = {};

    proposals.forEach(p => {
      if (!map[p.status]) map[p.status] = { count: 0, totalValue: 0, totalDays: 0 };
      map[p.status].count += 1;
      map[p.status].totalValue += Number(p.total_value);
      const created = new Date(p.created_at).getTime();
      const updated = new Date(p.updated_at).getTime();
      const days = (updated - created) / (1000 * 60 * 60 * 24);
      map[p.status].totalDays += days;
    });

    const statusLabels: Record<string, string> = {
      draft: "Draft",
      in_review: "In Review",
      pending_approval: "Pending Approval",
      approved: "Approved",
      sent: "Sent",
      accepted: "Accepted",
      rejected: "Rejected",
      expired: "Expired",
    };

    const result = Object.entries(map).map(([status, v]) => ({
      status,
      label: statusLabels[status] || status,
      count: v.count,
      totalValue: v.totalValue,
      avgValue: v.count > 0 ? v.totalValue / v.count : 0,
      avgDays: v.count > 0 ? v.totalDays / v.count : 0,
    }));

    // Also try to fetch stage order to sort
    const { data: stages } = await supabase.from("bd_proposal_statuses").select("status, order_index").order("order_index");
    const orderMap: Record<string, number> = {};
    stages?.forEach((s: any) => orderMap[s.status] = s.order_index);

    result.sort((a, b) => (orderMap[a.status] ?? 999) - (orderMap[b.status] ?? 999));

    setAggs(result);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Proposal Status Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Count and value by proposal status. Avg days = time from creation to last update in that status (approx).</Typography>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead><TableRow><TableCell>Status</TableCell><TableCell>Count</TableCell><TableCell>Total Value</TableCell><TableCell>Avg Value</TableCell><TableCell>Avg Days in Status</TableCell></TableRow></TableHead>
            <TableBody>
              {aggs.length === 0 ? (
                <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No proposals yet. Create proposals via New Proposal.</Typography></TableCell></TableRow>
              ) : (
                aggs.map(a => (
                  <TableRow key={a.status} hover>
                    <TableCell><Chip label={a.label} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>{a.count}</TableCell>
                    <TableCell>USD {a.totalValue.toLocaleString()}</TableCell>
                    <TableCell>USD {a.avgValue.toLocaleString(undefined, { maximumFractionDigits: 0 })}</TableCell>
                    <TableCell>{a.avgDays.toFixed(1)} days</TableCell>
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
