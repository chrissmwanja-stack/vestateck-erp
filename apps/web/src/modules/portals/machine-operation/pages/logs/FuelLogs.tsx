import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function FuelLogs() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Fuel & Consumption</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Fuel logs: liters, cost, consumption per hour.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Machine</TableCell><TableCell>Liters</TableCell><TableCell>Cost</TableCell><TableCell>Consumption L/hr</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No fuel logs yet. Needs fuel_logs table (machine_id, log_date, fuel_liters, cost).</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
