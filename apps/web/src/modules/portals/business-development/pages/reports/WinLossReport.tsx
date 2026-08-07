import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Chip } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Opp {
  id: string;
  stage: string;
  estimated_value: number;
  bd_clients?: { bd_client_categories?: { name: string } | null } | null;
}

export default function WinLossReport() {
  const [stats, setStats] = useState({ total: 0, won: 0, lost: 0, winRate: 0, wonValue: 0, lostValue: 0 });
  const [byCategory, setByCategory] = useState<{ category: string; won: number; lost: number; winRate: number; wonValue: number; lostValue: number }[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    // Fetch closed opportunities with client category join
    const { data } = await supabase
      .from("bd_opportunities")
      .select("*, bd_clients(bd_client_categories(name))")
      .in("stage", ["closed_won", "closed_lost"]);

    const opps = (data as Opp[]) || [];
    const won = opps.filter(o => o.stage === "closed_won");
    const lost = opps.filter(o => o.stage === "closed_lost");

    const wonValue = won.reduce((s, o) => s + Number(o.estimated_value), 0);
    const lostValue = lost.reduce((s, o) => s + Number(o.estimated_value), 0);
    const total = opps.length;
    const winRate = total > 0 ? (won.length / total) * 100 : 0;

    setStats({ total, won: won.length, lost: lost.length, winRate, wonValue, lostValue });

    // Group by client category
    const map: Record<string, { won: number; lost: number; wonValue: number; lostValue: number }> = {};
    opps.forEach(o => {
      const cat = o.bd_clients?.bd_client_categories?.name || "Uncategorized";
      if (!map[cat]) map[cat] = { won: 0, lost: 0, wonValue: 0, lostValue: 0 };
      if (o.stage === "closed_won") {
        map[cat].won += 1;
        map[cat].wonValue += Number(o.estimated_value);
      } else {
        map[cat].lost += 1;
        map[cat].lostValue += Number(o.estimated_value);
      }
    });

    const byCat = Object.entries(map).map(([category, v]) => ({
      category,
      ...v,
      winRate: v.won + v.lost > 0 ? (v.won / (v.won + v.lost)) * 100 : 0,
    }));
    setByCategory(byCat);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Win/Loss Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Win rate from closed opportunities (closed_won vs closed_lost). Breakdown by client category.</Typography>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption" color="text.secondary">Total Closed</Typography><Typography variant="h5" fontWeight={700}>{stats.total}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "success.light" }}><CardContent><Typography variant="caption">Won</Typography><Typography variant="h5" fontWeight={700}>{stats.won} • USD {stats.wonValue.toLocaleString()}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "error.light" }}><CardContent><Typography variant="caption">Lost</Typography><Typography variant="h5" fontWeight={700}>{stats.lost} • USD {stats.lostValue.toLocaleString()}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "primary.light", color: "primary.contrastText" }}><CardContent><Typography variant="caption" sx={{ opacity: 0.8 }}>Win Rate</Typography><Typography variant="h5" fontWeight={700}>{stats.winRate.toFixed(1)}%</Typography></CardContent></Card>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead><TableRow><TableCell>Client Category</TableCell><TableCell>Won</TableCell><TableCell>Lost</TableCell><TableCell>Win Rate</TableCell><TableCell>Won Value</TableCell><TableCell>Lost Value</TableCell></TableRow></TableHead>
            <TableBody>
              {byCategory.length === 0 ? (
                <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No closed opportunities yet. Move opportunities to Closed Won / Closed Lost in Pipeline Board.</Typography></TableCell></TableRow>
              ) : (
                byCategory.map(c => (
                  <TableRow key={c.category} hover>
                    <TableCell><Chip label={c.category} size="small" variant="outlined" /></TableCell>
                    <TableCell>{c.won}</TableCell>
                    <TableCell>{c.lost}</TableCell>
                    <TableCell><Chip label={`${c.winRate.toFixed(0)}%`} size="small" color={c.winRate > 60 ? "success" : c.winRate > 40 ? "warning" : "error"} /></TableCell>
                    <TableCell>USD {c.wonValue.toLocaleString()}</TableCell>
                    <TableCell>USD {c.lostValue.toLocaleString()}</TableCell>
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