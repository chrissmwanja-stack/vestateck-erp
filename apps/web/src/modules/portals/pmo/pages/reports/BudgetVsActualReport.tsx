import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function BudgetVsActualReport() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Budget vs Actual</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Budget consumption, variance, forecast to complete.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Project</TableCell><TableCell>Budget</TableCell><TableCell>Actual Cost</TableCell><TableCell>Variance</TableCell><TableCell>Utilization %</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No budget data yet. Needs pmo_projects budget + cost tracking integration with Finance.</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
