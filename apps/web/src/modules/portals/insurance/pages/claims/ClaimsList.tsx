import { useEffect, useState } from 'react';
import { Box, Button, Card, CardContent, CircularProgress, MenuItem, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography } from '@mui/material';
import { Add } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { errorText, rows, table } from '../../db';
import { CLAIM_STATUS_LABEL, formatMoney, isClaimOpen } from '../../logic';
import type { Claim, ClaimStatus } from '../../types';
import { ClaimStatusChip, EmptyRow, ErrorBanner, PageHeader } from '../../shared';

export default function ClaimsList() {
  const navigate = useNavigate();
  const [claims, setClaims] = useState<Claim[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<'all' | 'open' | ClaimStatus>('open');

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      try {
        let q = table('ins_claims')
          .select('id, claim_no, status, loss_date, notified_date, loss_description, reserve_amount, approved_amount, paid_amount, policy_id, created_at, ins_policies(policy_no, sum_insured, currency, ins_clients(bd_clients(name)))')
          .order('created_at', { ascending: false });
        if (filter !== 'all' && filter !== 'open') q = q.eq('status', filter);
        const data = await rows<Claim>(q);
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

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Claims"
        subtitle="Notified losses, from assessment through settlement."
        actions={<Button variant="contained" startIcon={<Add />} onClick={() => navigate('/insurance/claims/new')}>Report claim</Button>}
      />
      <ErrorBanner message={error} />
      <Card sx={{ mb: 2 }}>
        <CardContent>
          <TextField select size="small" label="Show" value={filter} onChange={(e) => setFilter(e.target.value as typeof filter)} sx={{ minWidth: 220 }}>
            <MenuItem value="open">Open</MenuItem>
            <MenuItem value="all">All</MenuItem>
            {(Object.keys(CLAIM_STATUS_LABEL) as ClaimStatus[]).map((s) => (
              <MenuItem key={s} value={s}>{CLAIM_STATUS_LABEL[s]}</MenuItem>
            ))}
          </TextField>
        </CardContent>
      </Card>
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
                {claims.length === 0 ? (
                  <EmptyRow colSpan={8} text={filter === 'open' ? 'No open claims.' : 'No claims match this filter.'} />
                ) : (
                  claims.map((c) => (
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
      <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 2 }}>Claim cash payments and their ledger posting are out of scope for this release.</Typography>
    </Box>
  );
}
