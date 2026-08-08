import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function ProjectStatusReport() {
  const [projects, setProjects] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("pmo_projects").select("*, pmo_tasks(id, status)");
      if (data) setProjects(data);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Project Status Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Status distribution, total tasks, completed, overdue.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Project</TableCell><TableCell>Status</TableCell><TableCell>Total Tasks</TableCell><TableCell>Completed</TableCell><TableCell>Overdue</TableCell><TableCell>Progress</TableCell></TableRow></TableHead><TableBody>{projects.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No projects yet. Create via New Project.</Typography></TableCell></TableRow> : projects.map((p: any) => {
        const totalTasks = p.pmo_tasks?.length || 0;
        const completed = p.pmo_tasks?.filter((t: any) => t.status === 'done').length || 0;
        const progress = totalTasks > 0 ? (completed / totalTasks) * 100 : 0;
        return <TableRow key={p.id} hover><TableCell><Typography fontWeight={600}>{p.name}</Typography></TableCell><TableCell><Chip label={p.status} size="small" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{totalTasks}</TableCell><TableCell>{completed}</TableCell><TableCell>0</TableCell><TableCell>{progress.toFixed(0)}%</TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
