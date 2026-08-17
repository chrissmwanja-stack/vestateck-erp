import { useCallback, useMemo, useRef, useState, ChangeEvent } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Divider,
  MenuItem,
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
import {
  UploadFile as UploadFileIcon,
  Download as DownloadIcon,
  PlayArrow as PlayArrowIcon,
  RestartAlt as RestartAltIcon,
} from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

type RecordType = 'expenditure_slip' | 'supplier_invoice' | 'receivable_invoice';

interface ColumnDef {
  key: string;
  label: string;
  required: boolean;
  hint?: string;
}

// Column sets per target. Required-ness here is the app's own validation
// layer, not always a DB constraint -- e.g. vendor_account_code isn't
// NOT NULL in the database, but every other entry path for supplier
// invoices treats it as required, so the bulk path holds to the same bar.
const COLUMN_DEFS: Record<RecordType, ColumnDef[]> = {
  expenditure_slip: [
    { key: 'organization_code', label: 'Organization Code', required: false, hint: 'Organization\'s company code (optional)' },
    { key: 'cost_center_code', label: 'Cost Center Code', required: true, hint: 'Cost center\'s project code' },
    { key: 'slip_number', label: 'Slip Number', required: true },
    { key: 'slip_date', label: 'Slip Date', required: true, hint: 'YYYY-MM-DD' },
    { key: 'payee_name', label: 'Payee Name', required: true },
    { key: 'purpose', label: 'Purpose', required: true },
    { key: 'amount', label: 'Amount', required: true },
    { key: 'currency', label: 'Currency', required: false, hint: 'Defaults to UGX' },
    { key: 'petty_cash_float_name', label: 'Petty Cash Float Name', required: false, hint: 'Must belong to the cost center above' },
  ],
  supplier_invoice: [
    { key: 'organization_code', label: 'Organization Code', required: true },
    { key: 'vendor_account_code', label: 'Vendor Account Code', required: true },
    { key: 'po_number', label: 'PO Number', required: false, hint: 'Required if Cost Center Code is blank' },
    { key: 'cost_center_code', label: 'Cost Center Code', required: false, hint: 'Required if PO Number is blank' },
    { key: 'invoice_number', label: 'Invoice Number', required: true },
    { key: 'invoice_date', label: 'Invoice Date', required: true, hint: 'YYYY-MM-DD' },
    { key: 'due_date', label: 'Due Date', required: false, hint: 'YYYY-MM-DD' },
    { key: 'amount_incl_vat', label: 'Amount (incl. VAT)', required: true },
    { key: 'vat_amount', label: 'VAT Amount', required: false, hint: 'Defaults to 0' },
    { key: 'currency', label: 'Currency', required: false, hint: 'Defaults to UGX' },
    { key: 'description', label: 'Description', required: false },
  ],
  receivable_invoice: [
    { key: 'organization_code', label: 'Organization Code', required: true },
    { key: 'client_account_code', label: 'Client Account Code', required: true },
    { key: 'cost_center_code', label: 'Cost Center Code', required: false },
    { key: 'invoice_number', label: 'Invoice Number', required: true },
    { key: 'invoice_date', label: 'Invoice Date', required: true, hint: 'YYYY-MM-DD' },
    { key: 'due_date', label: 'Due Date', required: false, hint: 'YYYY-MM-DD' },
    { key: 'amount_incl_vat', label: 'Amount (incl. VAT)', required: true },
    { key: 'vat_amount', label: 'VAT Amount', required: false, hint: 'Defaults to 0' },
    { key: 'currency', label: 'Currency', required: false, hint: 'Defaults to UGX' },
    { key: 'description', label: 'Description', required: false },
  ],
};

type MassSlipTableName = 'expenditure_slips' | 'supplier_invoices' | 'receivable_invoices';

const RECORD_TYPE_META: Record<RecordType, { table: MassSlipTableName; label: string; numberField: string }> = {
  expenditure_slip: { table: 'expenditure_slips', label: 'Expenditure Slips', numberField: 'slip_number' },
  supplier_invoice: { table: 'supplier_invoices', label: 'Supplier Invoices', numberField: 'invoice_number' },
  receivable_invoice: { table: 'receivable_invoices', label: 'Receivable Invoices', numberField: 'invoice_number' },
};

