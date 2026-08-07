import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function MaintenanceHistory() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Maintenance History</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Past completed maintenance, cost, downtime, parts used.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Completed Date</TableCell><TableCell>Cost</TableCell><TableCell>Downtime</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No history yet. Completed maintenance requests appear here.</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
