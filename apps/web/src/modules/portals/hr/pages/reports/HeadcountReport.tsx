import { useEffect, useState, useMemo } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Grid } from "@mui/material";
import { Download, FileDownload } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel } from "../../../../../lib/reportExport";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

interface Agg { name: string; count: number; active: number; onLeave: number; }

export default function HeadcountReport() {
  const [byDept, setByDept] = useState<Agg[]>([]);
  const [byPosition, setByPosition] = useState<Agg[]>([]);
  const [loading, setLoading] = useState(true);
  const [total, setTotal] = useState({ total: 0, active: 0 });

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("hr_employees").select("employment_status, is_active, departments(name), hr_positions(title)").limit(500);
    const employees = (data as any[]) || [];

    const deptMap: Record<string, Agg> = {};
    const posMap: Record<string, Agg> = {};

    employees.forEach((e: any) => {
      const dept = Array.isArray(e.departments) ? e.departments[0] : e.departments;
      const pos = Array.isArray(e.hr_positions) ? e.hr_positions[0] : e.hr_positions;
      const deptName = dept?.name || "Unassigned";
      if (!deptMap[deptName]) deptMap[deptName] = { name: deptName, count: 0, active: 0, onLeave: 0 };
      deptMap[deptName].count++;
      if (e.is_active) deptMap[deptName].active++;
      if (e.employment_status === 'on_leave') deptMap[deptName].onLeave++;

      const posName = pos?.title || "Unassigned";
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

  const deptChart = useMemo(() => byDept.slice(0, 8).map(d => ({ name: d.name.length > 14 ? d.name.slice(0,14)+'…' : d.name, Total: d.count, Active: d.active })), [byDept]);
  const posChart = useMemo(() => byPosition.slice(0, 8).map(p => ({ name: p.name.length > 14 ? p.name.slice(0,14)+'…' : p.name, Total: p.count, Active: p.active })), [byPosition]);

  const handleExcelDept = () => {
    const cols = [
      { header: "Department", accessor: (r: Agg) => r.name },
      { header: "Total", accessor: (r: Agg) => r.count },
      { header: "Active", accessor: (r: Agg) => r.active },
      { header: "On Leave", accessor: (r: Agg) => r.onLeave },
    ];
    exportReportToExcel(`headcount-by-dept-${new Date().toISOString().slice(0,10)}`, "By Department", cols as any, byDept);
  };
  const handleExcelPos = () => {
    const cols = [
      { header: "Position", accessor: (r: Agg) => r.name },
      { header: "Total", accessor: (r: Agg) => r.count },
      { header: "Active", accessor: (r: Agg) => r.active },
      { header: "On Leave", accessor: (r: Agg) => r.onLeave },
    ];
    exportReportToExcel(`headcount-by-position-${new Date().toISOString().slice(0,10)}`, "By Position", cols as any, byPosition);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>Headcount Report</Typography>
          <Typography variant="body2" color="text.secondary">Headcount by department and position. Total {total.total} employees, {total.active} active.</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExcelDept} disabled={byDept.length===0}>Dept Excel</Button>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExcelPos} disabled={byPosition.length===0}>Position Excel</Button>
        </Box>
      </Box>

      <Grid container spacing={2} sx={{ mb: 2 }}>
        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>By Department (Top 8)</Typography>
            {byDept.length===0 ? <Typography variant="caption" color="text.secondary">No data</Typography> : (
              <ResponsiveContainer width="100%" height={260}>
                <BarChart data={deptChart} layout="vertical" margin={{ left: 90 }}>
                  <XAxis type="number" allowDecimals={false} fontSize={12} />
                  <YAxis type="category" dataKey="name" width={90} fontSize={12} />
                  <ReTooltip /><Legend />
                  <Bar dataKey="Total" fill="#1976d2" radius={[0,8,8,0]} />
                  <Bar dataKey="Active" fill="#2e7d32" radius={[0,8,8,0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>By Position (Top 8)</Typography>
            {byPosition.length===0 ? <Typography variant="caption" color="text.secondary">No data</Typography> : (
              <ResponsiveContainer width="100%" height={260}>
                <BarChart data={posChart} layout="vertical" margin={{ left: 90 }}>
                  <XAxis type="number" allowDecimals={false} fontSize={12} />
                  <YAxis type="category" dataKey="name" width={90} fontSize={12} />
                  <ReTooltip /><Legend />
                  <Bar dataKey="Total" fill="#6d4c41" radius={[0,8,8,0]} />
                  <Bar dataKey="Active" fill="#2e7d32" radius={[0,8,8,0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </CardContent></Card>
        </Grid>
      </Grid>

      <Box sx={{ display: "flex", gap: 3, flexWrap: "wrap" }}>
        <Card sx={{ flex: 1, minWidth: 400 }}>
          <CardContent>
            <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
              <Typography variant="subtitle2" fontWeight={700}>By Department</Typography>
              <Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExcelDept}>Excel</Button>
            </Box>
            <Table size="small"><TableHead><TableRow><TableCell>Department</TableCell><TableCell>Total</TableCell><TableCell>Active</TableCell><TableCell>On Leave</TableCell></TableRow></TableHead><TableBody>{byDept.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center" }}><Typography variant="caption" color="text.secondary">No data</Typography></TableCell></TableRow> : byDept.map(d => <TableRow key={d.name} hover><TableCell><Typography fontWeight={600}>{d.name}</Typography></TableCell><TableCell>{d.count}</TableCell><TableCell><Chip label={d.active} size="small" color="success" /></TableCell><TableCell><Chip label={d.onLeave} size="small" color={d.onLeave > 0 ? "warning" : "default"} /></TableCell></TableRow>)}</TableBody></Table>
          </CardContent>
        </Card>

        <Card sx={{ flex: 1, minWidth: 400 }}>
          <CardContent>
            <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
              <Typography variant="subtitle2" fontWeight={700}>By Position</Typography>
              <Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExcelPos}>Excel</Button>
            </Box>
            <Table size="small"><TableHead><TableRow><TableCell>Position</TableCell><TableCell>Total</TableCell><TableCell>Active</TableCell><TableCell>On Leave</TableCell></TableRow></TableHead><TableBody>{byPosition.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center" }}><Typography variant="caption" color="text.secondary">No data</Typography></TableCell></TableRow> : byPosition.map(p => <TableRow key={p.name} hover><TableCell><Typography fontWeight={600}>{p.name}</Typography></TableCell><TableCell>{p.count}</TableCell><TableCell><Chip label={p.active} size="small" color="success" /></TableCell><TableCell><Chip label={p.onLeave} size="small" color={p.onLeave > 0 ? "warning" : "default"} /></TableCell></TableRow>)}</TableBody></Table>
          </CardContent>
        </Card>
      </Box>
    </Box>
  );
}