interface LookupOption {
  id: string;
  code: string; // normalized (uppercased) matching key
}

interface Lookups {
  organizations: LookupOption[];
  costCenters: LookupOption[];
  vendorAccounts: LookupOption[];
  clientAccounts: LookupOption[];
  openPOs: LookupOption[];
  pettyCashFloats: { id: string; name: string; cost_center_id: string }[];
  existingNumbers: Set<string>;
}

interface PreviewRow {
  index: number; // 1-based, matches CSV line (excluding header)
  raw: Record<string, string>;
  insertPayload: Record<string, unknown> | null;
  errors: string[];
  warnings: string[];
}

interface CommitResult {
  index: number;
  success: boolean;
  message: string;
}

type Phase = 'setup' | 'preview' | 'committing' | 'done';

function normalizeCode(s: string) {
  return s.trim().toUpperCase();
}

function isValidDate(s: string) {
  return /^\d{4}-\d{2}-\d{2}$/.test(s.trim());
}

function parseAmount(s: string): number | null {
  const n = Number(s.trim());
  return Number.isFinite(n) ? n : null;
}

// Minimal CSV parser: handles quoted fields, embedded commas, and escaped
// ("") quotes. Good enough for the flat, single-line-per-record exports
// this screen expects -- not a full RFC 4180 implementation.
function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ',') {
      row.push(field);
      field = '';
    } else if (c === '\n') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else if (c === '\r') {
      // skip, \n handles the line break
    } else {
      field += c;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((r) => r.some((cell) => cell.trim() !== ''));
}

