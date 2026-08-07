import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Agg { name: string; count: number; active: number; onLeave: number; }

export default function HeadcountReport() {
  const [byDept, setByDept] = useState<Agg[]>([]);
  const [byPosition, setByPosition] = useState<Agg[]>([]);
  const [loading, setLoading] = useState(true);
  const [total, setTotal] = useState({ total: 0, active: 0 });

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("hr_employees").select("employment_status, is_active, hr_departments(name), hr_positions(title)");
    const employees = (data as any[]) || [];

    const deptMap: Record<string, Agg> = {};
    const posMap: Record<string, Agg> = {};

    employees.forEach((e: any) => {
      const deptName = e.hr_departments?.name || "Unassigned";
      if (!deptMap[deptName]) deptMap[deptName] = { name: deptName, count: 0, active: 0, onLeave: 0 };
      deptMap[deptName].count++;
      if (e.is_active) deptMap[deptName].active++;
      if (e.employment_status === 'on_leave') deptMap[deptName].onLeave++;

      const posName = e.hr_positions?.title || "Unassigned";
      if (!posMap[posName]) posMap[posName] = { name: posName, count: 0, active: 0, onLeave: 0 };
      posMap[posName].count++;
      if (e.is_active) posMap[posName].active++;
      if (e.employment_status === 'on_leave') posMap[posName].onLeave++;
    });

    setByDept(Object.values(deptMap).sort((a, b) => b.count - a.count));
    setByPosition(Object.values(posMap).sort((a, b) => b.count - a.count));
    setTotal({ total: employees.length, active: employees.filter((e: any) => e.is_active).length });
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Headcount Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Headcount by department and position. Total {total.total} employees, {total.active} active.</Typography>

      <Box sx={{ display: "flex", gap: 3, flexWrap: "wrap" }}>
        <Card sx={{ flex: 1, minWidth: 400 }}>
          <CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>By Department</Typography>
            <Table size="small"><TableHead><TableRow><TableCell>Department</TableCell><TableCell>Total</TableCell><TableCell>Active</TableCell><TableCell>On Leave</TableCell></TableRow></TableHead><TableBody>{byDept.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center" }}><Typography variant="caption" color="text.secondary">No data</Typography></TableCell></TableRow> : byDept.map(d => <TableRow key={d.name}><TableCell><Typography fontWeight={600}>{d.name}</Typography></TableCell><TableCell>{d.count}</TableCell><TableCell><Chip label={d.active} size="small" color="success" /></TableCell><TableCell><Chip label={d.onLeave} size="small" color={d.onLeave > 0 ? "warning" : "default"} /></TableCell></TableRow>)}</TableBody></Table>
          </CardContent>
        </Card>

        <Card sx={{ flex: 1, minWidth: 400 }}>
          <CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>By Position</Typography>
            <Table size="small"><TableHead><TableRow><TableCell>Position</TableCell><TableCell>Total</TableCell><TableCell>Active</TableCell><TableCell>On Leave</TableCell></TableRow></TableHead><TableBody>{byPosition.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center" }}><Typography variant="caption" color="text.secondary">No data</Typography></TableCell></TableRow> : byPosition.map(p => <TableRow key={p.name}><TableCell><Typography fontWeight={600}>{p.name}</Typography></TableCell><TableCell>{p.count}</TableCell><TableCell><Chip label={p.active} size="small" color="success" /></TableCell><TableCell><Chip label={p.onLeave} size="small" color={p.onLeave > 0 ? "warning" : "default"} /></TableCell></TableRow>)}</TableBody></Table>
          </CardContent>
        </Card>
      </Box>
    </Box>
  );
}
