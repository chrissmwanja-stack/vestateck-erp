import { useEffect, useMemo, useState } from 'react';
import { Box, Button, Card, CardContent, CircularProgress, MenuItem, Table, TableBody, TableCell, TableHead, TableRow, TextField } from '@mui/material';
import ListToolbar from '../../ListToolbar';
import {
  EMPTY_POLICY_FILTERS, POLICY_SORT_LABEL, countActive, distinctOptions, filterPolicies, sortPolicies, type PolicyFilters, type PolicySort,
} from '../../listFilters';
import { Add } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { allRows, errorText, table } from '../../db';
import { formatMoney, POLICY_DISPLAY_STATUS_LABEL, type PolicyDisplayStatus } from '../../logic';
import { localIsoDate } from '../../fx';
import type { Policy } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader, PolicyStatusChip } from '../../shared';

const POLICY_STATUSES: PolicyDisplayStatus[] = ['draft', 'active', 'expired', 'renewed', 'reversed', 'cancelled'];

export default function PoliciesList() {
  const navigate = useNavigate();
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<'all' | PolicyDisplayStatus>('all');
  const [filters, setFilters] = useState<PolicyFilters>(EMPTY_POLICY_FILTERS);
  const [sort, setSort] = useState<PolicySort>('newest');

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      try {
        const data = await allRows<Policy>(() => {
          let q = table('ins_policies')
            .select('id, policy_no, status, insurer_id, product_line_id, inception_date, expiry_date, gross_premium, commission_amount, currency, ins_clients(bd_clients(name)), ins_insurers(name), ins_product_lines(name)')
            .order('created_at', { ascending: false })
            .order('id');
          // 'expired' is not stored: it is an active policy whose expiry date has passed.
          const today = localIsoDate();
          if (status === 'expired') q = q.eq('status', 'active').lt('expiry_date', today);
          else if (status === 'active') q = q.eq('status', 'active').gte('expiry_date', today);
          else if (status !== 'all') q = q.eq('status', status);
          return q;
        });
        if (!cancelled) {
          setPolicies(data);
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
  }, [status]);

  // Insurer and product choices come from the policies themselves, so only ones in use are offered.
  const insurerOptions = useMemo(() => distinctOptions(policies, (p) => p.insurer_id, (p) => p.ins_insurers?.name), [policies]);
  const productOptions = useMemo(() => distinctOptions(policies, (p) => p.product_line_id, (p) => p.ins_product_lines?.name), [policies]);
  const visible = useMemo(() => sortPolicies(filterPolicies(policies, filters), sort), [policies, filters, sort]);
  const set = (patch: Partial<PolicyFilters>) => setFilters((f) => ({ ...f, ...patch }));
  const activeCount = countActive({ ...filters, status });

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Policies"
        subtitle="Drafts are editable. Binding a policy books the premium and locks it."
        actions={<Button variant="contained" startIcon={<Add />} onClick={() => navigate('/insurance/policies/new')}>New policy</Button>}
      />
      <ErrorBanner message={error} />
      <ListToolbar
        search={filters.text}
        onSearch={(text) => set({ text })}
        placeholder="Search policy no, client, insurer or product"
        shown={visible.length}
        total={policies.length}
        noun="policies"
        activeCount={activeCount}
        onClear={() => { setFilters(EMPTY_POLICY_FILTERS); setStatus('all'); }}
      >
        <TextField select size="small" label="Status" value={status} onChange={(e) => setStatus(e.target.value as typeof status)} sx={{ minWidth: 160 }}>
          <MenuItem value="all">All</MenuItem>
          {POLICY_STATUSES.map((s) => (
            <MenuItem key={s} value={s}>{POLICY_DISPLAY_STATUS_LABEL[s]}</MenuItem>
          ))}
        </TextField>
        <TextField select size="small" label="Insurer" value={filters.insurerId} onChange={(e) => set({ insurerId: e.target.value })} sx={{ minWidth: 160 }}>
          <MenuItem value="">All</MenuItem>
          {insurerOptions.map((o) => <MenuItem key={o.id} value={o.id}>{o.name}</MenuItem>)}
        </TextField>
        <TextField select size="small" label="Product" value={filters.productLineId} onChange={(e) => set({ productLineId: e.target.value })} sx={{ minWidth: 160 }}>
          <MenuItem value="">All</MenuItem>
          {productOptions.map((o) => <MenuItem key={o.id} value={o.id}>{o.name}</MenuItem>)}
        </TextField>
        <TextField size="small" type="date" label="Expires from" InputLabelProps={{ shrink: true }} value={filters.expiresFrom} onChange={(e) => set({ expiresFrom: e.target.value })} />
        <TextField size="small" type="date" label="Expires to" InputLabelProps={{ shrink: true }} value={filters.expiresTo} onChange={(e) => set({ expiresTo: e.target.value })} />
        <TextField select size="small" label="Sort" value={sort} onChange={(e) => setSort(e.target.value as PolicySort)} sx={{ minWidth: 180 }}>
          {(Object.keys(POLICY_SORT_LABEL) as PolicySort[]).map((s) => <MenuItem key={s} value={s}>{POLICY_SORT_LABEL[s]}</MenuItem>)}
        </TextField>
      </ListToolbar>
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <Card>
          <CardContent sx={{ p: 0 }}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Policy no</TableCell>
                  <TableCell>Client</TableCell>
                  <TableCell>Insurer</TableCell>
                  <TableCell>Product</TableCell>
                  <TableCell>Period</TableCell>
                  <TableCell align="right">Premium</TableCell>
                  <TableCell align="right">Commission</TableCell>
                  <TableCell>Status</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {visible.length === 0 ? (
                  <EmptyRow colSpan={8} text={policies.length === 0 ? 'No policies yet.' : 'No policies match these filters.'} />
                ) : (
                  visible.map((p) => (
                    <TableRow key={p.id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/policies/${p.id}`)}>
                      <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{p.policy_no}</TableCell>
                      <TableCell>{p.ins_clients?.bd_clients?.name ?? '-'}</TableCell>
                      <TableCell>{p.ins_insurers?.name ?? '-'}</TableCell>
                      <TableCell>{p.ins_product_lines?.name ?? '-'}</TableCell>
                      <TableCell>{p.inception_date} to {p.expiry_date}</TableCell>
                      <TableCell align="right">{formatMoney(p.gross_premium, p.currency)}</TableCell>
                      <TableCell align="right">{p.status === 'draft' ? '-' : formatMoney(p.commission_amount, p.currency)}</TableCell>
                      <TableCell><PolicyStatusChip status={p.status} expiryDate={p.expiry_date} /></TableCell>
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
