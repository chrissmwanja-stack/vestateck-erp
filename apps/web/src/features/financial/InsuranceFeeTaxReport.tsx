import { useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { errorText, rpc } from '../../modules/portals/insurance/db';
import { formatMoney } from '../../modules/portals/insurance/logic';
import {
  exportReportToExcel,
  exportReportToPdf,
  type ReportExportColumn,
} from '../../lib/reportExport';
interface Row {
  charge_id: string;
  policy_no: string;
  invoice_date: string;
  description: string;
  currency: string;
  fee_amount: number;
  vat_mode: string;
  vat_rate_pct: number | null;
  vat_amount: number;
  invoice_line_total: number;
  journal_entry_id: string;
}
export default function InsuranceFeeTaxReport() {
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [data, setData] = useState<Row[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const load = async () => {
    setBusy(true);
    setError(null);
    try {
      setData(
        await rpc<Row[]>('ins_broker_fee_tax_rows', {
          p_date_from: from || null,
          p_date_to: to || null,
        }),
      );
    } catch (e) {
      setData([]);
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  const columns: ReportExportColumn<Row>[] = [
    { header: 'Policy', accessor: (r) => r.policy_no },
    { header: 'Bind / invoice date', accessor: (r) => r.invoice_date },
    { header: 'Description', accessor: (r) => r.description },
    {
      header: 'Fee base',
      accessor: (r) => Number(r.fee_amount),
      align: 'right',
    },
    {
      header: 'VAT treatment',
      accessor: (r) =>
        r.vat_mode === 'exclusive'
          ? `${r.vat_rate_pct}% VAT added`
          : 'VAT not calculated (not declared exempt)',
    },
    {
      header: 'VAT liability',
      accessor: (r) => Number(r.vat_amount),
      align: 'right',
    },
    {
      header: 'Line total',
      accessor: (r) => Number(r.invoice_line_total),
      align: 'right',
    },
    { header: 'Currency', accessor: (r) => r.currency },
    { header: 'Journal', accessor: (r) => r.journal_entry_id },
  ];
  return (
    <Box sx={{ p: 3 }}>
      <Typography variant="h5">Insurance broker-fee VAT supplement</Typography>
      <Alert severity="info" sx={{ my: 2 }}>
        Tenant-wide, accrual-based on bind date. Insurance policies do not carry
        an organization allocation. These rows are separate from the standard
        supplier/receivable-invoice VAT report; do not count them twice in a
        manual return. This is not a determination of Ugandan VAT treatment or
        an EFRIS submission.
      </Alert>
      {error && <Alert severity="error">{error}</Alert>}
      <Stack direction="row" spacing={1} sx={{ my: 2 }}>
        <TextField
          type="date"
          label="From"
          value={from}
          InputLabelProps={{ shrink: true }}
          onChange={(e) => setFrom(e.target.value)}
        />
        <TextField
          type="date"
          label="To"
          value={to}
          InputLabelProps={{ shrink: true }}
          onChange={(e) => setTo(e.target.value)}
        />
        <Button
          disabled={busy || Boolean(from && to && from > to)}
          onClick={() => void load()}
        >
          Run fee VAT report
        </Button>
        <Button
          disabled={!data.length}
          onClick={() =>
            exportReportToExcel(
              'insurance-fee-vat',
              'Insurance fee VAT',
              columns,
              data,
            )
          }
        >
          Export Excel
        </Button>
        <Button
          disabled={!data.length}
          onClick={() =>
            exportReportToPdf(
              'insurance-fee-vat',
              'Insurance broker-fee VAT supplement',
              columns,
              data,
            )
          }
        >
          Export PDF
        </Button>
      </Stack>
      <Box sx={{ overflowX: 'auto' }}>
        <Table size="small">
          <TableHead>
            <TableRow>
              {columns.map((c) => (
                <TableCell key={c.header}>{c.header}</TableCell>
              ))}
            </TableRow>
          </TableHead>
          <TableBody>
            {data.map((r) => (
              <TableRow key={r.charge_id}>
                {columns.map((c) => (
                  <TableCell key={c.header}>{c.accessor(r)}</TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </Box>
      {Object.entries(
        data.reduce<Record<string, number>>(
          (totals, r) => ({
            ...totals,
            [r.currency]: (totals[r.currency] || 0) + Number(r.vat_amount),
          }),
          {},
        ),
      ).map(([currency, total]) => (
        <Typography key={currency}>
          Broker-fee VAT liability: {formatMoney(total, currency)}
        </Typography>
      ))}
    </Box>
  );
}
