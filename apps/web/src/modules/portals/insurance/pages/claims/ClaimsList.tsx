import { useEffect, useMemo, useState } from 'react';
import { Box, Button, Card, CardContent, CircularProgress, MenuItem, Table, TableBody, TableCell, TableHead, TableRow, TextField } from '@mui/material';
import { Add } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { allRows, errorText, table } from '../../db';
import { CLAIM_STATUS_LABEL, formatMoney, isClaimOpen } from '../../logic';
import type { Claim, ClaimStatus } from '../../types';
import { ClaimStatusChip, EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import ListToolbar from '../../ListToolbar';
import { EMPTY_CLAIM_FILTERS, countActive, distinctOptions, filterClaims, type ClaimFilters } from '../../listFilters';

export default function ClaimsList() {
  const navigate = useNavigate();
  const [claims, setClaims] = useState<Claim[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<'all' | 'open' | ClaimStatus>('open');
  const [filters, setFilters] = useState<ClaimFilters>(EMPTY_CLAIM_FILTERS);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      try {
        const data = await allRows<Claim>(() => {
          let q = table('ins_claims')
            .select('id, claim_no, status, loss_date, notified_date, loss_description, insurer_claim_ref, reserve_amount, approved_amount, paid_amount, policy_id, created_at, ins_policies(policy_no, sum_insured, currency, insurer_id, ins_insurers(name), ins_clients(bd_clients(name)))')
            .order('created_at', { ascending: false })
            .order('id');
          if (filter !== 'all' && filter !== 'open') q = q.eq('status', filter);
          return q;
        });
        if (!cancelled) {
          setClaims(filter === 'open' ? data.filter((c) => isClaimOpen(c.status)) : data);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(errorText(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [filter]);

  const insurerOptions = useMemo(() => distinctOptions(claims, (c) => c.ins_policies?.insurer_id, (c) => c.ins_policies?.ins_insurers?.name), [claims]);
  const visible = useMemo(() => filterClaims(claims, filters), [claims, filters]);
  const set = (patch: Partial<ClaimFilters>) => setFilters((f) => ({ ...f, ...patch }));
  const activeCount = countActive({ ...filters, show: filter }, { show: 'open' }) + (filter === 'all' ? 1 : 0);

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Claims"
        subtitle="Notified losses, from assessment through settlement."
        actions={<Button variant="contained" startIcon={<Add />} onClick={() => navigate('/insurance/claims/new')}>Report claim</Button>}
      />
      <ErrorBanner message={error} />
      <ListToolbar
        search={filters.text}
        onSearch={(text) => set({ text })}
        placeholder="Search claim no, policy, client, description or insurer ref"
        shown={visible.length}
        total={claims.length}
        noun="claims"
        activeCount={activeCount}
        onClear={() => { setFilters(EMPTY_CLAIM_FILTERS); setFilter('open'); }}
      >
        <TextField select size="small" label="Show" value={filter} onChange={(e) => setFilter(e.target.value as typeof filter)} sx={{ minWidth: 160 }}>
          <MenuItem value="open">Open</MenuItem>
          <MenuItem value="all">All</MenuItem>
          {(Object.keys(CLAIM_STATUS_LABEL) as ClaimStatus[]).map((s) => (
            <MenuItem key={s} value={s}>{CLAIM_STATUS_LABEL[s]}</MenuItem>
          ))}
        </TextField>
        <TextField select size="small" label="Insurer" value={filters.insurerId} onChange={(e) => set({ insurerId: e.target.value })} sx={{ minWidth: 160 }}>
          <MenuItem value="">All</MenuItem>
          {insurerOptions.map((o) => <MenuItem key={o.id} value={o.id}>{o.name}</MenuItem>)}
        </TextField>
        <TextField size="small" type="date" label="Loss from" InputLabelProps={{ shrink: true }} value={filters.lossFrom} onChange={(e) => set({ lossFrom: e.target.value })} />
        <TextField size="small" type="date" label="Loss to" InputLabelProps={{ shrink: true }} value={filters.lossTo} onChange={(e) => set({ lossTo: e.target.value })} />
      </ListToolbar>
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <Card>
          <CardContent sx={{ p: 0 }}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Claim no</TableCell>
                  <TableCell>Client</TableCell>
                  <TableCell>Policy</TableCell>
                  <TableCell>Loss date</TableCell>
                  <TableCell>Description</TableCell>
                  <TableCell align="right">Reserve</TableCell>
                  <TableCell align="right">Approved</TableCell>
                  <TableCell>Status</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {visible.length === 0 ? (
                  <EmptyRow colSpan={8} text={claims.length > 0 ? 'No claims match these filters.' : filter === 'open' ? 'No open claims.' : 'No claims match this filter.'} />
                ) : (
                  visible.map((c) => (
                    <TableRow key={c.id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/claims/${c.id}`)}>
                      <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{c.claim_no}</TableCell>
                      <TableCell>{c.ins_policies?.ins_clients?.bd_clients?.name ?? '-'}</TableCell>
                      <TableCell sx={{ fontFamily: 'monospace' }}>{c.ins_policies?.policy_no ?? '-'}</TableCell>
                      <TableCell>{c.loss_date}</TableCell>
                      <TableCell sx={{ maxWidth: 260, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{c.loss_description}</TableCell>
                      <TableCell align="right">{formatMoney(c.reserve_amount, c.ins_policies?.currency)}</TableCell>
                      <TableCell align="right">{c.approved_amount == null ? '-' : formatMoney(c.approved_amount, c.ins_policies?.currency)}</TableCell>
                      <TableCell><ClaimStatusChip status={c.status} /></TableCell>
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}
    </Box>
  );
}
