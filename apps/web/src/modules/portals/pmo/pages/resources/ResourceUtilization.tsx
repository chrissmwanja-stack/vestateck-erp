import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function ResourceUtilization() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Resource Utilization</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Utilization % per resource, over/under allocation detection.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Resource</TableCell><TableCell>Allocated Hours</TableCell><TableCell>Available Hours</TableCell><TableCell>Utilization %</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No utilization data yet. Requires resource assignments + tasks hours.</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