function downloadCsvTemplate(recordType: RecordType) {
  const cols = COLUMN_DEFS[recordType];
  const header = cols.map((c) => c.key).join(',');
  const example = cols
    .map((c) => {
      if (c.key.includes('date')) return '2026-08-01';
      if (c.key.includes('amount')) return '100000';
      if (c.key === 'currency') return 'UGX';
      return `SAMPLE_${c.key.toUpperCase()}`;
    })
    .join(',');
  const blob = new Blob([`${header}\n${example}\n`], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${recordType}_template.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

export default function MassSlip() {
  const [recordType, setRecordType] = useState<RecordType>('expenditure_slip');
  const [phase, setPhase] = useState<Phase>('setup');
  const [fileName, setFileName] = useState<string | null>(null);
  const [loadingLookups, setLoadingLookups] = useState(false);
  const [lookupError, setLookupError] = useState<string | null>(null);
  const [preview, setPreview] = useState<PreviewRow[]>([]);
  const [commitResults, setCommitResults] = useState<CommitResult[]>([]);
  const fileInputRef = useRef<HTMLInputElement>(null);

  function reset() {
    setPhase('setup');
    setFileName(null);
    setPreview([]);
    setCommitResults([]);
    setLookupError(null);
    if (fileInputRef.current) fileInputRef.current.value = '';
  }

  function handleRecordTypeChange(next: RecordType) {
    setRecordType(next);
    reset();
  }

  const loadLookups = useCallback(async (type: RecordType): Promise<Lookups | null> => {
    setLoadingLookups(true);
    setLookupError(null);
    try {
      const meta = RECORD_TYPE_META[type];

      const [orgRes, ccRes, existingRes] = await Promise.all([
        supabase.from('organizations').select('id, company_code').eq('is_active', true),
        supabase.from('cost_centers').select('id, project_code'),
        // NOTE: only checks the first batch Supabase returns (default page
        // size) -- fine as a soft duplicate hint, not an exhaustive check.
        supabase.from(meta.table).select(meta.numberField),
      ]);
      if (orgRes.error) throw orgRes.error;
      if (ccRes.error) throw ccRes.error;
      if (existingRes.error) throw existingRes.error;

      const organizations: LookupOption[] = (orgRes.data ?? [])
        .filter((o: any) => o.company_code)
        .map((o: any) => ({ id: o.id, code: normalizeCode(o.company_code) }));
      const costCenters: LookupOption[] = (ccRes.data ?? [])
        .filter((c: any) => c.project_code)
        .map((c: any) => ({ id: c.id, code: normalizeCode(c.project_code) }));
      const existingNumbers = new Set(
        (existingRes.data ?? []).map((r: any) => normalizeCode(String(r[meta.numberField] ?? '')))
      );

      let vendorAccounts: LookupOption[] = [];
      let clientAccounts: LookupOption[] = [];
      let openPOs: LookupOption[] = [];
      let pettyCashFloats: Lookups['pettyCashFloats'] = [];

      if (type === 'supplier_invoice') {
        const { data, error } = await supabase
          .from('accounts')
          .select('id, account_code')
          .eq('is_active', true)
          .in('account_type', ['vendor', 'both']);
        if (error) throw error;
        vendorAccounts = (data ?? []).map((a: any) => ({ id: a.id, code: normalizeCode(a.account_code) }));

        const [invoicedRes, poRes] = await Promise.all([
          supabase.from('supplier_invoices').select('purchase_order_id'),
          supabase.from('purchase_orders').select('id, po_number'),
        ]);
        if (invoicedRes.error) throw invoicedRes.error;
        if (poRes.error) throw poRes.error;
        const invoicedIds = new Set((invoicedRes.data ?? []).map((r: any) => r.purchase_order_id));
        openPOs = (poRes.data ?? [])
          .filter((po: any) => !invoicedIds.has(po.id))
          .map((po: any) => ({ id: po.id, code: normalizeCode(po.po_number) }));
      }

      if (type === 'receivable_invoice') {
        const { data, error } = await supabase
          .from('accounts')
          .select('id, account_code')
          .eq('is_active', true)
          .in('account_type', ['client', 'both']);
        if (error) throw error;
        clientAccounts = (data ?? []).map((a: any) => ({ id: a.id, code: normalizeCode(a.account_code) }));
      }

      if (type === 'expenditure_slip') {
        const { data, error } = await supabase
          .from('petty_cash_floats')
          .select('id, float_name, cost_center_id')
          .eq('is_active', true);
        if (error) throw error;
        pettyCashFloats = (data ?? []).map((f: any) => ({
          id: f.id,
          name: normalizeCode(f.float_name),
          cost_center_id: f.cost_center_id,
        }));
      }

      return { organizations, costCenters, vendorAccounts, clientAccounts, openPOs, pettyCashFloats, existingNumbers };
    } catch (e) {
      setLookupError(e instanceof Error ? e.message : 'Failed to load reference data for validation');
      return null;
    } finally {
      setLoadingLookups(false);
    }
  }, []);

  function resolveRow(type: RecordType, raw: Record<string, string>, lookups: Lookups): PreviewRow['insertPayload'] extends never ? never : { insertPayload: Record<string, unknown> | null; errors: string[]; warnings: string[] } {
    const errors: string[] = [];
    const warnings: string[] = [];
    const get = (key: string) => (raw[key] ?? '').trim();

    const orgCode = get('organization_code');
    let organizationId: string | null = null;
    if (orgCode) {
      const match = lookups.organizations.find((o) => o.code === normalizeCode(orgCode));
      if (!match) errors.push(`Organization code "${orgCode}" not found`);
      else organizationId = match.id;
    } else if (type !== 'expenditure_slip') {
      errors.push('Organization Code is required');
    }

    const ccCode = get('cost_center_code');
    let costCenterId: string | null = null;
    if (ccCode) {
      const match = lookups.costCenters.find((c) => c.code === normalizeCode(ccCode));
      if (!match) errors.push(`Cost center code "${ccCode}" not found`);
      else costCenterId = match.id;
    }

    if (type === 'expenditure_slip') {
      if (!ccCode) errors.push('Cost Center Code is required');

      const slipNumber = get('slip_number');
      if (!slipNumber) errors.push('Slip Number is required');

      const slipDate = get('slip_date');
      if (!slipDate) errors.push('Slip Date is required');
      else if (!isValidDate(slipDate)) errors.push(`Slip Date "${slipDate}" must be YYYY-MM-DD`);

      const payeeName = get('payee_name');
      if (!payeeName) errors.push('Payee Name is required');

      const purpose = get('purpose');
      if (!purpose) errors.push('Purpose is required');

      const amountRaw = get('amount');
      const amount = amountRaw ? parseAmount(amountRaw) : null;
      if (!amountRaw) errors.push('Amount is required');
      else if (amount === null || amount <= 0) errors.push(`Amount "${amountRaw}" must be a positive number`);

      const currency = get('currency') || 'UGX';

      let pettyCashFloatId: string | null = null;
      const floatName = get('petty_cash_float_name');
      if (floatName && costCenterId) {
        const match = lookups.pettyCashFloats.find(
          (f) => f.name === normalizeCode(floatName) && f.cost_center_id === costCenterId
        );
        if (!match) errors.push(`Petty cash float "${floatName}" not found for cost center "${ccCode}"`);
        else pettyCashFloatId = match.id;
      } else if (floatName && !costCenterId) {
        errors.push('Cannot resolve Petty Cash Float Name without a valid Cost Center Code');
      }

      if (slipNumber && lookups.existingNumbers.has(normalizeCode(slipNumber))) {
        warnings.push(`Slip number "${slipNumber}" already exists in the system`);
      }

      if (errors.length > 0) return { insertPayload: null, errors, warnings };
      return {
        insertPayload: {
          cost_center_id: costCenterId,
          organization_id: organizationId,
          slip_number: slipNumber,
          slip_date: slipDate,
          payee_name: payeeName,
          purpose,
          amount,
          currency,
          petty_cash_float_id: pettyCashFloatId,
        },
        errors,
        warnings,
      } as any;
    }

    // Shared logic for supplier_invoice / receivable_invoice
    const invoiceNumber = get('invoice_number');
    if (!invoiceNumber) errors.push('Invoice Number is required');

    const invoiceDate = get('invoice_date');
    if (!invoiceDate) errors.push('Invoice Date is required');
    else if (!isValidDate(invoiceDate)) errors.push(`Invoice Date "${invoiceDate}" must be YYYY-MM-DD`);

    const dueDate = get('due_date');
    if (dueDate && !isValidDate(dueDate)) errors.push(`Due Date "${dueDate}" must be YYYY-MM-DD`);

    const amountRaw = get('amount_incl_vat');
    const amount = amountRaw ? parseAmount(amountRaw) : null;
    if (!amountRaw) errors.push('Amount (incl. VAT) is required');
    else if (amount === null || amount <= 0) errors.push(`Amount (incl. VAT) "${amountRaw}" must be a positive number`);

    const vatRaw = get('vat_amount');
    const vatAmount = vatRaw ? parseAmount(vatRaw) : 0;
    if (vatRaw && (vatAmount === null || vatAmount < 0)) errors.push(`VAT Amount "${vatRaw}" must be a non-negative number`);

    const currency = get('currency') || 'UGX';
    const description = get('description') || null;

    if (invoiceNumber && lookups.existingNumbers.has(normalizeCode(invoiceNumber))) {
      warnings.push(`Invoice number "${invoiceNumber}" already exists in the system`);
    }

    if (type === 'supplier_invoice') {
      const vendorCode = get('vendor_account_code');
      let vendorAccountId: string | null = null;
      if (!vendorCode) errors.push('Vendor Account Code is required');
      else {
        const match = lookups.vendorAccounts.find((a) => a.code === normalizeCode(vendorCode));
        if (!match) errors.push(`Vendor account code "${vendorCode}" not found (or not a vendor account)`);
        else vendorAccountId = match.id;
      }

      const poCode = get('po_number');
      let purchaseOrderId: string | null = null;
      if (poCode) {
        const match = lookups.openPOs.find((p) => p.code === normalizeCode(poCode));
        if (!match) errors.push(`PO "${poCode}" not found, or is already fully invoiced`);
        else purchaseOrderId = match.id;
      }

      if (!poCode && !ccCode) {
        errors.push('Either PO Number or Cost Center Code is required');
      }

      if (errors.length > 0) return { insertPayload: null, errors, warnings };
      return {
        insertPayload: {
          organization_id: organizationId,
          vendor_account_id: vendorAccountId,
          purchase_order_id: purchaseOrderId,
          cost_center_id: costCenterId,
          invoice_number: invoiceNumber,
          invoice_date: invoiceDate,
          due_date: dueDate || null,
          amount_incl_vat: amount,
          vat_amount: vatAmount ?? 0,
          currency,
          description,
        },
        errors,
        warnings,
      } as any;
    }

    // receivable_invoice
    const clientCode = get('client_account_code');
    let clientAccountId: string | null = null;
    if (!clientCode) errors.push('Client Account Code is required');
    else {
      const match = lookups.clientAccounts.find((a) => a.code === normalizeCode(clientCode));
      if (!match) errors.push(`Client account code "${clientCode}" not found (or not a client account)`);
      else clientAccountId = match.id;
    }

    if (errors.length > 0) return { insertPayload: null, errors, warnings };
    return {
      insertPayload: {
        organization_id: organizationId,
        client_account_id: clientAccountId,
        cost_center_id: costCenterId,
        invoice_number: invoiceNumber,
        invoice_date: invoiceDate,
        due_date: dueDate || null,
        amount_incl_vat: amount,
        vat_amount: vatAmount ?? 0,
        currency,
        description,
      },
      errors,
      warnings,
    } as any;
  }

  async function handleFileChange(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setFileName(file.name);

    const text = await file.text();
    const rows = parseCsv(text);
    if (rows.length < 2) {
      setLookupError('The CSV needs a header row plus at least one data row.');
      return;
    }

    const headers = rows[0].map((h) => h.trim().toLowerCase());
    const dataRows = rows.slice(1);

    const lookups = await loadLookups(recordType);
    if (!lookups) return;

    const missingRequired = COLUMN_DEFS[recordType]
      .filter((c) => c.required && !headers.includes(c.key))
      .map((c) => c.key);
    if (missingRequired.length > 0) {
      setLookupError(`CSV is missing required column(s): ${missingRequired.join(', ')}`);
      return;
    }

    const rowsPreview: PreviewRow[] = dataRows.map((cols, i) => {
      const raw: Record<string, string> = {};
      headers.forEach((h, colIdx) => {
        raw[h] = cols[colIdx] ?? '';
      });
      const { insertPayload, errors, warnings } = resolveRow(recordType, raw, lookups);
      return { index: i + 1, raw, insertPayload, errors, warnings };
    });

    setPreview(rowsPreview);
    setPhase('preview');
  }

  const validCount = useMemo(() => preview.filter((r) => r.errors.length === 0).length, [preview]);
  const errorCount = preview.length - validCount;

  async function handleCommit() {
    setPhase('committing');
    const meta = RECORD_TYPE_META[recordType];
    const results: CommitResult[] = [];

    // tenant_id isn't set by resolveRow (it doesn't have access to the
    // session). expenditure_slips fills it via a DB trigger regardless,
    // but supplier_invoices and receivable_invoices have no such trigger
    // and would otherwise fail NOT NULL on every imported row.
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data: profile, error: profileError } = await supabase
      .from('app_users')
      .select('tenant_id')
      .eq('id', user?.id ?? '')
      .single();
    if (profileError || !profile) {
      setPhase('preview');
      return;
    }

    // Inserted one row at a time, not batched -- both invoice tables
    // auto-generate prf_oif_number from a per-organization sequence on
    // insert, and this keeps failures attributable to the exact row that
    // caused them instead of failing an entire batch together.
    for (const row of preview) {
      if (row.errors.length > 0 || !row.insertPayload) continue;
      const { error } = await supabase
        .from(meta.table)
        .insert({ ...row.insertPayload, tenant_id: profile.tenant_id } as never);
      results.push({
        index: row.index,
        success: !error,
        message: error ? error.message : 'Imported',
      });
    }

    setCommitResults(results);
    setPhase('done');
  }

  const meta = RECORD_TYPE_META[recordType];
  const columns = COLUMN_DEFS[recordType];

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Mass Slip — Bulk Upload</Typography>
        {phase !== 'setup' && (
          <Button variant="outlined" startIcon={<RestartAltIcon />} onClick={reset}>
            Start Over
          </Button>
        )}
      </Stack>

      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Stack spacing={2.5}>
          <TextField
            select
            label="What are you importing?"
            sx={{ maxWidth: 360 }}
            value={recordType}
            disabled={phase !== 'setup'}
            onChange={(e) => handleRecordTypeChange(e.target.value as RecordType)}
          >
            <MenuItem value="expenditure_slip">Expenditure Slips</MenuItem>
            <MenuItem value="supplier_invoice">Supplier Invoices</MenuItem>
            <MenuItem value="receivable_invoice">Receivable Invoices</MenuItem>
          </TextField>

          <Box>
            <Typography variant="subtitle2" sx={{ fontWeight: 600, mb: 1 }}>
              Required columns for {meta.label}
            </Typography>
            <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
              {columns.map((c) => (
                <Chip
                  key={c.key}
                  size="small"
                  label={c.label}
                  color={c.required ? 'primary' : 'default'}
                  variant={c.required ? 'filled' : 'outlined'}
                  title={c.hint}
                />
              ))}
            </Stack>
            <Typography variant="caption" color="text.secondary" sx={{ mt: 1, display: 'block' }}>
              Bold/filled chips are required. Dates must be YYYY-MM-DD. Hover a chip for details.
            </Typography>
          </Box>

          <Stack direction="row" spacing={2}>
            <Button
              variant="outlined"
              startIcon={<DownloadIcon />}
              onClick={() => downloadCsvTemplate(recordType)}
            >
              Download Template
            </Button>
            <Button
              variant="contained"
              component="label"
              startIcon={loadingLookups ? <CircularProgress size={16} color="inherit" /> : <UploadFileIcon />}
              disabled={phase !== 'setup' || loadingLookups}
            >
              {loadingLookups ? 'Loading reference data…' : 'Upload CSV'}
              <input
                ref={fileInputRef}
                type="file"
                accept=".csv,text/csv"
                hidden
                onChange={handleFileChange}
              />
            </Button>
            {fileName && (
              <Typography variant="body2" sx={{ alignSelf: 'center', color: 'text.secondary' }}>
                {fileName}
              </Typography>
            )}
          </Stack>

          {lookupError && <Alert severity="error">{lookupError}</Alert>}
        </Stack>
      </Paper>

      {(phase === 'preview' || phase === 'committing' || phase === 'done') && (
        <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
          <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
              {phase === 'done' ? 'Import Results' : 'Preview'} — {preview.length} row(s) parsed
            </Typography>
            <Stack direction="row" spacing={1}>
              <Chip size="small" color="success" label={`${validCount} ready`} />
              {errorCount > 0 && <Chip size="small" color="error" label={`${errorCount} with errors`} />}
            </Stack>
          </Stack>

          {phase === 'preview' && (
            <Stack direction="row" spacing={2} sx={{ mb: 2 }}>
              <Button
                variant="contained"
                startIcon={<PlayArrowIcon />}
                disabled={validCount === 0}
                onClick={handleCommit}
              >
                Import {validCount} Valid Row(s)
              </Button>
              {errorCount > 0 && (
                <Typography variant="body2" sx={{ alignSelf: 'center', color: 'text.secondary' }}>
                  Rows with errors will be skipped. Fix your CSV and re-upload to include them.
                </Typography>
              )}
            </Stack>
          )}

          {phase === 'committing' && (
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, py: 2 }}>
              <CircularProgress size={20} />
              <Typography variant="body2">Importing rows one at a time…</Typography>
            </Box>
          )}

          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>#</TableCell>
                  <TableCell>Key Fields</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Notes</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {preview.map((row) => {
                  const result = commitResults.find((r) => r.index === row.index);
                  const keyFields = Object.entries(row.raw)
                    .slice(0, 3)
                    .map(([k, v]) => `${k}: ${v}`)
                    .join(' · ');
                  return (
                    <TableRow key={row.index} hover>
                      <TableCell>{row.index}</TableCell>
                      <TableCell>{keyFields}</TableCell>
                      <TableCell>
                        {phase === 'done' ? (
                          result ? (
                            <Chip
                              size="small"
                              label={result.success ? 'Imported' : 'Failed'}
                              color={result.success ? 'success' : 'error'}
                            />
                          ) : (
                            <Chip size="small" label="Skipped" color="default" />
                          )
                        ) : row.errors.length > 0 ? (
                          <Chip size="small" label="Error" color="error" />
                        ) : row.warnings.length > 0 ? (
                          <Chip size="small" label="Warning" color="warning" />
                        ) : (
                          <Chip size="small" label="OK" color="success" />
                        )}
                      </TableCell>
                      <TableCell>
                        {phase === 'done' && result
                          ? result.message
                          : [...row.errors, ...row.warnings].join('; ') || '—'}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </TableContainer>
        </Paper>
      )}

      <Divider sx={{ my: 2 }} />
      <Typography variant="caption" color="text.secondary">
        Organization, cost center, and account codes are matched case-insensitively against existing records —
        nothing is created on the fly. Fix codes in your source system or the reference screens first if a lookup
        fails.
      </Typography>
    </Box>
  );
}