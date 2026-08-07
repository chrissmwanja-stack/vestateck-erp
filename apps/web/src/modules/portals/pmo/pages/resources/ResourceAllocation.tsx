import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function ResourceAllocation() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Resource Allocation</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Who is allocated where, capacity %, allocation dates.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Resource</TableCell><TableCell>Project</TableCell><TableCell>Allocation %</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No allocations yet. Needs resource_assignments table (resource_id, project_id, allocation_percent).</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
