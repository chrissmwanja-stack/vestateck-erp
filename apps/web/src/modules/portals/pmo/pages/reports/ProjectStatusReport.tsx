import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography,  } from "@mui/material";
export default function ProjectStatusReport() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Project Status Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Status distribution, overdue tasks, milestone slipping.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Project</TableCell><TableCell>Status</TableCell><TableCell>Total Tasks</TableCell><TableCell>Completed</TableCell><TableCell>Overdue</TableCell><TableCell>Progress</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No project status data yet. Needs pmo_projects + pmo_tasks aggregation.</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
