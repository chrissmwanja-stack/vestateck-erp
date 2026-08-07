import { useEffect, useState } from 'react';
import {
  Box,
  Button,
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

interface Organization {
  id: string;
  company_code: string;
  site_name: string;
}

interface VatRow {
  organization_id: string;
  source_type: 'supplier_invoice' | 'receivable_invoice';
  source_id: string;
  invoice_number: string;
  invoice_date: string;
  vat_amount: number;
  amount_incl_vat: number;
  currency: string;
}

const SOURCE_LABELS: Record<VatRow['source_type'], string> = {
  supplier_invoice: 'Supplier Invoice',
  receivable_invoice: 'Receivable Invoice',
};

export default function VatReport() {
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [organizationId, setOrganizationId] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState<VatRow[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    supabase
      .from('organizations')
      .select('id, company_code, site_name')
      .eq('is_active', true)
      .order('site_name')
      .then(({ data }) => setOrganizations(data ?? []));
  }, []);

  const runSearch = async () => {
    setLoading(true);
    let query = supabase
      .from('v_vat_report')
      .select('*')
      .order('invoice_date', { ascending: false });

    if (organizationId) query = query.eq('organization_id', organizationId);
    if (dateFrom) query = query.gte('invoice_date', dateFrom);
    if (dateTo) query = query.lte('invoice_date', dateTo);

    const { data, error } = await query;
    setRows(error ? [] : (data as VatRow[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    runSearch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const totalsByCurrency = rows.reduce<Record<string, { vat: number; gross: number }>>((acc, r) => {
    const key = r.currency;
    if (!acc[key]) acc[key] = { vat: 0, gross: 0 };
    acc[key].vat += Number(r.vat_amount);
    acc[key].gross += Number(r.amount_incl_vat);
    return acc;
  }, {});

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        VAT Report
      </Typography>

      <Paper sx={{ p: 2, mb: 2 }}>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap', alignItems: 'center' }}>
          <TextField
            select
            label="Organization"
            value={organizationId}
            onChange={(e) => setOrganizationId(e.target.value)}
            sx={{ minWidth: 260 }}
            size="small"
          >
            <MenuItem value="">All organizations</MenuItem>
            {organizations.map((o) => (
              <MenuItem key={o.id} value={o.id}>
                {o.company_code} — {o.site_name}
              </MenuItem>
            ))}
          </TextField>
          <TextField
            label="From"
            type="date"
            size="small"
            InputLabelProps={{ shrink: true }}
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
          />
          <TextField
            label="To"
            type="date"
            size="small"
            InputLabelProps={{ shrink: true }}
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
          />
          <Button variant="contained" onClick={runSearch} disabled={loading}>
            Search
          </Button>
          <Button
            variant="outlined"
            onClick={() => {
              setOrganizationId('');
              setDateFrom('');
              setDateTo('');
            }}
          >
            Clear
          </Button>
        </Box>
      </Paper>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Type</TableCell>
              <TableCell>Invoice No</TableCell>
              <TableCell>Date</TableCell>
              <TableCell align="right">VAT Amount</TableCell>
              <TableCell align="right">Amount (incl. VAT)</TableCell>
              <TableCell>Currency</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={`${r.source_type}-${r.source_id}`}>
                <TableCell>{SOURCE_LABELS[r.source_type]}</TableCell>
                <TableCell>{r.invoice_number}</TableCell>
                <TableCell>{r.invoice_date}</TableCell>
                <TableCell align="right">{Number(r.vat_amount).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.amount_incl_vat).toLocaleString()}</TableCell>
                <TableCell>{r.currency}</TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={6} align="center">
                  No invoices found for the selected filters.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>

      {Object.entries(totalsByCurrency).map(([ccy, t]) => (
        <Typography variant="subtitle2" key={ccy} sx={{ mt: 1 }}>
          Total VAT ({ccy}): {t.vat.toLocaleString()} &nbsp;|&nbsp; Total incl. VAT: {t.gross.toLocaleString()}
        </Typography>
      ))}
    </Box>
  );
}