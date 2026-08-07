import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function EquipmentAssignments() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Equipment Assignments</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Tracks which equipment assigned to which project/operator, start/end dates.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Project</TableCell><TableCell>Operator</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No assignments yet. Real table needs machine_assignments (machine_id, project_id, operator, dates).</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
