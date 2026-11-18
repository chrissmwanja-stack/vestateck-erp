import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle,
  Grid, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { allRows, errorText, rows, table } from '../../db';
import { formatMoney } from '../../logic';
import ListToolbar from '../../ListToolbar';
import { EmptyRow, ErrorBanner } from '../../shared';
import AccrualDialogs from './AccrualDialogs';
import { countActive } from '../../listFilters';
import {
  ACCRUAL_SORT_LABEL, AGENT_ACCRUAL_STATUS_LABEL, AGENT_BASIS_LABEL, AGENT_EVENT_AMOUNT_LABEL, AGENT_EVENT_LABEL,
  EMPTY_ACCRUAL_FILTERS, accrualDate, eligibilityLabel, filterAccruals, netOf, registerTotals, sortAccruals, sortEvents,
  withholdingNote, type AccrualFilters, type AccrualSort, type AgentAccrualDetail, type AgentAccrualEvent,
  type AgentAccrualStatus, type CurrencyTotals,
} from '../../agentCommission';

interface PolicyRef { id: string; policy_no: string | null; ins_clients: { bd_clients: { name: string } | null } | null }
interface PersonRef { id: string; name: string | null; email: string | null }

const STATUSES = Object.keys(AGENT_ACCRUAL_STATUS_LABEL) as AgentAccrualStatus[];

/** One line per currency; currencies are never added together. */
const perCurrency = (totals: CurrencyTotals): string => {
  const entries = Object.entries(totals);
  return entries.length === 0 ? '-' : entries.map(([c, v]) => formatMoney(v, c)).join(' · ');
};

const when = (iso: string) => new Date(iso).toLocaleString();

