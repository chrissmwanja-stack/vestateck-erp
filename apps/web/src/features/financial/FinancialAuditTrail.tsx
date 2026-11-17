import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
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
import { Refresh } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

// /financial-management/reports/audit-trail
//
// One screen for the question "who did what to this money". Reads
// fin_audit_trail(entity_type, entity_id) (migration 20261117160000), which
// composes fin_trace (the document spine and money legs, item E) with
// fin_transaction_actors (initiator / approver / poster / reverser),
// the approval trail, the supporting documents, and the period state.
//
// The screen is deliberately read-only: the trail is append-only in the
// database, so there is nothing here that could edit it.

// Which documents the trail can report on. fin_trace refuses anything else,
// so the list is not a hint -- it is the contract.
const ENTITY_TYPES = [
  { value: 'supplier_invoice', label: 'Supplier invoice' },
  { value: 'receivable_invoice', label: 'Receivable invoice' },
  { value: 'cash_bank_transaction', label: 'Cash / bank transaction' },
  { value: 'fin_settlement', label: 'Settlement' },
] as const;

type EntityType = (typeof ENTITY_TYPES)[number]['value'];

interface TrailRow {
  hop: number;
  stage: string;
  happened_at: string | null;
  actor_id: string | null;
  actor_name: string | null;
  summary: string | null;
  detail: string | null;
  journal_id: string | null;
  document_id: string | null;
  document_name: string | null;
  amount: number | null;
  currency: string | null;
  status: string | null;
}

interface GapRow {
  journal_entry_id: string;
  source_type: string;
  entry_date: string;
  description: string | null;
  gap: string;
}

interface DocumentOption {
  id: string;
  label: string;
}

type TableName =
  | 'supplier_invoices'
  | 'receivable_invoices'
  | 'cash_bank_transactions'
  | 'fin_settlements';

// Which table a chosen entity type is picked from, and what to show per row.
const PICKERS: Record<EntityType, { table: TableName; select: string; orderBy: 'invoice_date' | 'issue_date' | 'transaction_date' | 'settlement_date'; label: (r: Record<string, unknown>) => string }> = {
  supplier_invoice: {
    table: 'supplier_invoices',
    select: 'id, invoice_number, invoice_date, amount_incl_vat, currency',
    orderBy: 'invoice_date',
    label: (r) =>
      `${r.invoice_number as string} · ${r.invoice_date as string} · ${
        Number(r.amount_incl_vat).toLocaleString()
      } ${r.currency as string}`,
  },
  receivable_invoice: {
    table: 'receivable_invoices',
    select: 'id, invoice_number, issue_date, amount_incl_vat, currency',
    orderBy: 'issue_date',
    label: (r) =>
      `${r.invoice_number as string} · ${r.issue_date as string} · ${
        Number(r.amount_incl_vat).toLocaleString()
      } ${r.currency as string}`,
  },
  cash_bank_transaction: {
    table: 'cash_bank_transactions',
    select: 'id, transaction_date, transaction_type, amount, currency, description',
    orderBy: 'transaction_date',
    label: (r) =>
      `${r.transaction_date as string} · ${r.transaction_type as string} · ${
        Number(r.amount).toLocaleString()
      } ${r.currency as string}${r.description ? ` · ${r.description as string}` : ''}`,
  },
  fin_settlement: {
    table: 'fin_settlements',
    select: 'id, settlement_no, settlement_date, amount, currency, direction',
    orderBy: 'settlement_date',
    label: (r) =>
      `${r.settlement_no as string} · ${r.settlement_date as string} · ${
        Number(r.amount).toLocaleString()
      } ${r.currency as string}`,
  },
};

const STAGE_COLOR: Record<string, 'default' | 'primary' | 'success' | 'warning' | 'error' | 'info'> = {
  document: 'default',
  'purchase order': 'info',
  journal: 'primary',
  initiated: 'info',
  approved: 'success',
  posted: 'primary',
  reversed: 'error',
  payment: 'primary',
  'open item': 'info',
  settlement: 'info',
  'bank match': 'success',
  period: 'default',
  'supporting document': 'default',
};

function formatWhen(value: string | null): string {
  if (!value) return '—';
  return new Date(value).toLocaleString();
}

