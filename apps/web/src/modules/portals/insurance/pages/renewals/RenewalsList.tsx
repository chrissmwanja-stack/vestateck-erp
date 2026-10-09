import { useCallback, useEffect, useMemo, useState } from 'react';
import { Box, Button, Card, CardContent, Chip, CircularProgress, Stack, Table, TableBody, TableCell, TableHead, TableRow, Typography } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { errorText, rows, rpc, table } from '../../db';
import { formatMoney, RENEWAL_BUCKET_LABEL, renewalBucket, type RenewalBucket } from '../../logic';
import type { RenewalRow } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

const ORDER: RenewalBucket[] = ['overdue', 'd0_30', 'd31_60', 'd61_90', 'd91_120'];

// Active policies expiring within 120 days (ins_renewal_pipeline, RLS-scoped).
// "Start renewal" opens a draft that starts on the old expiry date and copies the term.
export default function RenewalsList() {
  const navigate = useNavigate();
  const [items, setItems] = useState<RenewalRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [bucket, setBucket] = useState<'all' | RenewalBucket>('all');
  const [busyId, setBusyId] = useState<string | null>(null);

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

  const counts = useMemo(() => {
    const c: Record<RenewalBucket, number> = { overdue: 0, d0_30: 0, d31_60: 0, d61_90: 0, d91_120: 0, later: 0 };
    for (const r of items) c[renewalBucket(r.days_to_expiry)] += 1;
    return c;
  }, [items]);

  const visible = items.filter((r) => bucket === 'all' || renewalBucket(r.days_to_expiry) === bucket);

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

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader title="Renewals" subtitle="Active policies expiring in the next 120 days, oldest first." />
      <ErrorBanner message={error} />
      <Stack direction="row" spacing={1} sx={{ mb: 2, flexWrap: 'wrap', gap: 1 }}>
        <Chip label={`All (${items.length})`} color={bucket === 'all' ? 'primary' : 'default'} onClick={() => setBucket('all')} />
        {ORDER.map((b) => (
          <Chip key={b} label={`${RENEWAL_BUCKET_LABEL[b]} (${counts[b]})`} color={bucket === b ? 'primary' : 'default'} variant={counts[b] ? 'filled' : 'outlined'} onClick={() => setBucket(b)} />
        ))}
      </Stack>
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Policy</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Insurer</TableCell>
                <TableCell>Expiry</TableCell>
                <TableCell>When</TableCell>
                <TableCell align="right">Last premium</TableCell>
                <TableCell align="right">Action</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {visible.length === 0 ? (
                <EmptyRow colSpan={7} text="Nothing expiring in this window." />
              ) : (
                visible.map((r) => (
                  <TableRow key={r.policy_id} hover>
                    <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.policy_no}</TableCell>
                    <TableCell>{r.client_name}</TableCell>
                    <TableCell>{r.insurer_name}</TableCell>
                    <TableCell>{r.expiry_date}</TableCell>
                    <TableCell>
                      <Typography variant="body2" color={r.days_to_expiry < 0 ? 'error' : 'text.primary'}>
                        {r.days_to_expiry < 0 ? `${-r.days_to_expiry} days overdue` : `${r.days_to_expiry} days`}
                      </Typography>
                    </TableCell>
                    <TableCell align="right">{formatMoney(r.gross_premium, r.currency)}</TableCell>
                    <TableCell align="right">
                      {r.renewal_draft_id ? (
                        <Button size="small" onClick={() => navigate(`/insurance/policies/${r.renewal_draft_id}`)}>Open draft</Button>
                      ) : (
                        <Button size="small" variant="outlined" disabled={busyId === r.policy_id} onClick={() => startRenewal(r)}>
                          Start renewal
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
}
