import { Box, Card, CardContent, Typography } from "@mui/material";
export default function GanttChart() {
  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Gantt Chart</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Timeline view of projects, tasks, milestones. Shows dependencies and progress.</Typography>
      <Card><CardContent><Box sx={{ height: 400, display: "flex", alignItems: "center", justifyContent: "center", bgcolor: "grey.50", borderRadius: 1, border: "1px dashed", borderColor: "divider" }}><Typography color="text.secondary">Gantt chart visualization would render here — needs timeline library (e.g. gantt-task-react) + pmo_tasks + pmo_milestones data. Placeholder for real Gantt.</Typography></Box></CardContent></Card>
    </Box>
  );
}