export default function FinancialAuditTrail() {
  const [entityType, setEntityType] = useState<EntityType>('supplier_invoice');
  const [documents, setDocuments] = useState<DocumentOption[]>([]);
  const [documentsLoading, setDocumentsLoading] = useState(true);
  const [selectedId, setSelectedId] = useState('');
  const [rows, setRows] = useState<TrailRow[]>([]);
  const [gaps, setGaps] = useState<GapRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [searched, setSearched] = useState(false);

  // The document picker: recent documents of the chosen type. Reading the
  // table is enough to populate it; the trail itself is what is authoritative.
  useEffect(() => {
    let cancelled = false;
    const picker = PICKERS[entityType];

    async function loadDocuments() {
      setDocumentsLoading(true);
      const { data, error: err } = await supabase
        .from(picker.table)
        .select(picker.select)
        .order(picker.orderBy, { ascending: false })
        .limit(50);

      if (cancelled) return;
      if (err) {
        setError(err.message);
        setDocuments([]);
      } else {
        setDocuments(
          ((data ?? []) as unknown as Record<string, unknown>[]).map((r) => ({
            id: r.id as string,
            label: picker.label(r),
          })),
        );
      }
      setDocumentsLoading(false);
    }

    void loadDocuments();
    return () => {
      cancelled = true;
    };
  }, [entityType]);

  const loadTrail = useCallback(async () => {
    if (!selectedId) return;
    setLoading(true);
    setError(null);

    const { data, error: err } = await supabase.rpc('fin_audit_trail', {
      p_entity_type: entityType,
      p_entity_id: selectedId,
    });

    if (err) {
      setError(err.message);
      setRows([]);
      setLoading(false);
      setSearched(true);
      return;
    }

    setRows((data ?? []) as TrailRow[]);

    // Gaps are tenant-wide, so they are shown alongside as context: the trail
    // of this one document is complete or not, but the reader should be able
    // to see what else in the books has no initiator.
    const { data: gapData, error: gapErr } = await supabase.rpc('fin_audit_gaps');
    if (gapErr) {
      setGaps([]);
    } else {
      setGaps((gapData ?? []) as GapRow[]);
    }

    setLoading(false);
    setSearched(true);
  }, [entityType, selectedId]);

  useEffect(() => {
    setSelectedId('');
    setRows([]);
    setSearched(false);
    setError(null);
  }, [entityType]);

  const actorSummary = useMemo(() => {
    const byStage = new Map<string, string>();
    for (const row of rows) {
      if (['initiated', 'approved', 'posted', 'reversed'].includes(row.stage) && row.actor_name) {
        byStage.set(row.stage, row.actor_name);
      }
    }
    return byStage;
  }, [rows]);

  return (
    <Box sx={{ p: 2 }}>
      <Typography variant="h5" gutterBottom>
        Financial audit trail
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Who initiated, approved, posted and reversed each posting — with the document, the paper
        behind it and the period it landed in. Read-only: the trail is append-only.
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Paper sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} alignItems="flex-start">
          <TextField
            select
            size="small"
            label="Document type"
            value={entityType}
            onChange={(e) => setEntityType(e.target.value as EntityType)}
            sx={{ minWidth: 220 }}
          >
            {ENTITY_TYPES.map((t) => (
              <MenuItem key={t.value} value={t.value}>
                {t.label}
              </MenuItem>
            ))}
          </TextField>

          <TextField
            select
            size="small"
            label="Document"
            value={selectedId}
            onChange={(e) => setSelectedId(e.target.value)}
            sx={{ minWidth: 360, flexGrow: 1 }}
            disabled={documentsLoading}
            helperText={documentsLoading ? 'Loading recent documents…' : undefined}
          >
            <MenuItem value="">
              <em>Choose a document</em>
            </MenuItem>
            {documents.map((d) => (
              <MenuItem key={d.id} value={d.id}>
                {d.label}
              </MenuItem>
            ))}
          </TextField>

          <Button
            variant="contained"
            onClick={() => void loadTrail()}
            disabled={!selectedId || loading}
            startIcon={loading ? <CircularProgress size={16} color="inherit" /> : <Refresh />}
          >
            Trace
          </Button>
        </Stack>
      </Paper>

      {searched && rows.length > 0 && (
        <Paper sx={{ mb: 2 }}>
          <Box sx={{ p: 1.5, pb: 0 }}>
            <Typography variant="subtitle2">In one line</Typography>
            <Stack direction="row" spacing={1} sx={{ mt: 1, mb: 1, flexWrap: 'wrap', rowGap: 1 }}>
              {(['initiated', 'approved', 'posted', 'reversed'] as const).map((stage) => (
                <Chip
                  key={stage}
                  size="small"
                  label={`${stage}: ${actorSummary.get(stage) ?? 'not recorded'}`}
                  color={actorSummary.has(stage) ? STAGE_COLOR[stage] : 'default'}
                  variant={actorSummary.has(stage) ? 'filled' : 'outlined'}
                />
              ))}
            </Stack>
          </Box>
        </Paper>
      )}

      {loading && (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
          <CircularProgress />
        </Box>
      )}

      {!loading && searched && rows.length === 0 && (
        <Alert severity="info">Nothing to show for that document.</Alert>
      )}

      {!loading && rows.length > 0 && (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>#</TableCell>
                <TableCell>Stage</TableCell>
                <TableCell>When</TableCell>
                <TableCell>Who</TableCell>
                <TableCell>What</TableCell>
                <TableCell align="right">Amount</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={`${row.hop}-${row.stage}-${row.journal_id ?? 'x'}`} hover>
                  <TableCell>{row.hop}</TableCell>
                  <TableCell>
                    <Chip
                      size="small"
                      label={row.stage}
                      color={STAGE_COLOR[row.stage] ?? 'default'}
                      variant="outlined"
                    />
                  </TableCell>
                  <TableCell>{formatWhen(row.happened_at)}</TableCell>
                  <TableCell>{row.actor_name ?? '—'}</TableCell>
                  <TableCell>
                    <Typography variant="body2">{row.summary ?? '—'}</Typography>
                    {row.detail && (
                      <Typography variant="caption" color="text.secondary" display="block">
                        {row.detail}
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell align="right">
                    {row.amount === null
                      ? '—'
                      : `${Number(row.amount).toLocaleString()} ${row.currency ?? ''}`.trim()}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {gaps.length > 0 && (
        <Paper sx={{ mt: 2 }}>
          <Box sx={{ p: 1.5, pb: 0 }}>
            <Typography variant="subtitle2">
              Postings with incomplete history ({gaps.length})
            </Typography>
            <Typography variant="caption" color="text.secondary">
              Reported, not inferred: these postings genuinely have no initiator on record.
            </Typography>
          </Box>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Date</TableCell>
                <TableCell>Source</TableCell>
                <TableCell>Description</TableCell>
                <TableCell>Gap</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {gaps.slice(0, 20).map((g) => (
                <TableRow key={`${g.journal_entry_id}-${g.gap}`} hover>
                  <TableCell>{g.entry_date}</TableCell>
                  <TableCell>{g.source_type}</TableCell>
                  <TableCell>{g.description ?? '—'}</TableCell>
                  <TableCell>{g.gap}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Paper>
      )}
    </Box>
  );
}
