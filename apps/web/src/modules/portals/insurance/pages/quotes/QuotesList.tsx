import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions,
  DialogContent, DialogTitle, MenuItem, Stack, Table, TableBody, TableCell, TableHead,
  TableRow, TextField, 
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useInsuranceAccess } from '../../access';
import { errorText, rows, rpc, table } from '../../db';
import { formatMoney } from '../../logic';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Quotes & placement (slice Q1): the quotation pipeline backed by
// ins_quotes and the ins_create_quote / ins_submit_quote / ins_decide_quote /
// ins_place_quote RPCs. Writes go through the RPCs only; this screen never
// writes the table directly. Statuses: draft -> submitted -> accepted/declined
// -> placed (a draft policy is created). Server enforces the tiers: members
// create and submit, managers decide and place.

type QuoteStatus = 'draft' | 'submitted' | 'accepted' | 'declined' | 'placed';

interface QuoteRow {
  id: string;
  quote_no: string;
  status: QuoteStatus;
  client_id: string;
  insurer_id: string;
  product_line_id: string;
  sum_insured: number;
  currency: string;
  gross_premium: number;
  commission_rate_pct: number;
  valid_until: string | null;
  insurer_ref: string | null;
  accepted_policy_id: string | null;
  notes: string | null;
  created_at: string;
}

interface ClientRow { id: string; name: string }
interface InsurerRow { id: string; name: string; is_active: boolean }
interface ProductLineRow { id: string; name: string; is_active: boolean }

const STATUS_COLOR: Record<QuoteStatus, 'default' | 'info' | 'success' | 'error' | 'warning'> = {
  draft: 'default',
  submitted: 'info',
  accepted: 'success',
  declined: 'error',
  placed: 'warning',
};

interface NewQuote {
  client_id: string;
  insurer_id: string;
  product_line_id: string;
  sum_insured: string;
  currency: string;
  gross_premium: string;
  commission_rate_pct: string;
  valid_until: string;
  notes: string;
}

const EMPTY_NEW: NewQuote = {
  client_id: '', insurer_id: '', product_line_id: '',
  sum_insured: '', currency: 'UGX', gross_premium: '', commission_rate_pct: '',
  valid_until: '', notes: '',
};

