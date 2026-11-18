import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Grid, MenuItem,
  Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { allRows, errorText, rows, rpc, table } from '../../db';
import { useInsuranceAccess } from '../../access';
import { EmptyRow, ErrorBanner } from '../../shared';
import { supabase } from '../../../../../lib/supabaseClient';
import {
  AGENT_BASIS_LABEL, AGENT_TERM_STATUS_LABEL, TERM_PHASE_LABEL, basesForCategory, canApproveTerm, canEndTerm,
  termFigure, termPhase, validateTermInput, type AgentTerm, type AgentTermBasis, type TermFormInput,
} from '../../agentCommission';

interface AgentRef { id: string; name: string; category: string }
interface PersonRef { id: string; name: string | null; email: string | null }

const todayIso = () => new Date().toISOString().slice(0, 10);
const blankForm = (): TermFormInput & { intermediary_id: string; product_line_id: string; source_ref: string } => ({
  intermediary_id: '', basis: '', rate_pct: '', fixed_amount: '', tier_from_amount: '', tier_to_amount: '',
  product_line_id: '', effective_from: todayIso(), effective_to: '', source_ref: '',
});
const numOrNull = (v: string) => (v.trim() === '' ? null : Number(v));

const AgentCommissionTerms = () => {
  const { canManage } = useInsuranceAccess();
  const [terms, setTerms] = useState<AgentTerm[]>([]);
  const [agents, setAgents] = useState<AgentRef[]>([]);
  const [lines, setLines] = useState<{ id: string; name: string }[]>([]);
  const [people, setPeople] = useState<Record<string, string>>({});
  const [userId, setUserId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [open, setOpen] = useState(false);
  const [form, setForm] = useState(blankForm());
  const [formError, setFormError] = useState<string | null>(null);

  const [endTarget, setEndTarget] = useState<AgentTerm | null>(null);
  const [endDate, setEndDate] = useState(todayIso());

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [t, a, l, p] = await Promise.all([
        allRows<AgentTerm>(() => table('ins_intermediary_terms').select('*').order('created_at', { ascending: false }).order('id')),
        allRows<AgentRef>(() => table('ins_intermediaries').select('id, name, category').order('name', { ascending: true }).order('id')),
        rows<{ id: string; name: string }>(table('ins_product_lines').select('id, name').order('name', { ascending: true })),
        rows<PersonRef>(table('app_users').select('id, name, email').order('name', { ascending: true })),
      ]);
      setTerms(t);
      setAgents(a);
      setLines(l);
      setPeople(Object.fromEntries(p.map((u) => [u.id, u.name ?? u.email ?? 'Unknown'])));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    void supabase.auth.getUser().then(({ data }) => setUserId(data.user?.id ?? null));
  }, [load]);

  const agentName = useMemo(() => Object.fromEntries(agents.map((a) => [a.id, a.name])), [agents]);
  const lineName = useMemo(() => Object.fromEntries(lines.map((l) => [l.id, l.name])), [lines]);
  const nameOf = (id: string | null) => (id ? people[id] ?? 'Another user' : '-');
  // An independent broker is a co-broker, which the server refuses; leave it out of the list.
  const termAgents = useMemo(() => agents.filter((a) => basesForCategory(a.category).length > 0), [agents]);
  const chosenAgent = agents.find((a) => a.id === form.intermediary_id);
  const bases = chosenAgent ? basesForCategory(chosenAgent.category) : [];
  const today = todayIso();

  const run = async (action: () => Promise<unknown>, done: string) => {
    setBusy(true);
    try {
      await action();
      setNotice(done);
      setError(null);
      await load();
      return true;
    } catch (e) {
      setError(errorText(e));
      return false;
    } finally {
      setBusy(false);
    }
  };

  const submitTerm = async () => {
    if (!form.intermediary_id) { setFormError('Choose the intermediary.'); return; }
    const problem = validateTermInput(form);
    if (problem) { setFormError(problem); return; }
    setFormError(null);
    const ok = await run(() => rpc('ins_set_intermediary_term', {
      p_intermediary_id: form.intermediary_id,
      p_basis: form.basis,
      p_effective_from: form.effective_from,
      p_rate_pct: form.basis === 'none' || form.basis === 'flat_amount_per_policy' ? null : numOrNull(form.rate_pct),
      p_fixed_amount: form.basis === 'flat_amount_per_policy' ? numOrNull(form.fixed_amount) : null,
      p_product_line_id: form.product_line_id || null,
      p_effective_to: form.effective_to || null,
      p_tier_from_amount: form.basis === 'tiered_pct_of_broker_commission' ? numOrNull(form.tier_from_amount) : null,
      p_tier_to_amount: form.basis === 'tiered_pct_of_broker_commission' ? numOrNull(form.tier_to_amount) : null,
      p_source_ref: form.source_ref.trim() || null,
    }), 'Term saved as a draft. A different manager must approve it before it applies.');
    if (ok) { setOpen(false); setForm(blankForm()); }
  };

  const approve = (t: AgentTerm) => run(() => rpc('ins_approve_intermediary_term', { p_id: t.id }), 'Term approved.');

  const submitEnd = async () => {
    if (!endTarget) return;
    const ok = await run(() => rpc('ins_end_intermediary_term', { p_id: endTarget.id, p_effective_to: endDate }), 'Term end-dated.');
    if (ok) setEndTarget(null);
  };

  if (loading) return <CircularProgress />;

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 720 }}>
          How each intermediary is paid. Terms are never edited: end-date the current one and enter a new term, so commission
          already accrued keeps the figures it was accrued with. A term applies only once a different manager approves it.
        </Typography>
        {canManage && <Button variant="contained" onClick={() => { setForm(blankForm()); setFormError(null); setOpen(true); }}>New term</Button>}
      </Stack>
      <ErrorBanner message={error} />
      {notice && <Alert severity="success" onClose={() => setNotice(null)} sx={{ mb: 2 }}>{notice}</Alert>}

      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Intermediary</TableCell><TableCell>Arrangement</TableCell><TableCell>Product line</TableCell>
            <TableCell>Effective</TableCell><TableCell>Status</TableCell><TableCell>Entered by</TableCell>
            <TableCell>Approved</TableCell><TableCell />
          </TableRow>
        </TableHead>
        <TableBody>
          {terms.length === 0 && <EmptyRow colSpan={8} text="No commission terms yet." />}
          {terms.map((t) => (
            <TableRow key={t.id}>
              <TableCell>{agentName[t.intermediary_id] ?? '-'}</TableCell>
              <TableCell>
                <Typography variant="body2">{termFigure(t)}</Typography>
                <Typography variant="caption" color="text.secondary">{AGENT_BASIS_LABEL[t.basis] ?? t.basis}</Typography>
              </TableCell>
              <TableCell>{t.product_line_id ? lineName[t.product_line_id] ?? '-' : 'All product lines'}</TableCell>
              <TableCell>{t.effective_from} to {t.effective_to ?? 'open-ended'}</TableCell>
              <TableCell>
                <Chip size="small" label={TERM_PHASE_LABEL[termPhase(t, today)]} title={AGENT_TERM_STATUS_LABEL[t.status]} />
              </TableCell>
              <TableCell>{nameOf(t.entered_by)}</TableCell>
              <TableCell>{t.approved_by ? `${nameOf(t.approved_by)}, ${t.approved_at?.slice(0, 10) ?? ''}` : '-'}</TableCell>
              <TableCell align="right">
                {canApproveTerm(t, userId, canManage) && (
                  <Button size="small" disabled={busy} onClick={() => void approve(t)}>Approve</Button>
                )}
                {canEndTerm(t, today, canManage) && (
                  <Button size="small" disabled={busy} onClick={() => { setEndTarget(t); setEndDate(today); }}>End term</Button>
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>

      <Dialog open={open} onClose={() => setOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New commission term</DialogTitle>
        <DialogContent>
          <Grid container spacing={2} sx={{ mt: 0 }}>
            <Grid item xs={12}>
              <TextField select fullWidth label="Intermediary" value={form.intermediary_id}
                onChange={(e) => setForm({ ...form, intermediary_id: e.target.value, basis: '' })}>
                {termAgents.map((a) => <MenuItem key={a.id} value={a.id}>{a.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={12}>
              <TextField select fullWidth label="Arrangement" value={form.basis} disabled={!chosenAgent}
                helperText={chosenAgent?.category === 'insurer_appointed_agent' ? 'The insurer pays this agent, so the brokerage owes nothing. Recorded for the register only.' : undefined}
                onChange={(e) => setForm({ ...form, basis: e.target.value as AgentTermBasis })}>
                {bases.map((b) => <MenuItem key={b} value={b}>{AGENT_BASIS_LABEL[b]}</MenuItem>)}
              </TextField>
            </Grid>
            {form.basis !== '' && form.basis !== 'none' && form.basis !== 'flat_amount_per_policy' && (
              <Grid item xs={12} sm={6}>
                <TextField fullWidth type="number" label="Percentage" value={form.rate_pct}
                  onChange={(e) => setForm({ ...form, rate_pct: e.target.value })} />
              </Grid>
            )}
            {form.basis === 'flat_amount_per_policy' && (
              <Grid item xs={12} sm={6}>
                <TextField fullWidth type="number" label="Amount per policy" value={form.fixed_amount}
                  onChange={(e) => setForm({ ...form, fixed_amount: e.target.value })} />
              </Grid>
            )}
            {form.basis === 'tiered_pct_of_broker_commission' && (
              <>
                <Grid item xs={12} sm={6}>
                  <TextField fullWidth type="number" label="Tier from" value={form.tier_from_amount}
                    onChange={(e) => setForm({ ...form, tier_from_amount: e.target.value })} />
                </Grid>
                <Grid item xs={12} sm={6}>
                  <TextField fullWidth type="number" label="Tier to" value={form.tier_to_amount}
                    onChange={(e) => setForm({ ...form, tier_to_amount: e.target.value })} />
                </Grid>
              </>
            )}
            <Grid item xs={12}>
              <TextField select fullWidth label="Product line" value={form.product_line_id}
                onChange={(e) => setForm({ ...form, product_line_id: e.target.value })}>
                <MenuItem value="">All product lines</MenuItem>
                {lines.map((l) => <MenuItem key={l.id} value={l.id}>{l.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField fullWidth type="date" label="Effective from" InputLabelProps={{ shrink: true }} value={form.effective_from}
                onChange={(e) => setForm({ ...form, effective_from: e.target.value })} />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField fullWidth type="date" label="Effective to (optional)" InputLabelProps={{ shrink: true }} value={form.effective_to}
                onChange={(e) => setForm({ ...form, effective_to: e.target.value })} />
            </Grid>
            <Grid item xs={12}>
              <TextField fullWidth label="Reference (agreement, letter)" value={form.source_ref}
                onChange={(e) => setForm({ ...form, source_ref: e.target.value })} />
            </Grid>
            {formError && <Grid item xs={12}><Alert severity="warning">{formError}</Alert></Grid>}
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" disabled={busy} onClick={() => void submitTerm()}>Save as draft</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={endTarget !== null} onClose={() => setEndTarget(null)} fullWidth maxWidth="xs">
        <DialogTitle>End term</DialogTitle>
        <DialogContent>
          <TextField fullWidth type="date" label="Last day in force" InputLabelProps={{ shrink: true }} sx={{ mt: 1 }}
            value={endDate} onChange={(e) => setEndDate(e.target.value)} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEndTarget(null)}>Cancel</Button>
          <Button variant="contained" disabled={busy || !endDate} onClick={() => void submitEnd()}>End term</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default AgentCommissionTerms;
