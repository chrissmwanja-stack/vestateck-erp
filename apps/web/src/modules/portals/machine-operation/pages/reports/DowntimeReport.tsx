import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function DowntimeReport() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Downtime Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Downtime reasons, MTTR, MTBF, total downtime hours from maintenance_requests.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Reason</TableCell><TableCell>Downtime Hours</TableCell><TableCell>MTTR</TableCell><TableCell>MTBF</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No downtime data yet. Requires maintenance_requests with downtime tracking.</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