export default function QuotesList() {
  const navigate = useNavigate();
  const { canManage } = useInsuranceAccess();
  const [items, setItems] = useState<QuoteRow[]>([]);
  const [clients, setClients] = useState<ClientRow[]>([]);
  const [insurers, setInsurers] = useState<InsurerRow[]>([]);
  const [lines, setLines] = useState<ProductLineRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [deciding, setDeciding] = useState<QuoteRow | null>(null);
  const [decision, setDecision] = useState<'accepted' | 'declined'>('accepted');
  const [insurerRef, setInsurerRef] = useState('');
  const [openNew, setOpenNew] = useState(false);
  const [newQuote, setNewQuote] = useState<NewQuote>(EMPTY_NEW);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [q, c, i, l] = await Promise.all([
        rows<QuoteRow>(table('ins_quotes').select('*').order('created_at', { ascending: false })),
        rows<ClientRow>(table('ins_clients').select('id,name').order('name')),
        rows<InsurerRow>(table('ins_insurers').select('id,name,is_active').order('name')),
        rows<ProductLineRow>(table('ins_product_lines').select('id,name,is_active').order('name')),
      ]);
      setItems(q);
      setClients(c);
      setInsurers(i);
      setLines(l);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const run = useCallback(async (id: string, fn: () => Promise<unknown>) => {
    setBusyId(id);
    try {
      await fn();
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusyId(null);
    }
  }, [load]);

  const submit = (q: QuoteRow) =>
    run(q.id, () => rpc('ins_submit_quote', { p_quote_id: q.id }));

  const decide = async () => {
    if (!deciding) return;
    await run(deciding.id, () =>
      rpc('ins_decide_quote', {
        p_quote_id: deciding.id,
        p_decision: decision,
        p_insurer_ref: insurerRef || null,
      }));
    setDeciding(null);
    setInsurerRef('');
  };

  const place = (q: QuoteRow) =>
    run(q.id, async () => {
      const policy = await rpc<{ id: string }>('ins_place_quote', { p_quote_id: q.id });
      navigate(`/insurance/policies/${policy.id}`);
    });

  const saveNew = async () => {
    setSaving(true);
    try {
      await rpc('ins_create_quote', {
        p_client_id: newQuote.client_id,
        p_insurer_id: newQuote.insurer_id,
        p_product_line_id: newQuote.product_line_id,
        p_sum_insured: Number(newQuote.sum_insured) || 0,
        p_currency: newQuote.currency,
        p_gross_premium: Number(newQuote.gross_premium) || 0,
        p_commission_rate_pct: Number(newQuote.commission_rate_pct) || 0,
        p_valid_until: newQuote.valid_until || null,
        p_notes: newQuote.notes || null,
      });
      setOpenNew(false);
      setNewQuote(EMPTY_NEW);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  const clientName = (id: string) => clients.find((c) => c.id === id)?.name ?? '—';
  const insurerName = (id: string) => insurers.find((i) => i.id === id)?.name ?? '—';
  const lineName = (id: string) => lines.find((l) => l.id === id)?.name ?? '—';

  return (
    <Box>
      <PageHeader
        title="Quotes & Placement"
        subtitle="Quotation pipeline: draft → submit → accept/decline → place into a policy draft."
        actions={<Button variant="contained" onClick={() => setOpenNew(true)}>New quote</Button>}
      />
      <ErrorBanner message={error} />
      {loading ? (
        <CircularProgress />
      ) : (
        <Card><CardContent>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Quote</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Insurer</TableCell>
                <TableCell>Product line</TableCell>
                <TableCell align="right">Sum insured</TableCell>
                <TableCell align="right">Gross premium</TableCell>
                <TableCell align="right">Comm %</TableCell>
                <TableCell>Valid until</TableCell>
                <TableCell>Status</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {items.length === 0 && <EmptyRow colSpan={10} text="No quotes yet." />}
              {items.map((q) => (
                <TableRow key={q.id}>
                  <TableCell>{q.quote_no}</TableCell>
                  <TableCell>{clientName(q.client_id)}</TableCell>
                  <TableCell>{insurerName(q.insurer_id)}</TableCell>
                  <TableCell>{lineName(q.product_line_id)}</TableCell>
                  <TableCell align="right">{formatMoney(q.sum_insured, q.currency)}</TableCell>
                  <TableCell align="right">{formatMoney(q.gross_premium, q.currency)}</TableCell>
                  <TableCell align="right">{q.commission_rate_pct}</TableCell>
                  <TableCell>{q.valid_until ?? '—'}</TableCell>
                  <TableCell><Chip size="small" label={q.status} color={STATUS_COLOR[q.status]} /></TableCell>
                  <TableCell align="right">
                    <Stack direction="row" spacing={1} justifyContent="flex-end">
                      {q.status === 'draft' && (
                        <Button size="small" disabled={busyId === q.id} onClick={() => submit(q)}>Submit</Button>
                      )}
                      {q.status === 'submitted' && canManage && (
                        <Button size="small" variant="outlined" disabled={busyId === q.id}
                          onClick={() => { setDeciding(q); setDecision('accepted'); setInsurerRef(q.insurer_ref ?? ''); }}>
                          Decide
                        </Button>
                      )}
                      {q.status === 'accepted' && canManage && (
                        <Button size="small" variant="contained" disabled={busyId === q.id} onClick={() => place(q)}>
                          Place
                        </Button>
                      )}
                      {q.status === 'placed' && q.accepted_policy_id && (
                        <Button size="small" onClick={() => navigate(`/insurance/policies/${q.accepted_policy_id}`)}>
                          Policy
                        </Button>
                      )}
                    </Stack>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent></Card>
      )}

      <Dialog open={openNew} onClose={() => setOpenNew(false)} fullWidth maxWidth="sm">
        <DialogTitle>New quote</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="Client" fullWidth required value={newQuote.client_id}
              onChange={(e) => setNewQuote({ ...newQuote, client_id: e.target.value })}>
              {clients.map((c) => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}
            </TextField>
            <TextField select label="Insurer" fullWidth required value={newQuote.insurer_id}
              onChange={(e) => setNewQuote({ ...newQuote, insurer_id: e.target.value })}>
              {insurers.filter((i) => i.is_active).map((i) => <MenuItem key={i.id} value={i.id}>{i.name}</MenuItem>)}
            </TextField>
            <TextField select label="Product line" fullWidth required value={newQuote.product_line_id}
              onChange={(e) => setNewQuote({ ...newQuote, product_line_id: e.target.value })}>
              {lines.filter((l) => l.is_active).map((l) => <MenuItem key={l.id} value={l.id}>{l.name}</MenuItem>)}
            </TextField>
            <TextField label="Sum insured" type="number" fullWidth value={newQuote.sum_insured}
              onChange={(e) => setNewQuote({ ...newQuote, sum_insured: e.target.value })} />
            <TextField label="Currency" fullWidth value={newQuote.currency}
              onChange={(e) => setNewQuote({ ...newQuote, currency: e.target.value.toUpperCase() })} />
            <TextField label="Gross premium" type="number" fullWidth value={newQuote.gross_premium}
              onChange={(e) => setNewQuote({ ...newQuote, gross_premium: e.target.value })} />
            <TextField label="Commission %" type="number" fullWidth value={newQuote.commission_rate_pct}
              onChange={(e) => setNewQuote({ ...newQuote, commission_rate_pct: e.target.value })} />
            <TextField label="Valid until" type="date" fullWidth InputLabelProps={{ shrink: true }}
              value={newQuote.valid_until}
              onChange={(e) => setNewQuote({ ...newQuote, valid_until: e.target.value })} />
            <TextField label="Notes" fullWidth multiline minRows={2} value={newQuote.notes}
              onChange={(e) => setNewQuote({ ...newQuote, notes: e.target.value })} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpenNew(false)}>Cancel</Button>
          <Button variant="contained" disabled={saving || !newQuote.client_id || !newQuote.insurer_id || !newQuote.product_line_id}
            onClick={saveNew}>
            {saving ? 'Saving…' : 'Create draft'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={!!deciding} onClose={() => setDeciding(null)}>
        <DialogTitle>Decide quote {deciding?.quote_no}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="Decision" fullWidth value={decision}
              onChange={(e) => setDecision(e.target.value as 'accepted' | 'declined')}>
              <MenuItem value="accepted">Accept</MenuItem>
              <MenuItem value="declined">Decline</MenuItem>
            </TextField>
            <TextField label="Insurer reference" fullWidth value={insurerRef}
              onChange={(e) => setInsurerRef(e.target.value)} />
            {decision === 'accepted' && (
              <Alert severity="info">Accepting lets a manager place the quote into a policy draft.</Alert>
            )}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDeciding(null)}>Cancel</Button>
          <Button variant="contained" disabled={busyId === deciding?.id} onClick={decide}>Save decision</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
