import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
export default function DailyLogs() {
  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Daily Operation Logs</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Operator daily logs: hours used, work description, project.</Typography>
      <Card><CardContent><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Machine</TableCell><TableCell>Operator</TableCell><TableCell>Hours</TableCell><TableCell>Work</TableCell></TableRow></TableHead><TableBody><TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No logs yet. Needs operation_logs table (machine_id, log_date, hours_used, operator_name, work_description).</Typography></TableCell></TableRow></TableBody></Table></CardContent></Card>
    </Box>
  );
}
