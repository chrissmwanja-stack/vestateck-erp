import { useEffect, useState } from 'react';
import {
  Box,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
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

interface WhtRow {
  tenant_id: string;
  organization_id: string;
  source_id: string;
  invoice_number: string;
  invoice_date: string;
  wht_rate: number | null;
  wht_amount: number;
  amount_incl_vat: number;
  currency: string;
  net_payable: number;
  vendor_account_id: string | null;
  vendor_name: string | null;
  vendor_account_code: string | null;
  vendor_tax_id: string | null;
  remittance_due_date: string;
}

export default function WhtReport() {
  const [organizations, setOrganizations] = useState<Organization[]>([]);
  const [organizationId, setOrganizationId] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState<WhtRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [certificateRow, setCertificateRow] = useState<WhtRow | null>(null);

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
      .from('v_wht_report')
      .select('*')
      .order('invoice_date', { ascending: false });

    if (organizationId) query = query.eq('organization_id', organizationId);
    if (dateFrom) query = query.gte('invoice_date', dateFrom);
    if (dateTo) query = query.lte('invoice_date', dateTo);

    const { data, error } = await query;
    setRows(error ? [] : (data as WhtRow[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    runSearch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const totalsByCurrency = rows.reduce<Record<string, { wht: number; gross: number; net: number }>>((acc, r) => {
    const key = r.currency;
    if (!acc[key]) acc[key] = { wht: 0, gross: 0, net: 0 };
    acc[key].wht += Number(r.wht_amount);
    acc[key].gross += Number(r.amount_incl_vat);
    acc[key].net += Number(r.net_payable);
    return acc;
  }, {});

  const currentOrg = organizations.find((o) => o.id === certificateRow?.organization_id);

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        WHT Report
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
              <TableCell>Vendor</TableCell>
              <TableCell>Invoice No</TableCell>
              <TableCell>Date</TableCell>
              <TableCell align="right">WHT Rate</TableCell>
              <TableCell align="right">WHT Amount</TableCell>
              <TableCell align="right">Amount (incl. VAT)</TableCell>
              <TableCell align="right">Net Payable</TableCell>
              <TableCell>Currency</TableCell>
              <TableCell>Remittance Due</TableCell>
              <TableCell align="right">Certificate</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.source_id}>
                <TableCell>
                  {r.vendor_account_code ? `${r.vendor_account_code} — ${r.vendor_name}` : r.vendor_name ?? '—'}
                </TableCell>
                <TableCell>{r.invoice_number}</TableCell>
                <TableCell>{r.invoice_date}</TableCell>
                <TableCell align="right">{r.wht_rate != null ? `${Number(r.wht_rate).toLocaleString()}%` : '—'}</TableCell>
                <TableCell align="right">{Number(r.wht_amount).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.amount_incl_vat).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.net_payable).toLocaleString()}</TableCell>
                <TableCell>{r.currency}</TableCell>
                <TableCell>{r.remittance_due_date}</TableCell>
                <TableCell align="right">
                  <Button size="small" variant="outlined" onClick={() => setCertificateRow(r)}>
                    View
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={10} align="center">
                  No WHT-bearing invoices found for the selected filters.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>

      {Object.entries(totalsByCurrency).map(([ccy, t]) => (
        <Typography variant="subtitle2" key={ccy} sx={{ mt: 1 }}>
          Total WHT ({ccy}): {t.wht.toLocaleString()} &nbsp;|&nbsp; Total incl. VAT: {t.gross.toLocaleString()}{' '}
          &nbsp;|&nbsp; Total Net Payable: {t.net.toLocaleString()}
        </Typography>
      ))}

      <Dialog open={!!certificateRow} onClose={() => setCertificateRow(null)} maxWidth="sm" fullWidth>
        <style>
          {`
            @media print {
              body * { visibility: hidden; }
              #wht-certificate, #wht-certificate * { visibility: visible; }
              #wht-certificate { position: absolute; top: 0; left: 0; width: 100%; padding: 24px; }
              .no-print { display: none !important; }
            }
          `}
        </style>
        <DialogContent>
          {certificateRow && (
            <Box id="wht-certificate">
              <Typography variant="h6" gutterBottom>
                Withholding Tax Certificate
              </Typography>
              <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
                {currentOrg ? `${currentOrg.company_code} — ${currentOrg.site_name}` : ''}
              </Typography>

              <Table size="small">
                <TableBody>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>Vendor</TableCell>
                    <TableCell sx={{ border: 0 }}>
                      {certificateRow.vendor_account_code
                        ? `${certificateRow.vendor_account_code} — ${certificateRow.vendor_name}`
                        : certificateRow.vendor_name ?? '—'}
                    </TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>Vendor Tax ID</TableCell>
                    <TableCell sx={{ border: 0 }}>{certificateRow.vendor_tax_id ?? '—'}</TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>Invoice No</TableCell>
                    <TableCell sx={{ border: 0 }}>{certificateRow.invoice_number}</TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>Invoice Date</TableCell>
                    <TableCell sx={{ border: 0 }}>{certificateRow.invoice_date}</TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>Gross Amount</TableCell>
                    <TableCell sx={{ border: 0 }}>
                      {certificateRow.currency} {Number(certificateRow.amount_incl_vat).toLocaleString()}
                    </TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>WHT Rate</TableCell>
                    <TableCell sx={{ border: 0 }}>
                      {certificateRow.wht_rate != null ? `${Number(certificateRow.wht_rate).toLocaleString()}%` : '—'}
                    </TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>WHT Amount Withheld</TableCell>
                    <TableCell sx={{ border: 0 }}>
                      {certificateRow.currency} {Number(certificateRow.wht_amount).toLocaleString()}
                    </TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>Net Amount Paid to Vendor</TableCell>
                    <TableCell sx={{ border: 0 }}>
                      {certificateRow.currency} {Number(certificateRow.net_payable).toLocaleString()}
                    </TableCell>
                  </TableRow>
                  <TableRow>
                    <TableCell sx={{ fontWeight: 600, border: 0 }}>Remittance Due Date</TableCell>
                    <TableCell sx={{ border: 0 }}>{certificateRow.remittance_due_date}</TableCell>
                  </TableRow>
                </TableBody>
              </Table>

              <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 3 }}>
                This certificate reflects amounts recorded in the system as of the date printed. Confirm the
                applicable rate and filing requirements against current URA guidance before remittance.
              </Typography>
            </Box>
          )}
        </DialogContent>
        <DialogActions className="no-print">
          <Button onClick={() => setCertificateRow(null)}>Close</Button>
          <Button variant="contained" onClick={() => window.print()}>
            Print
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}