const AgentCommissionAccruals = () => {
  const [accruals, setAccruals] = useState<AgentAccrualDetail[]>([]);
  const [agents, setAgents] = useState<Record<string, string>>({});
  const [policies, setPolicies] = useState<Record<string, PolicyRef>>({});
  const [people, setPeople] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [filters, setFilters] = useState<AccrualFilters>(EMPTY_ACCRUAL_FILTERS);
  const [sort, setSort] = useState<AccrualSort>('newest');

  const [selected, setSelected] = useState<AgentAccrualDetail | null>(null);
  const [events, setEvents] = useState<AgentAccrualEvent[]>([]);
  const [eventsLoading, setEventsLoading] = useState(false);
  const [eventsError, setEventsError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [acc, ints, pols, ppl] = await Promise.all([
        allRows<AgentAccrualDetail>(() => table('ins_agent_commission_accruals').select('*').order('created_at', { ascending: false }).order('id')),
        allRows<{ id: string; name: string }>(() => table('ins_intermediaries').select('id, name').order('id')),
        allRows<PolicyRef>(() => table('ins_policies').select('id, policy_no, ins_clients(bd_clients(name))').order('id')),
        rows<PersonRef>(table('app_users').select('id, name, email').order('name', { ascending: true })),
      ]);
      setAccruals(acc);
      setAgents(Object.fromEntries(ints.map((i) => [i.id, i.name])));
      setPolicies(Object.fromEntries(pols.map((p) => [p.id, p])));
      setPeople(Object.fromEntries(ppl.map((u) => [u.id, u.name ?? u.email ?? 'Unknown'])));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  // The history of one accrual, fetched when its detail opens. A reply for a row that is no
  // longer selected is dropped, so closing and opening another never shows the wrong history.
  const selectedId = selected?.id ?? null;
  useEffect(() => {
    if (!selectedId) return undefined;
    let cancelled = false;
    setEvents([]);
    setEventsError(null);
    setEventsLoading(true);
    (async () => {
      try {
        const data = await rows<AgentAccrualEvent>(
          table('ins_agent_commission_events').select('*').eq('accrual_id', selectedId).order('created_at', { ascending: true }).order('id'),
        );
        if (!cancelled) setEvents(sortEvents(data));
      } catch (e) {
        if (!cancelled) setEventsError(errorText(e));
      } finally {
        if (!cancelled) setEventsLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [selectedId]);

  const labels = useMemo(() => ({
    agent: (a: { intermediary_id: string }) => agents[a.intermediary_id] ?? '',
    policy: (a: { policy_id: string }) => policies[a.policy_id]?.policy_no ?? '',
    client: (a: { policy_id: string }) => policies[a.policy_id]?.ins_clients?.bd_clients?.name ?? '',
  }), [agents, policies]);
  const nameOf = (id: string | null) => (id ? people[id] ?? 'Another user' : 'System');
  // Only policies that name an intermediary can ever be accrued; offering the
  // rest would be offering a refusal.
  const policyOptions = useMemo(
    () => Object.values(policies)
      .filter((p) => p.policy_no)
      .map((p) => ({ id: p.id, policy_no: p.policy_no }))
      .sort((x, y) => (x.policy_no ?? '').localeCompare(y.policy_no ?? '')),
    [policies],
  );

  // Dropdown choices come from the rows themselves, so only values in use are offered.
  const agentOptions = useMemo(
    () => [...new Set(accruals.map((a) => a.intermediary_id))]
      .map((id) => ({ id, name: agents[id] ?? id })).sort((x, y) => x.name.localeCompare(y.name)),
    [accruals, agents],
  );
  const basisOptions = useMemo(() => [...new Set(accruals.map((a) => a.basis))].sort(), [accruals]);
  const currencyOptions = useMemo(() => [...new Set(accruals.map((a) => a.currency))].sort(), [accruals]);

  const visible = useMemo(
    () => sortAccruals(filterAccruals(accruals, filters, labels), sort, labels),
    [accruals, filters, sort, labels],
  );
  const totals = useMemo(() => registerTotals(visible), [visible]);
  const set = (patch: Partial<AccrualFilters>) => setFilters((f) => ({ ...f, ...patch }));

  if (loading) return <CircularProgress />;

  return (
    <Box>
      <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 720, mb: 2 }}>
        Every share of brokerage commission owed to a sub-agent or referral partner, one row per policy and intermediary.
        Figures are the ones copied when the commission accrued, so a later change of terms or tax rate does not rewrite them.
      </Typography>
      <ErrorBanner message={error} />

      <AccrualDialogs onDone={() => void load()} policyOptions={policyOptions} />

      <ListToolbar
        search={filters.text}
        onSearch={(text) => set({ text })}
        placeholder="Search agent, policy no or client"
        shown={visible.length}
        total={accruals.length}
        noun="accruals"
        activeCount={countActive({ ...filters })}
        onClear={() => setFilters(EMPTY_ACCRUAL_FILTERS)}
      >
        <TextField select size="small" label="Agent" value={filters.agentId} onChange={(e) => set({ agentId: e.target.value })} sx={{ minWidth: 160 }}>
          <MenuItem value="">All</MenuItem>
          {agentOptions.map((o) => <MenuItem key={o.id} value={o.id}>{o.name}</MenuItem>)}
        </TextField>
        <TextField select size="small" label="Status" value={filters.status} onChange={(e) => set({ status: e.target.value as AccrualFilters['status'] })} sx={{ minWidth: 160 }}>
          <MenuItem value="">All</MenuItem>
          {STATUSES.map((s) => <MenuItem key={s} value={s}>{AGENT_ACCRUAL_STATUS_LABEL[s]}</MenuItem>)}
        </TextField>
        <TextField select size="small" label="Basis" value={filters.basis} onChange={(e) => set({ basis: e.target.value })} sx={{ minWidth: 200 }}>
          <MenuItem value="">All</MenuItem>
          {basisOptions.map((b) => <MenuItem key={b} value={b}>{AGENT_BASIS_LABEL[b] ?? b}</MenuItem>)}
        </TextField>
        <TextField select size="small" label="Currency" value={filters.currency} onChange={(e) => set({ currency: e.target.value })} sx={{ minWidth: 120 }}>
          <MenuItem value="">All</MenuItem>
          {currencyOptions.map((c) => <MenuItem key={c} value={c}>{c}</MenuItem>)}
        </TextField>
        <TextField size="small" type="date" label="Accrued from" InputLabelProps={{ shrink: true }} value={filters.accruedFrom} onChange={(e) => set({ accruedFrom: e.target.value })} />
        <TextField size="small" type="date" label="Accrued to" InputLabelProps={{ shrink: true }} value={filters.accruedTo} onChange={(e) => set({ accruedTo: e.target.value })} />
        <TextField select size="small" label="Sort" value={sort} onChange={(e) => setSort(e.target.value as AccrualSort)} sx={{ minWidth: 160 }}>
          {(Object.keys(ACCRUAL_SORT_LABEL) as AccrualSort[]).map((s) => <MenuItem key={s} value={s}>{ACCRUAL_SORT_LABEL[s]}</MenuItem>)}
        </TextField>
      </ListToolbar>

      <Card>
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Agent</TableCell><TableCell>Policy</TableCell><TableCell>Client</TableCell><TableCell>Basis</TableCell>
                <TableCell align="right">Gross</TableCell><TableCell align="right">Withholding</TableCell><TableCell align="right">Net</TableCell>
                <TableCell>Currency</TableCell><TableCell>Accrual date</TableCell><TableCell>Eligibility</TableCell><TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {visible.length === 0 && (
                <EmptyRow colSpan={11} text={accruals.length === 0 ? 'No agent commission has accrued yet.' : 'No accruals match these filters.'} />
              )}
              {visible.map((a) => (
                <TableRow key={a.id} hover sx={{ cursor: 'pointer' }} onClick={() => setSelected(a)}>
                  <TableCell>
                    <Button size="small" sx={{ textTransform: 'none', p: 0, minWidth: 0 }} onClick={(e) => { e.stopPropagation(); setSelected(a); }}>
                      {agents[a.intermediary_id] ?? '-'}
                    </Button>
                  </TableCell>
                  <TableCell>{policies[a.policy_id]?.policy_no ?? '-'}</TableCell>
                  <TableCell>{labels.client(a) || '-'}</TableCell>
                  <TableCell>{AGENT_BASIS_LABEL[a.basis] ?? a.basis}</TableCell>
                  <TableCell align="right">{formatMoney(a.gross_amount, a.currency)}</TableCell>
                  <TableCell align="right">{formatMoney(a.wht_amount, a.currency)}</TableCell>
                  <TableCell align="right">{formatMoney(netOf(a), a.currency)}</TableCell>
                  <TableCell>{a.currency}</TableCell>
                  <TableCell>{accrualDate(a)}</TableCell>
                  <TableCell>{eligibilityLabel(a)}</TableCell>
                  <TableCell><Chip size="small" label={AGENT_ACCRUAL_STATUS_LABEL[a.status]} /></TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {visible.length > 0 && (
        <Box sx={{ mt: 2 }} role="region" aria-label="Totals of the accruals shown">
          <Typography variant="body2" color="text.secondary">
            Totals of the rows shown, reversed accruals left out. Each currency is totalled on its own.
          </Typography>
          <Typography variant="body2">Gross: {perCurrency(totals.gross)}</Typography>
          <Typography variant="body2">Withholding: {perCurrency(totals.withholding)}</Typography>
          <Typography variant="body2" fontWeight={600}>Net payable to agents: {perCurrency(totals.net)}</Typography>
        </Box>
      )}

      <Dialog open={selected !== null} onClose={() => setSelected(null)} fullWidth maxWidth="md">
        {selected && (
          <>
            <DialogTitle>
              Accrual: {agents[selected.intermediary_id] ?? 'Agent'}, policy {policies[selected.policy_id]?.policy_no ?? '-'}
            </DialogTitle>
            <DialogContent dividers>
              <Grid container spacing={2} sx={{ mb: 3 }}>
                <Detail label="Client" value={labels.client(selected) || '-'} />
                <Detail label="Status" value={AGENT_ACCRUAL_STATUS_LABEL[selected.status]} />
                <Detail label="Basis" value={AGENT_BASIS_LABEL[selected.basis] ?? selected.basis} />
                <Detail label="Rate or amount used" value={selected.rate_pct !== null ? `${selected.rate_pct}%` : selected.fixed_amount !== null ? formatMoney(selected.fixed_amount, selected.currency) : '-'} />
                <Detail label="Commission it was calculated on" value={formatMoney(selected.commission_base, selected.currency)} />
                <Detail label="Accrual date" value={accrualDate(selected)} />
                <Detail label="Gross" value={formatMoney(selected.gross_amount, selected.currency)} />
                <Detail label="Withholding tax" value={`${formatMoney(selected.wht_amount, selected.currency)} · ${withholdingNote(selected)}`} />
                <Detail label="Net payable" value={formatMoney(netOf(selected), selected.currency)} />
                <Detail label="Eligibility" value={eligibilityLabel(selected)} />
                <Detail label="Paid on" value={selected.paid_at ? when(selected.paid_at) : '-'} />
                {selected.status === 'reversed' && <Detail label="Reversal reason" value={selected.reversal_reason ?? '-'} />}
              </Grid>

              <Typography variant="h6" sx={{ mb: 1 }}>Event history</Typography>
              {eventsError && <Alert severity="error" sx={{ mb: 1 }}>{eventsError}</Alert>}
              {eventsLoading ? <CircularProgress size={24} /> : (
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>When</TableCell><TableCell>Event</TableCell><TableCell align="right">Amount</TableCell>
                      <TableCell>By</TableCell><TableCell>Note</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {events.length === 0 && !eventsError && <EmptyRow colSpan={5} text="No events recorded for this accrual." />}
                    {events.map((ev) => (
                      <TableRow key={ev.id}>
                        <TableCell>{when(ev.created_at)}</TableCell>
                        <TableCell>{AGENT_EVENT_LABEL[ev.event] ?? ev.event}</TableCell>
                        <TableCell align="right">
                          {ev.amount === null ? '-' : (
                            <Stack alignItems="flex-end">
                              <span>{formatMoney(ev.amount, selected.currency)}</span>
                              <Typography variant="caption" color="text.secondary">{AGENT_EVENT_AMOUNT_LABEL[ev.event]}</Typography>
                            </Stack>
                          )}
                        </TableCell>
                        <TableCell>{nameOf(ev.actor_id)}</TableCell>
                        <TableCell>{ev.note ?? '-'}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </DialogContent>
            <DialogActions><Button onClick={() => setSelected(null)}>Close</Button></DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
};

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <Grid item xs={12} sm={6} md={4}>
      <Typography variant="caption" color="text.secondary">{label}</Typography>
      <Typography variant="body2">{value}</Typography>
    </Grid>
  );
}

export default AgentCommissionAccruals;