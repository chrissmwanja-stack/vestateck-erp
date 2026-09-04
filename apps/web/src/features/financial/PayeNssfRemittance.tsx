import { useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  MenuItem,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

// Same statuses hr_payroll_runs uses elsewhere (see PayrollList.tsx) --
// v_paye_nssf_remittance only ever returns 'approved' or 'disbursed'
// rows (that's the point at which PAYE/NSSF amounts are final and the
// GL posting has happened), so those are the only two this filter
// needs to offer.
const statusColor: Record<string, 'info' | 'success'> = {
  approved: 'info',
  disbursed: 'success',
};

interface RemittanceRow {
  tenant_id: string;
  payroll_run_id: string;
  period: string;
  status: string;
  approved_at: string | null;
  employee_count: number;
  total_gross: number;
  total_paye: number;
  total_nssf_employee: number;
  total_nssf_employer: number;
  total_nssf: number;
  total_net_pay: number;
  remittance_due_date: string | null;
}

export default function PayeNssfRemittance() {
  const [periodFrom, setPeriodFrom] = useState('');
  const [periodTo, setPeriodTo] = useState('');
  const [status, setStatus] = useState('');
  const [rows, setRows] = useState<RemittanceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const runSearch = async () => {
    setLoading(true);
    setError(null);
    let query = supabase
      .from('v_paye_nssf_remittance')
      .select('*')
      .order('period', { ascending: false });

    if (periodFrom) query = query.gte('period', periodFrom);
    if (periodTo) query = query.lte('period', periodTo);
    if (status) query = query.eq('status', status);

    const { data, error: err } = await query;
    if (err) {
      setError(err.message);
      setRows([]);
    } else {
      setRows((data as RemittanceRow[]) ?? []);
    }
    setLoading(false);
  };

  useEffect(() => {
    runSearch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const totals = rows.reduce(
    (acc, r) => {
      acc.gross += Number(r.total_gross);
      acc.paye += Number(r.total_paye);
      acc.nssfEmployee += Number(r.total_nssf_employee);
      acc.nssfEmployer += Number(r.total_nssf_employer);
      acc.nssf += Number(r.total_nssf);
      acc.netPay += Number(r.total_net_pay);
      return acc;
    },
    { gross: 0, paye: 0, nssfEmployee: 0, nssfEmployer: 0, nssf: 0, netPay: 0 }
  );

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        PAYE / NSSF Remittance
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        What's owed to URA (PAYE) and NSSF for each approved or disbursed payroll run. Confirm the current PAYE bands
        and NSSF rates in the statutory rate table before relying on these figures for a live remittance.
      </Typography>

      <Paper sx={{ p: 2, mb: 2 }}>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap', alignItems: 'center' }}>
          <TextField
            label="Period From"
            placeholder="2026-01"
            size="small"
            value={periodFrom}
            onChange={(e) => setPeriodFrom(e.target.value)}
            helperText="YYYY-MM"
          />
          <TextField
            label="Period To"
            placeholder="2026-12"
            size="small"
            value={periodTo}
            onChange={(e) => setPeriodTo(e.target.value)}
            helperText="YYYY-MM"
          />
          <TextField
            select
            label="Status"
            value={status}
            onChange={(e) => setStatus(e.target.value)}
            sx={{ minWidth: 180 }}
            size="small"
          >
            <MenuItem value="">All (approved + disbursed)</MenuItem>
            <MenuItem value="approved">Approved</MenuItem>
            <MenuItem value="disbursed">Disbursed</MenuItem>
          </TextField>
          <Button variant="contained" onClick={runSearch} disabled={loading}>
            Search
          </Button>
          <Button
            variant="outlined"
            onClick={() => {
              setPeriodFrom('');
              setPeriodTo('');
              setStatus('');
            }}
          >
            Clear
          </Button>
        </Box>
      </Paper>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Period</TableCell>
              <TableCell>Status</TableCell>
              <TableCell align="right">Employees</TableCell>
              <TableCell align="right">Total Gross</TableCell>
              <TableCell align="right">PAYE</TableCell>
              <TableCell align="right">NSSF (Employee)</TableCell>
              <TableCell align="right">NSSF (Employer)</TableCell>
              <TableCell align="right">NSSF (Total)</TableCell>
              <TableCell align="right">Total Net Pay</TableCell>
              <TableCell>Remittance Due</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.payroll_run_id}>
                <TableCell>{r.period}</TableCell>
                <TableCell>
                  <Chip size="small" label={r.status} color={statusColor[r.status] ?? 'default'} sx={{ textTransform: 'capitalize' }} />
                </TableCell>
                <TableCell align="right">{r.employee_count}</TableCell>
                <TableCell align="right">{Number(r.total_gross).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.total_paye).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.total_nssf_employee).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.total_nssf_employer).toLocaleString()}</TableCell>
                <TableCell align="right">
                  <Typography fontWeight={600}>{Number(r.total_nssf).toLocaleString()}</Typography>
                </TableCell>
                <TableCell align="right">{Number(r.total_net_pay).toLocaleString()}</TableCell>
                <TableCell>{r.remittance_due_date ?? '—'}</TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={10} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                  No approved or disbursed payroll runs found for the selected filters.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>

      {rows.length > 0 && (
        <Typography variant="subtitle2" sx={{ mt: 1 }}>
          Totals — Gross: {totals.gross.toLocaleString()} &nbsp;|&nbsp; PAYE due: {totals.paye.toLocaleString()}{' '}
          &nbsp;|&nbsp; NSSF due (employee + employer): {totals.nssf.toLocaleString()} &nbsp;|&nbsp; Net Pay:{' '}
          {totals.netPay.toLocaleString()}
        </Typography>
      )}
    </Box>
  );
}