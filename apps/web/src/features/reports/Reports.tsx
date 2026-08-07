import { useCallback, useEffect, useMemo, useState, FormEvent } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Divider,
  Grid,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { Search as SearchIcon, Clear as ClearIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface OrganizationOption {
  id: string;
  company_code: string;
  site_name: string;
}

interface ReportFilters {
  organizationId: string;
  dateFrom: string;
  dateTo: string;
}

const emptyFilters: ReportFilters = { organizationId: '', dateFrom: '', dateTo: '' };

interface OrgBreakdownRow {
  organization_label: string;
  count: number;
  total: number;
}

interface SupplierSummary {
  count: number;
  totalInclVat: number;
  totalVat: number;
  poRelatedCount: number;
  nonPoCount: number;
  byOrg: OrgBreakdownRow[];
}

interface ReceivableSummary {
  openCount: number;
  openTotal: number;
  paidCount: number;
  paidTotal: number;
  byOrg: OrgBreakdownRow[];
}

interface CashBankSummary {
  receiptsTotal: number;
  paymentsTotal: number;
  cashTotal: number;
  bankTotal: number;
  netMovement: number;
}

interface ExpenditureSummary {
  count: number;
  total: number;
  byCostCenter: { cost_center_label: string; count: number; total: number }[];
}

interface PettyCashRow {
  float_name: string;
  currency: string;
  ceiling_amount: number;
  current_balance: number;
  is_active: boolean;
}

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function groupByOrg(rows: { amount: number; org: string }[]): OrgBreakdownRow[] {
  const agg: Record<string, { count: number; total: number }> = {};
  rows.forEach((r) => {
    if (!agg[r.org]) agg[r.org] = { count: 0, total: 0 };
    agg[r.org].count += 1;
    agg[r.org].total += r.amount;
  });
  return Object.entries(agg)
    .map(([organization_label, stats]) => ({ organization_label, count: stats.count, total: stats.total }))
    .sort((a, b) => b.total - a.total);
}

export default function FinancialReports() {
  const [organizations, setOrganizations] = useState<OrganizationOption[]>([]);
  const [loadingOrganizations, setLoadingOrganizations] = useState(false);

  const [filters, setFilters] = useState<ReportFilters>(emptyFilters);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hasRun, setHasRun] = useState(false);

  const [supplierSummary, setSupplierSummary] = useState<SupplierSummary | null>(null);
  const [receivableSummary, setReceivableSummary] = useState<ReceivableSummary | null>(null);
  const [cashBankSummary, setCashBankSummary] = useState<CashBankSummary | null>(null);
  const [expenditureSummary, setExpenditureSummary] = useState<ExpenditureSummary | null>(null);
  const [pettyCashRows, setPettyCashRows] = useState<PettyCashRow[]>([]);

  const loadOrganizations = useCallback(async () => {
    setLoadingOrganizations(true);
    try {
      const { data, error: orgError } = await supabase
        .from('organizations')
        .select('id, company_code, site_name')
        .eq('is_active', true)
        .order('company_code')
        .order('site_name');
      if (orgError) throw orgError;
      setOrganizations(data ?? []);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load organizations');
    } finally {
      setLoadingOrganizations(false);
    }
  }, []);

  useEffect(() => {
    loadOrganizations();
    // Run once on load with no filters, so the page isn't blank on first visit.
    runReport(emptyFilters);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const organizationOptions = useMemo(
    () => organizations.map((o) => ({ id: o.id, label: `${o.company_code} — ${o.site_name}` })),
    [organizations]
  );

  async function runReport(activeFilters: ReportFilters) {
    setLoading(true);
    setError(null);
    setHasRun(true);

    try {
      // ---- Supplier invoices ----
      let supplierQuery = supabase
        .from('supplier_invoices')
        .select('amount_incl_vat, vat_amount, invoice_type, invoice_date, organization:organizations!organization_id(company_code, site_name)');
      if (activeFilters.organizationId) supplierQuery = supplierQuery.eq('organization_id', activeFilters.organizationId);
      if (activeFilters.dateFrom) supplierQuery = supplierQuery.gte('invoice_date', activeFilters.dateFrom);
      if (activeFilters.dateTo) supplierQuery = supplierQuery.lte('invoice_date', activeFilters.dateTo);
      const { data: supplierRows, error: supplierErr } = await supplierQuery;
      if (supplierErr) throw supplierErr;

      const sRows = supplierRows ?? [];
      setSupplierSummary({
        count: sRows.length,
        totalInclVat: sRows.reduce((sum, r: any) => sum + Number(r.amount_incl_vat), 0),
        totalVat: sRows.reduce((sum, r: any) => sum + Number(r.vat_amount), 0),
        poRelatedCount: sRows.filter((r: any) => r.invoice_type === 'po_related').length,
        nonPoCount: sRows.filter((r: any) => r.invoice_type === 'non_po').length,
        byOrg: groupByOrg(
          sRows.map((r: any) => {
            const org = embedOne(r.organization);
            return { amount: Number(r.amount_incl_vat), org: org ? `${org.company_code} — ${org.site_name}` : 'Unassigned' };
          })
        ),
      });

      // ---- Receivable invoices ----
      let receivableQuery = supabase
        .from('receivable_invoices')
        .select('amount_incl_vat, status, invoice_date, organization:organizations!organization_id(company_code, site_name)');
      if (activeFilters.organizationId) receivableQuery = receivableQuery.eq('organization_id', activeFilters.organizationId);
      if (activeFilters.dateFrom) receivableQuery = receivableQuery.gte('invoice_date', activeFilters.dateFrom);
      if (activeFilters.dateTo) receivableQuery = receivableQuery.lte('invoice_date', activeFilters.dateTo);
      const { data: receivableRows, error: receivableErr } = await receivableQuery;
      if (receivableErr) throw receivableErr;

      const rRows = receivableRows ?? [];
      const openRows = rRows.filter((r: any) => r.status === 'open');
      const paidRows = rRows.filter((r: any) => r.status === 'paid');
      setReceivableSummary({
        openCount: openRows.length,
        openTotal: openRows.reduce((sum, r: any) => sum + Number(r.amount_incl_vat), 0),
        paidCount: paidRows.length,
        paidTotal: paidRows.reduce((sum, r: any) => sum + Number(r.amount_incl_vat), 0),
        byOrg: groupByOrg(
          rRows.map((r: any) => {
            const org = embedOne(r.organization);
            return { amount: Number(r.amount_incl_vat), org: org ? `${org.company_code} — ${org.site_name}` : 'Unassigned' };
          })
        ),
      });

      // ---- Cash & bank transactions (org filter doesn't apply -- these
      // aren't org-scoped in the schema, only date-scoped here) ----
      let cashBankQuery = supabase.from('cash_bank_transactions').select('transaction_type, payment_method, amount, transaction_date');
      if (activeFilters.dateFrom) cashBankQuery = cashBankQuery.gte('transaction_date', activeFilters.dateFrom);
      if (activeFilters.dateTo) cashBankQuery = cashBankQuery.lte('transaction_date', activeFilters.dateTo);
      const { data: cbRows, error: cbErr } = await cashBankQuery;
      if (cbErr) throw cbErr;

      const cRows = cbRows ?? [];
      const receiptsTotal = cRows.filter((r: any) => r.transaction_type === 'receipt').reduce((sum, r: any) => sum + Number(r.amount), 0);
      const paymentsTotal = cRows.filter((r: any) => r.transaction_type === 'payment').reduce((sum, r: any) => sum + Number(r.amount), 0);
      const cashTotal = cRows.filter((r: any) => r.payment_method === 'cash').reduce((sum, r: any) => sum + Number(r.amount), 0);
      const bankTotal = cRows.filter((r: any) => r.payment_method === 'bank').reduce((sum, r: any) => sum + Number(r.amount), 0);
      setCashBankSummary({
        receiptsTotal,
        paymentsTotal,
        cashTotal,
        bankTotal,
        netMovement: receiptsTotal - paymentsTotal,
      });

      // ---- Expenditure slips (org filter doesn't apply -- slips are
      // cost-center-scoped, not organization-scoped, in the current schema) ----
      let expenditureQuery = supabase
        .from('expenditure_slips')
        .select('amount, slip_date, cost_centers(name, project_code)');
      if (activeFilters.dateFrom) expenditureQuery = expenditureQuery.gte('slip_date', activeFilters.dateFrom);
      if (activeFilters.dateTo) expenditureQuery = expenditureQuery.lte('slip_date', activeFilters.dateTo);
      const { data: expRows, error: expErr } = await expenditureQuery;
      if (expErr) throw expErr;

      const eRows = expRows ?? [];
      const ccAgg: Record<string, { count: number; total: number }> = {};
      eRows.forEach((r: any) => {
        const cc = embedOne(r.cost_centers);
        const label = cc ? `${cc.project_code ?? ''} ${cc.name}`.trim() : 'Unassigned';
        if (!ccAgg[label]) ccAgg[label] = { count: 0, total: 0 };
        ccAgg[label].count += 1;
        ccAgg[label].total += Number(r.amount);
      });
      setExpenditureSummary({
        count: eRows.length,
        total: eRows.reduce((sum, r: any) => sum + Number(r.amount), 0),
        byCostCenter: Object.entries(ccAgg)
          .map(([cost_center_label, stats]) => ({ cost_center_label, count: stats.count, total: stats.total }))
          .sort((a, b) => b.total - a.total),
      });

      // ---- Petty cash floats -- a live snapshot, not date-filtered ----
      const { data: pcRows, error: pcErr } = await supabase
        .from('petty_cash_float_balances')
        .select('float_name, currency, ceiling_amount, current_balance, is_active')
        .order('float_name');
      if (pcErr) throw pcErr;
      setPettyCashRows((pcRows ?? []) as PettyCashRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to build the report');
    } finally {
      setLoading(false);
    }
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    runReport(filters);
  }

  function handleClear() {
    setFilters(emptyFilters);
    runReport(emptyFilters);
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 2 }}>
        Financial Reports
      </Typography>

      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Box component="form" onSubmit={handleSubmit}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap">
            <Autocomplete
              options={organizationOptions}
              loading={loadingOrganizations}
              sx={{ flex: 1, minWidth: 240 }}
              onChange={(_, option) => setFilters((f) => ({ ...f, organizationId: option?.id ?? '' }))}
              value={organizationOptions.find((o) => o.id === filters.organizationId) ?? null}
              isOptionEqualToValue={(option, value) => option.id === value.id}
              renderInput={(params) => (
                <TextField
                  {...params}
                  label="Organization (invoices only)"
                  size="small"
                  InputProps={{
                    ...params.InputProps,
                    endAdornment: (
                      <>
                        {loadingOrganizations ? <CircularProgress color="inherit" size={16} /> : null}
                        {params.InputProps.endAdornment}
                      </>
                    ),
                  }}
                />
              )}
            />
            <TextField
              label="Date From"
              type="date"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              InputLabelProps={{ shrink: true }}
              value={filters.dateFrom}
              onChange={(e) => setFilters((f) => ({ ...f, dateFrom: e.target.value }))}
            />
            <TextField
              label="Date To"
              type="date"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              InputLabelProps={{ shrink: true }}
              value={filters.dateTo}
              onChange={(e) => setFilters((f) => ({ ...f, dateTo: e.target.value }))}
            />
          </Stack>
          <Stack direction="row" spacing={1} sx={{ mt: 2 }}>
            <Button type="submit" variant="contained" startIcon={<SearchIcon />} disabled={loading}>
              {loading ? 'Running…' : 'Run Report'}
            </Button>
            <Button variant="outlined" startIcon={<ClearIcon />} onClick={handleClear} disabled={loading}>
              Clear
            </Button>
          </Stack>
        </Box>
      </Paper>

      {error && (
        <Alert severity="error" sx={{ mb: 3 }}>
          {error}
        </Alert>
      )}

      {hasRun && !error && (
        <Stack spacing={3}>
          <Grid container spacing={3}>
            {/* Supplier invoices */}
            <Grid item xs={12} md={6}>
              <Card variant="outlined" sx={{ height: '100%' }}>
                <CardContent>
                  <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                    Supplier Invoices
                  </Typography>
                  {supplierSummary && (
                    <>
                      <Stack direction="row" spacing={1} sx={{ mb: 2 }} flexWrap="wrap">
                        <Chip label={`${supplierSummary.count} invoices`} />
                        <Chip label={`${supplierSummary.totalInclVat.toLocaleString()} total incl. VAT`} />
                        <Chip variant="outlined" label={`${supplierSummary.totalVat.toLocaleString()} VAT`} />
                        <Chip variant="outlined" label={`${supplierSummary.poRelatedCount} PO-related`} />
                        <Chip variant="outlined" label={`${supplierSummary.nonPoCount} non-PO`} />
                      </Stack>
                      <Divider sx={{ mb: 1 }} />
                      <TableContainer sx={{ maxHeight: 260 }}>
                        <Table size="small">
                          <TableHead>
                            <TableRow>
                              <TableCell>Organization</TableCell>
                              <TableCell align="right">Count</TableCell>
                              <TableCell align="right">Total</TableCell>
                            </TableRow>
                          </TableHead>
                          <TableBody>
                            {supplierSummary.byOrg.map((row) => (
                              <TableRow key={row.organization_label}>
                                <TableCell>{row.organization_label}</TableCell>
                                <TableCell align="right">{row.count}</TableCell>
                                <TableCell align="right">{row.total.toLocaleString()}</TableCell>
                              </TableRow>
                            ))}
                            {supplierSummary.byOrg.length === 0 && (
                              <TableRow>
                                <TableCell colSpan={3} align="center" sx={{ color: 'text.secondary' }}>
                                  No supplier invoices in this period.
                                </TableCell>
                              </TableRow>
                            )}
                          </TableBody>
                        </Table>
                      </TableContainer>
                    </>
                  )}
                </CardContent>
              </Card>
            </Grid>

            {/* Receivable invoices */}
            <Grid item xs={12} md={6}>
              <Card variant="outlined" sx={{ height: '100%' }}>
                <CardContent>
                  <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                    Receivable Invoices
                  </Typography>
                  {receivableSummary && (
                    <>
                      <Stack direction="row" spacing={1} sx={{ mb: 2 }} flexWrap="wrap">
                        <Chip
                          color="warning"
                          label={`${receivableSummary.openCount} open — ${receivableSummary.openTotal.toLocaleString()}`}
                        />
                        <Chip
                          color="success"
                          label={`${receivableSummary.paidCount} paid — ${receivableSummary.paidTotal.toLocaleString()}`}
                        />
                      </Stack>
                      <Divider sx={{ mb: 1 }} />
                      <TableContainer sx={{ maxHeight: 260 }}>
                        <Table size="small">
                          <TableHead>
                            <TableRow>
                              <TableCell>Organization</TableCell>
                              <TableCell align="right">Count</TableCell>
                              <TableCell align="right">Total</TableCell>
                            </TableRow>
                          </TableHead>
                          <TableBody>
                            {receivableSummary.byOrg.map((row) => (
                              <TableRow key={row.organization_label}>
                                <TableCell>{row.organization_label}</TableCell>
                                <TableCell align="right">{row.count}</TableCell>
                                <TableCell align="right">{row.total.toLocaleString()}</TableCell>
                              </TableRow>
                            ))}
                            {receivableSummary.byOrg.length === 0 && (
                              <TableRow>
                                <TableCell colSpan={3} align="center" sx={{ color: 'text.secondary' }}>
                                  No receivable invoices in this period.
                                </TableCell>
                              </TableRow>
                            )}
                          </TableBody>
                        </Table>
                      </TableContainer>
                    </>
                  )}
                </CardContent>
              </Card>
            </Grid>

            {/* Cash & bank */}
            <Grid item xs={12} md={6}>
              <Card variant="outlined" sx={{ height: '100%' }}>
                <CardContent>
                  <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                    Cash and Bank Movement
                  </Typography>
                  {cashBankSummary && (
                    <Stack spacing={1}>
                      <Stack direction="row" spacing={1} flexWrap="wrap">
                        <Chip color="success" label={`Receipts: ${cashBankSummary.receiptsTotal.toLocaleString()}`} />
                        <Chip color="default" label={`Payments: ${cashBankSummary.paymentsTotal.toLocaleString()}`} />
                        <Chip
                          color={cashBankSummary.netMovement >= 0 ? 'success' : 'error'}
                          label={`Net: ${cashBankSummary.netMovement.toLocaleString()}`}
                        />
                      </Stack>
                      <Divider />
                      <Stack direction="row" spacing={1} flexWrap="wrap">
                        <Chip variant="outlined" label={`Cash: ${cashBankSummary.cashTotal.toLocaleString()}`} />
                        <Chip variant="outlined" label={`Bank: ${cashBankSummary.bankTotal.toLocaleString()}`} />
                      </Stack>
                      <Typography variant="caption" color="text.secondary">
                        Not organization-scoped — cash and bank transactions aren't currently tied to an organization in the schema.
                      </Typography>
                    </Stack>
                  )}
                </CardContent>
              </Card>
            </Grid>

            {/* Expenditure slips */}
            <Grid item xs={12} md={6}>
              <Card variant="outlined" sx={{ height: '100%' }}>
                <CardContent>
                  <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                    Expenditure Slips
                  </Typography>
                  {expenditureSummary && (
                    <>
                      <Stack direction="row" spacing={1} sx={{ mb: 2 }}>
                        <Chip label={`${expenditureSummary.count} slips`} />
                        <Chip label={`${expenditureSummary.total.toLocaleString()} total`} />
                      </Stack>
                      <Divider sx={{ mb: 1 }} />
                      <TableContainer sx={{ maxHeight: 260 }}>
                        <Table size="small">
                          <TableHead>
                            <TableRow>
                              <TableCell>Cost Center</TableCell>
                              <TableCell align="right">Count</TableCell>
                              <TableCell align="right">Total</TableCell>
                            </TableRow>
                          </TableHead>
                          <TableBody>
                            {expenditureSummary.byCostCenter.map((row) => (
                              <TableRow key={row.cost_center_label}>
                                <TableCell>{row.cost_center_label}</TableCell>
                                <TableCell align="right">{row.count}</TableCell>
                                <TableCell align="right">{row.total.toLocaleString()}</TableCell>
                              </TableRow>
                            ))}
                            {expenditureSummary.byCostCenter.length === 0 && (
                              <TableRow>
                                <TableCell colSpan={3} align="center" sx={{ color: 'text.secondary' }}>
                                  No expenditure slips in this period.
                                </TableCell>
                              </TableRow>
                            )}
                          </TableBody>
                        </Table>
                      </TableContainer>
                    </>
                  )}
                </CardContent>
              </Card>
            </Grid>
          </Grid>

          {/* Petty cash floats -- always current, not date filtered */}
          <Card variant="outlined">
            <CardContent>
              <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                Petty Cash Floats (current snapshot)
              </Typography>
              <TableContainer>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>Float</TableCell>
                      <TableCell align="right">Ceiling</TableCell>
                      <TableCell align="right">Current Balance</TableCell>
                      <TableCell>Status</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {pettyCashRows.map((row) => {
                      const low = row.current_balance < row.ceiling_amount * 0.2;
                      return (
                        <TableRow key={row.float_name} hover>
                          <TableCell>{row.float_name}</TableCell>
                          <TableCell align="right">
                            {row.ceiling_amount.toLocaleString()} {row.currency}
                          </TableCell>
                          <TableCell align="right">
                            <Chip
                              size="small"
                              label={`${row.current_balance.toLocaleString()} ${row.currency}`}
                              color={low ? 'warning' : 'default'}
                            />
                          </TableCell>
                          <TableCell>
                            <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                          </TableCell>
                        </TableRow>
                      );
                    })}
                    {pettyCashRows.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary' }}>
                          No petty cash floats set up yet.
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </TableContainer>
            </CardContent>
          </Card>
        </Stack>
      )}
    </Box>
  );
}