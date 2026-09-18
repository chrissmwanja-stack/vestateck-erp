import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Chip, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

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
    const { data } = await supabase
      .from("bd_opportunities")
      .select("*, bd_clients(bd_client_categories(name))")
      .in("stage", ["closed_won", "closed_lost"]);

    const opps = ((data as any[]) || []).map((o: any) => ({
      ...o,
      bd_clients: Array.isArray(o.bd_clients) ? o.bd_clients[0] ?? null : o.bd_clients ?? null,
    })).map((o: any) => ({
      ...o,
      bd_clients: o.bd_clients ? { ...o.bd_clients, bd_client_categories: Array.isArray(o.bd_clients.bd_client_categories) ? o.bd_clients.bd_client_categories[0] ?? null : o.bd_clients.bd_client_categories ?? null } : null,
    })) as Opp[];
    const won = opps.filter(o => o.stage === "closed_won");
    const lost = opps.filter(o => o.stage === "closed_lost");

    const wonValue = won.reduce((s, o) => s + Number(o.estimated_value), 0);
    const lostValue = lost.reduce((s, o) => s + Number(o.estimated_value), 0);
    const total = opps.length;
    const winRate = total > 0 ? (won.length / total) * 100 : 0;

    setStats({ total, won: won.length, lost: lost.length, winRate, wonValue, lostValue });

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

  const handleExportExcel = () => {
    const rows = byCategory.map(c => ({ category: c.category, won: c.won, lost: c.lost, winRate: Number(c.winRate.toFixed(1)), wonValue: c.wonValue, lostValue: c.lostValue }));
    const cols = [
      { header: "Category", accessor: (r:any) => r.category },
      { header: "Won", accessor: (r:any) => r.won },
      { header: "Lost", accessor: (r:any) => r.lost },
      { header: "Win Rate %", accessor: (r:any) => r.winRate },
      { header: "Won Value", accessor: (r:any) => r.wonValue },
      { header: "Lost Value", accessor: (r:any) => r.lostValue },
    ];
    exportReportToExcel("win_loss_report", "Win/Loss Report", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = byCategory.map(c => ({ category: c.category, won: String(c.won), lost: String(c.lost), rate: `${c.winRate.toFixed(0)}%` }));
    const cols = [
      { header: "Category", accessor: (r:any) => r.category },
      { header: "Won", accessor: (r:any) => r.won },
      { header: "Lost", accessor: (r:any) => r.lost },
      { header: "Win Rate", accessor: (r:any) => r.rate },
    ];
    exportReportToPdf("win_loss_report.pdf", "Win/Loss Report", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const chartData = byCategory.slice(0, 8).map(c => ({ name: c.category, winRate: Number(c.winRate.toFixed(1)), won: c.won, lost: c.lost }));

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3, flexWrap: "wrap", gap: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Win/Loss Report</Typography><Typography variant="body2" color="text.secondary">Win rate from closed opportunities (closed_won vs closed_lost). Breakdown by client category.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption" color="text.secondary">Total Closed</Typography><Typography variant="h5" fontWeight={700}>{stats.total}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "success.light" }}><CardContent><Typography variant="caption">Won</Typography><Typography variant="h5" fontWeight={700}>{stats.won} • UGX {stats.wonValue.toLocaleString()}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "error.light" }}><CardContent><Typography variant="caption">Lost</Typography><Typography variant="h5" fontWeight={700}>{stats.lost} • UGX {stats.lostValue.toLocaleString()}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "primary.light", color: "primary.contrastText" }}><CardContent><Typography variant="caption" sx={{ opacity: 0.8 }}>Win Rate</Typography><Typography variant="h5" fontWeight={700}>{stats.winRate.toFixed(1)}%</Typography></CardContent></Card>
      </Box>

      {byCategory.length > 0 && <Card sx={{ mb: 3 }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Win Rate by Client Category</Typography><Box sx={{ height: 280 }}><ResponsiveContainer width="100%" height="100%"><BarChart data={chartData}><XAxis dataKey="name" tick={{ fontSize: 10 }} interval={0} angle={-14} textAnchor="end" height={60} /><YAxis tick={{ fontSize: 11 }} /><ReTooltip /><Legend /><Bar dataKey="winRate" fill="#2e7d32" name="Win Rate %" /><Bar dataKey="won" fill="#1976d2" name="Won" /><Bar dataKey="lost" fill="#d32f2f" name="Lost" /></BarChart></ResponsiveContainer></Box></CardContent></Card>}

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
                    <TableCell>UGX {c.wonValue.toLocaleString()}</TableCell>
                    <TableCell>UGX {c.lostValue.toLocaleString()}</TableCell>
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
