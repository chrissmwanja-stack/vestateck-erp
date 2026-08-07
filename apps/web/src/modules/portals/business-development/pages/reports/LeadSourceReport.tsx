import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Lead {
  id: string;
  source_id: string;
  estimated_value: number | null;
  converted_to_opportunity_id: string | null;
  status: string;
  bd_lead_sources?: { name: string } | null;
}

interface SourceAgg {
  source_id: string;
  source_name: string;
  count: number;
  totalValue: number;
  qualified: number;
  converted: number;
  conversionRate: number;
}

export default function LeadSourceReport() {
  const [aggs, setAggs] = useState<SourceAgg[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_leads").select("*, bd_lead_sources(name)");
    const leads = (data as Lead[]) || [];

    const map: Record<string, { name: string; count: number; totalValue: number; qualified: number; converted: number }> = {};

    leads.forEach(l => {
      const name = l.bd_lead_sources?.name || "Unknown";
      if (!map[l.source_id]) map[l.source_id] = { name, count: 0, totalValue: 0, qualified: 0, converted: 0 };
      map[l.source_id].count += 1;
      map[l.source_id].totalValue += Number(l.estimated_value || 0);
      if (l.status === "qualified") map[l.source_id].qualified += 1;
      if (l.converted_to_opportunity_id || l.status === "converted") map[l.source_id].converted += 1;
    });

    const result = Object.entries(map).map(([source_id, v]) => ({
      source_id,
      source_name: v.name,
      count: v.count,
      totalValue: v.totalValue,
      qualified: v.qualified,
      converted: v.converted,
      conversionRate: v.count > 0 ? (v.converted / v.count) * 100 : 0,
    }));

    result.sort((a, b) => b.count - a.count);
    setAggs(result);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Lead Source Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Leads count and value by source, with conversion rate to opportunity. Uses bd_leads + bd_lead_sources.</Typography>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead><TableRow><TableCell>Source</TableCell><TableCell>Leads Count</TableCell><TableCell>Total Estimated Value</TableCell><TableCell>Qualified</TableCell><TableCell>Converted to Opp</TableCell><TableCell>Conversion Rate</TableCell></TableRow></TableHead>
            <TableBody>
              {aggs.length === 0 ? (
                <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No leads yet. Create leads via New Lead and set source from Lead Sources admin.</Typography></TableCell></TableRow>
              ) : (
                aggs.map(a => (
                  <TableRow key={a.source_id} hover>
                    <TableCell><Chip label={a.source_name} size="small" variant="outlined" /></TableCell>
                    <TableCell>{a.count}</TableCell>
                    <TableCell>USD {a.totalValue.toLocaleString()}</TableCell>
                    <TableCell>{a.qualified}</TableCell>
                    <TableCell>{a.converted}</TableCell>
                    <TableCell><Chip label={`${a.conversionRate.toFixed(0)}%`} size="small" color={a.conversionRate > 50 ? "success" : a.conversionRate > 20 ? "warning" : "default"} /></TableCell>
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