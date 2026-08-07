import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function MilestonesList() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Milestones</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Milestone tracking per project, due date, completion %.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Project</TableCell><TableCell>Milestone</TableCell><TableCell>Due Date</TableCell><TableCell>Completion %</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No milestones yet. Needs pmo_milestones table (project_id, title, due_date, completion_percent).</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
