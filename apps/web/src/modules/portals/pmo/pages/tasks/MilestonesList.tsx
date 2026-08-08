import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function MilestonesList() {
  const [milestones, setMilestones] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("pmo_milestones").select("*, pmo_projects(name)").order("due_date", { ascending: true });
      if (data) setMilestones(data);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Milestones</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Milestone tracking per project, due date, completion %.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Project</TableCell><TableCell>Milestone</TableCell><TableCell>Due Date</TableCell><TableCell>Completion</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{milestones.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No milestones yet. Needs pmo_milestones table (project_id, title, due_date, completion_percent).</Typography></TableCell></TableRow> : milestones.map(m => <TableRow key={m.id} hover><TableCell>{m.pmo_projects?.name || "-"}</TableCell><TableCell><Typography fontWeight={600}>{m.title}</Typography></TableCell><TableCell>{m.due_date ? new Date(m.due_date).toLocaleDateString() : "-"}</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={m.completion_percent || 0} sx={{ flex: 1, height: 6 }} /><Typography variant="caption">{m.completion_percent || 0}%</Typography></Box></TableCell><TableCell><Chip label={m.status || "pending"} size="small" /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
