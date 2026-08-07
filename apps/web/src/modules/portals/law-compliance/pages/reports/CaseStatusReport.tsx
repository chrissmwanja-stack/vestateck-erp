import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface CaseItem {
  id: string;
  status: string;
  law_case_types?: { name: string } | null;
}

interface Agg {
  type: string;
  open: number;
  inProgress: number;
  closed: number;
  onHold: number;
  total: number;
}

export default function CaseStatusReport() {
  const [byType, setByType] = useState<Agg[]>([]);
  const [totals, setTotals] = useState({ open: 0, inProgress: 0, closed: 0, onHold: 0, total: 0 });
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("law_cases").select("id, status, law_case_types(name)");
    const cases: CaseItem[] = (data || []).map((row: any) => ({
     id: row.id,
     status: row.status,
    law_case_types: Array.isArray(row.law_case_types) ? row.law_case_types[0] ?? null : row.law_case_types,
   }));

    const map: Record<string, Agg> = {};
    let open = 0, inProgress = 0, closed = 0, onHold = 0;

    cases.forEach(c => {
      const typeName = c.law_case_types?.name || "Uncategorized";
      if (!map[typeName]) map[typeName] = { type: typeName, open: 0, inProgress: 0, closed: 0, onHold: 0, total: 0 };
      map[typeName].total++;
      if (c.status === 'open') { map[typeName].open++; open++; }
      else if (c.status === 'in_progress') { map[typeName].inProgress++; inProgress++; }
      else if (c.status === 'closed') { map[typeName].closed++; closed++; }
      else if (c.status === 'on_hold') { map[typeName].onHold++; onHold++; }
    });

    setByType(Object.values(map).sort((a, b) => b.total - a.total));
    setTotals({ open, inProgress, closed, onHold, total: cases.length });
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Case Status Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Cases breakdown by type and status. Total {totals.total} cases.</Typography>

      <Box sx={{ display: "flex", gap: 1, mb: 3, flexWrap: "wrap" }}>
        <Chip label={`Total: ${totals.total}`} />
        <Chip label={`Open: ${totals.open}`} color="primary" />
        <Chip label={`In Progress: ${totals.inProgress}`} color="info" />
        <Chip label={`On Hold: ${totals.onHold}`} color="warning" />
        <Chip label={`Closed: ${totals.closed}`} color="success" />
      </Box>

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Case Type</TableCell><TableCell>Total</TableCell><TableCell>Open</TableCell><TableCell>In Progress</TableCell><TableCell>On Hold</TableCell><TableCell>Closed</TableCell></TableRow></TableHead><TableBody>{byType.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No cases yet. Create cases via Cases list.</Typography></TableCell></TableRow> : byType.map(b => <TableRow key={b.type} hover><TableCell><Typography fontWeight={600}>{b.type}</Typography></TableCell><TableCell>{b.total}</TableCell><TableCell><Chip label={b.open} size="small" color={b.open > 0 ? "primary" : "default"} /></TableCell><TableCell><Chip label={b.inProgress} size="small" color={b.inProgress > 0 ? "info" : "default"} /></TableCell><TableCell><Chip label={b.onHold} size="small" color={b.onHold > 0 ? "warning" : "default"} /></TableCell><TableCell><Chip label={b.closed} size="small" color={b.closed > 0 ? "success" : "default"} /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
