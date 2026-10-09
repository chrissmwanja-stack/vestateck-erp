import { useEffect, useState } from 'react';
import { Box, Button, Card, CardContent, CircularProgress, MenuItem, Table, TableBody, TableCell, TableHead, TableRow, TextField } from '@mui/material';
import { Add } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { errorText, rows, table } from '../../db';
import { formatMoney, POLICY_STATUS_LABEL } from '../../logic';
import type { Policy, PolicyStatus } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader, PolicyStatusChip } from '../../shared';

const POLICY_STATUSES: PolicyStatus[] = ['draft', 'active', 'renewed'];

export default function PoliciesList() {
  const navigate = useNavigate();
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<'all' | 'draft' | 'active' | 'renewed'>('all');

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      try {
        let q = table('ins_policies')
          .select('id, policy_no, status, inception_date, expiry_date, gross_premium, commission_amount, currency, ins_clients(bd_clients(name)), ins_insurers(name), ins_product_lines(name)')
          .order('created_at', { ascending: false });
        if (status !== 'all') q = q.eq('status', status);
        const data = await rows<Policy>(q);
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

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Policies"
        subtitle="Drafts are editable. Binding a policy books the premium and locks it."
        actions={<Button variant="contained" startIcon={<Add />} onClick={() => navigate('/insurance/policies/new')}>New policy</Button>}
      />
      <ErrorBanner message={error} />
      <Card sx={{ mb: 2 }}>
        <CardContent>
          <TextField select size="small" label="Status" value={status} onChange={(e) => setStatus(e.target.value as typeof status)} sx={{ minWidth: 200 }}>
            <MenuItem value="all">All</MenuItem>
            {POLICY_STATUSES.map((s) => (
              <MenuItem key={s} value={s}>{POLICY_STATUS_LABEL[s]}</MenuItem>
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
                {policies.length === 0 ? (
                  <EmptyRow colSpan={8} text="No policies yet." />
                ) : (
                  policies.map((p) => (
                    <TableRow key={p.id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/policies/${p.id}`)}>
                      <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{p.policy_no}</TableCell>
                      <TableCell>{p.ins_clients?.bd_clients?.name ?? '-'}</TableCell>
                      <TableCell>{p.ins_insurers?.name ?? '-'}</TableCell>
                      <TableCell>{p.ins_product_lines?.name ?? '-'}</TableCell>
                      <TableCell>{p.inception_date} to {p.expiry_date}</TableCell>
                      <TableCell align="right">{formatMoney(p.gross_premium, p.currency)}</TableCell>
                      <TableCell align="right">{p.status === 'draft' ? '-' : formatMoney(p.commission_amount, p.currency)}</TableCell>
                      <TableCell><PolicyStatusChip status={p.status} /></TableCell>
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
