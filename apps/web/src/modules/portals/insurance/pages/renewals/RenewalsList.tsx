import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Checkbox, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, MenuItem, Stack,
  Table, TableBody, TableCell, TableHead, TableRow, TextField, Tooltip, Typography,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useInsuranceAccess } from '../../access';
import { errorText, rows, rpc, table } from '../../db';
import {
  canStartRenewal, formatMoney, isRenewalOpen, RENEWAL_BUCKET_LABEL, RENEWAL_OUTCOME_LABEL, RENEWAL_OUTCOMES, renewalBucket,
  summariseBulkRenewal, validateRenewalOutcome, type RenewalBucket,
} from '../../logic';
import type { BulkRenewalResult, RenewalOutcome, RenewalRow } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import { useRenewalNotificationSweep } from '../../renewalNotificationSweep';

const ORDER: RenewalBucket[] = ['overdue', 'd0_30', 'd31_60', 'd61_90', 'd91_120'];
const BULK_LIMIT = 100;

type Filter = 'all' | 'closed' | RenewalBucket;

// Active policies expiring within 120 days (ins_renewal_pipeline, RLS-scoped).
// "Start renewal" opens a draft that starts on the old expiry date and copies the term.
// Tick several policies to open their drafts in one go; each is reported separately, so one
// refusal never blocks the rest. "Close out" records why a policy is not being renewed and
// takes it off the open list; a manager can reopen it.
export default function RenewalsList() {
  const navigate = useNavigate();
  useRenewalNotificationSweep();
  const { canManage } = useInsuranceAccess();
  const [items, setItems] = useState<RenewalRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [bulkBusy, setBulkBusy] = useState(false);
  const [bulkResult, setBulkResult] = useState<ReturnType<typeof summariseBulkRenewal> | null>(null);
  const [closing, setClosing] = useState<RenewalRow | null>(null);
  const [outcome, setOutcome] = useState<RenewalOutcome | ''>('');
  const [reason, setReason] = useState('');
  const [closeBusy, setCloseBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems(await rows<RenewalRow>(table('ins_renewal_pipeline').select('*').order('expiry_date', { ascending: true })));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const open = useMemo(() => items.filter(isRenewalOpen), [items]);
  const closedCount = items.length - open.length;

  const counts = useMemo(() => {
    const c: Record<RenewalBucket, number> = { overdue: 0, d0_30: 0, d31_60: 0, d61_90: 0, d91_120: 0, later: 0 };
    for (const r of open) c[renewalBucket(r.days_to_expiry)] += 1;
    return c;
  }, [open]);

  const visible = items.filter((r) => {
    if (filter === 'closed') return !isRenewalOpen(r);
    if (!isRenewalOpen(r)) return false;
    return filter === 'all' || renewalBucket(r.days_to_expiry) === filter;
  });

  const eligible = visible.filter(canStartRenewal);
  const selectedEligible = eligible.filter((r) => selected.has(r.policy_id));
  const allTicked = eligible.length > 0 && selectedEligible.length === eligible.length;

  const toggle = (id: string) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const toggleAll = () => setSelected(allTicked ? new Set() : new Set(eligible.map((r) => r.policy_id)));
  const chooseFilter = (f: Filter) => {
    setFilter(f);
    setSelected(new Set());
  };

  const startRenewal = async (r: RenewalRow) => {
    setBusyId(r.policy_id);
    setError(null);
    try {
      const d = await rpc<{ id: string }>('ins_create_renewal_draft', { p_policy_id: r.policy_id });
      navigate(`/insurance/policies/${d.id}`);
    } catch (e) {
      setError(errorText(e));
      setBusyId(null);
    }
  };

  const startSelected = async () => {
    if (selectedEligible.length === 0) return;
    setBulkBusy(true);
    setError(null);
    setBulkResult(null);
    try {
      const results = await rpc<BulkRenewalResult[]>('ins_create_renewal_drafts', { p_policy_ids: selectedEligible.map((r) => r.policy_id) });
      setBulkResult(summariseBulkRenewal(results));
      setSelected(new Set());
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBulkBusy(false);
    }
  };

  const openClose = (r: RenewalRow) => {
    setClosing(r);
    setOutcome('');
    setReason('');
  };

  const submitClose = async () => {
    if (!closing || !outcome) return;
    setCloseBusy(true);
    setError(null);
    try {
      await rpc('ins_record_renewal_outcome', { p_policy_id: closing.policy_id, p_outcome: outcome, p_reason: reason });
      setClosing(null);
      await load();
    } catch (e) {
      setError(errorText(e));
      setClosing(null);
    } finally {
      setCloseBusy(false);
    }
  };

  const reopen = async (r: RenewalRow) => {
    setBusyId(r.policy_id);
    setError(null);
    try {
      await rpc('ins_clear_renewal_outcome', { p_policy_id: r.policy_id });
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusyId(null);
    }
  };

  if (loading && items.length === 0) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  const closeErrors = validateRenewalOutcome(outcome, reason);
  const tooMany = selectedEligible.length > BULK_LIMIT;
  const showCheckboxes = filter !== 'closed';

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader title="Renewals" subtitle="Active policies expiring in the next 120 days, oldest first." />
      <ErrorBanner message={error} />
      {bulkResult && (
        <Alert severity={bulkResult.failed.length ? 'warning' : 'success'} sx={{ mb: 2 }} onClose={() => setBulkResult(null)}>
          <Typography variant="body2" fontWeight={600}>
            {bulkResult.created} renewal draft{bulkResult.created === 1 ? '' : 's'} opened
            {bulkResult.failed.length ? `, ${bulkResult.failed.length} not opened` : ''}.
          </Typography>
          {bulkResult.failed.map((f) => (
            <Typography key={f.policy_no} variant="body2">{f.policy_no}: {f.message}</Typography>
          ))}
        </Alert>
      )}
      <Stack direction="row" spacing={1} sx={{ mb: 2, flexWrap: 'wrap', gap: 1 }}>
        <Chip label={`All open (${open.length})`} color={filter === 'all' ? 'primary' : 'default'} onClick={() => chooseFilter('all')} />
        {ORDER.map((b) => (
          <Chip key={b} label={`${RENEWAL_BUCKET_LABEL[b]} (${counts[b]})`} color={filter === b ? 'primary' : 'default'} variant={counts[b] ? 'filled' : 'outlined'} onClick={() => chooseFilter(b)} />
        ))}
        <Chip label={`Closed out (${closedCount})`} color={filter === 'closed' ? 'primary' : 'default'} variant={closedCount ? 'filled' : 'outlined'} onClick={() => chooseFilter('closed')} />
      </Stack>
      {showCheckboxes && selectedEligible.length > 0 && (
        <Stack direction="row" spacing={2} alignItems="center" sx={{ mb: 2 }}>
          <Typography variant="body2">{selectedEligible.length} selected</Typography>
          <Button variant="contained" size="small" disabled={bulkBusy || tooMany} onClick={startSelected}>
            {bulkBusy ? 'Starting...' : `Start ${selectedEligible.length} renewal${selectedEligible.length === 1 ? '' : 's'}`}
          </Button>
          <Button size="small" disabled={bulkBusy} onClick={() => setSelected(new Set())}>Clear selection</Button>
          {tooMany && <Typography variant="caption" color="error">Select at most {BULK_LIMIT} policies at a time.</Typography>}
        </Stack>
      )}
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                {showCheckboxes && (
                  <TableCell padding="checkbox">
                    <Checkbox size="small" checked={allTicked} indeterminate={selectedEligible.length > 0 && !allTicked} disabled={eligible.length === 0}
                      onChange={toggleAll} inputProps={{ 'aria-label': 'Select all policies without a renewal draft' }} />
                  </TableCell>
                )}
                <TableCell>Policy</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Insurer</TableCell>
                <TableCell>Expiry</TableCell>
                <TableCell>{filter === 'closed' ? 'Outcome' : 'When'}</TableCell>
                <TableCell align="right">Last premium</TableCell>
                <TableCell align="right">Action</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {visible.length === 0 ? (
                <EmptyRow colSpan={showCheckboxes ? 8 : 7} text={filter === 'closed' ? 'No renewals have been closed out.' : 'Nothing expiring in this window.'} />
              ) : (
                visible.map((r) => (
                  <TableRow key={r.policy_id} hover selected={selected.has(r.policy_id)}>
                    {showCheckboxes && (
                      <TableCell padding="checkbox">
                        <Checkbox size="small" checked={selected.has(r.policy_id)} disabled={!canStartRenewal(r)} onChange={() => toggle(r.policy_id)}
                          inputProps={{ 'aria-label': `Select ${r.policy_no}` }} />
                      </TableCell>
                    )}
                    <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.policy_no}</TableCell>
                    <TableCell>{r.client_name}</TableCell>
                    <TableCell>{r.insurer_name}</TableCell>
                    <TableCell>{r.expiry_date}</TableCell>
                    <TableCell>
                      {r.renewal_outcome ? (
                        <Tooltip title={r.renewal_outcome_reason ?? ''}>
                          <Chip size="small" variant="outlined" label={RENEWAL_OUTCOME_LABEL[r.renewal_outcome]} />
                        </Tooltip>
                      ) : (
                        <Typography variant="body2" color={r.days_to_expiry < 0 ? 'error' : 'text.primary'}>
                          {r.days_to_expiry < 0 ? `${-r.days_to_expiry} days overdue` : `${r.days_to_expiry} days`}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell align="right">{formatMoney(r.gross_premium, r.currency)}</TableCell>
                    <TableCell align="right">
                      {r.renewal_outcome ? (
                        canManage && <Button size="small" disabled={busyId === r.policy_id} onClick={() => reopen(r)}>Reopen</Button>
                      ) : r.renewal_draft_id ? (
                        <Button size="small" onClick={() => navigate(`/insurance/policies/${r.renewal_draft_id}`)}>Open draft</Button>
                      ) : (
                        <Stack direction="row" spacing={1} justifyContent="flex-end">
                          <Button size="small" color="inherit" onClick={() => openClose(r)}>Close out</Button>
                          <Button size="small" variant="outlined" disabled={busyId === r.policy_id} onClick={() => startRenewal(r)}>
                            Start renewal
                          </Button>
                        </Stack>
                      )}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={!!closing} onClose={() => !closeBusy && setClosing(null)} fullWidth maxWidth="sm">
        <DialogTitle>Close out {closing?.policy_no}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <Typography variant="body2" color="text.secondary">
              Record why {closing?.client_name} is not being renewed. The policy leaves the open list. A manager can reopen it later.
            </Typography>
            <TextField select label="What happened" value={outcome} onChange={(e) => setOutcome(e.target.value as RenewalOutcome)}>
              {RENEWAL_OUTCOMES.map((o) => <MenuItem key={o} value={o}>{RENEWAL_OUTCOME_LABEL[o]}</MenuItem>)}
            </TextField>
            <TextField label="Reason" required multiline minRows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setClosing(null)} disabled={closeBusy}>Cancel</Button>
          <Button variant="contained" onClick={submitClose} disabled={closeBusy || closeErrors.length > 0}>Close out</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
