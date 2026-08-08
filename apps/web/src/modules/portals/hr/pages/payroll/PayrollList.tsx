import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography, Chip } from "@mui/material";

const MOCK_PAYROLL = [
  { id: "1", employee: "John Doe", period: "2026-01", basic: 3000, allowances: 500, deductions: 200, net: 3300, status: "paid" },
  { id: "2", employee: "Jane Smith", period: "2026-01", basic: 2800, allowances: 300, deductions: 150, net: 2950, status: "paid" },
  { id: "3", employee: "Peter Okello", period: "2026-01", basic: 2500, allowances: 400, deductions: 100, net: 2800, status: "pending" },
];

export default function PayrollList() {
  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Payroll</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Payroll run, basic salary, allowances, deductions, net pay, slips. Integration with Finance.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Employee</TableCell><TableCell>Period</TableCell><TableCell>Basic</TableCell><TableCell>Allowances</TableCell><TableCell>Deductions</TableCell><TableCell>Net Pay</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{MOCK_PAYROLL.map(p => <TableRow key={p.id} hover><TableCell><Typography fontWeight={600}>{p.employee}</Typography></TableCell><TableCell>{p.period}</TableCell><TableCell>UGX {p.basic.toLocaleString()}</TableCell><TableCell>UGX {p.allowances.toLocaleString()}</TableCell><TableCell>UGX {p.deductions.toLocaleString()}</TableCell><TableCell><Typography fontWeight={700}>UGX {p.net.toLocaleString()}</Typography></TableCell><TableCell><Chip label={p.status} size="small" color={p.status === 'paid' ? 'success' : 'warning'} sx={{ textTransform: "capitalize" }} /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}><Typography variant="caption">Real implementation needs hr_payroll_runs, hr_payroll_items tables + calculation logic + payslip PDF generation. For shell, mock data. Next: integrate with Financial Management Petty Cash / Bank Payments for actual disbursement.</Typography></Box>
    </Box>
  );
}
