import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function MaintenanceSchedule() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Maintenance Schedule</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Preventive maintenance calendar, due dates, recurring schedule.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Scheduled Date</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No scheduled maintenance yet. Create via Maintenance Requests + set scheduled_date.</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
