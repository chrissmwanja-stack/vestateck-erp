import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function UtilizationReport() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Utilization Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Utilization % by machine / project, based on operation_logs hours_used vs available hours.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Project</TableCell><TableCell>Hours Used</TableCell><TableCell>Available Hours</TableCell><TableCell>Utilization %</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No utilization data yet. Requires operation_logs + machines.</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
