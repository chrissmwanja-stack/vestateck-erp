import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography, CircularProgress, LinearProgress } from "@mui/material";
import { useEffect, useState } from "react";
import { supabase } from "../../../../../lib/supabaseClient";

export default function ResourceUtilization() {
  const [util, setUtil] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      // For shell, compute from tasks assigned
      const { data: tasks } = await supabase.from("pmo_tasks").select("assignee_id");
      const assigneeMap: Record<string, number> = {};
      (tasks as any[] || []).forEach((t: any) => {
        if (t.assignee_id) assigneeMap[t.assignee_id] = (assigneeMap[t.assignee_id] || 0) + 1;
      });

      // Try to get employee names
      const { data: employees } = await supabase.from("hr_employees").select("id, first_name, last_name").eq("is_active", true).limit(20);
      const list = Object.entries(assigneeMap).map(([id, count]) => {
        const emp = (employees as any[])?.find((e: any) => e.id === id);
        const name = emp ? `${emp.first_name} ${emp.last_name}` : id.slice(0,8);
        const utilization = Math.min(100, count * 20); // mock 20% per task
        return { id, name, tasks: count, utilization };
      });

      setUtil(list);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Resource Utilization</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Utilization % per resource based on assigned tasks. Over 100% = overallocated.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Resource</TableCell><TableCell>Assigned Tasks</TableCell><TableCell>Available Hours</TableCell><TableCell>Utilization %</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{util.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No utilization data yet. Assign tasks to employees to see utilization.</Typography></TableCell></TableRow> : util.map(u => <TableRow key={u.id} hover><TableCell><Typography fontWeight={600}>{u.name}</Typography></TableCell><TableCell>{u.tasks}</TableCell><TableCell>40h/week</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><LinearProgress variant="determinate" value={u.utilization} sx={{ width: 100, height: 6 }} color={u.utilization > 100 ? "error" : u.utilization > 80 ? "warning" : "success"} /><Typography variant="caption">{u.utilization}%</Typography></Box></TableCell><TableCell>{u.utilization > 100 ? "Overallocated" : u.utilization > 80 ? "High" : "Normal"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
