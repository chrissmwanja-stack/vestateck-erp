import { useCallback, useEffect, useState, type ReactNode } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogContentText,
  DialogTitle, Grid, Stack, Table, TableBody, TableCell, TableHead, TableRow, Typography,
} from '@mui/material';
import { useNavigate, useParams } from 'react-router-dom';
import { errorText, rows, rpc, table, write } from '../../db';
import { useInsuranceAccess } from '../../access';
import { ClaimStatusChip, EmptyRow, ErrorBanner, PageHeader, PolicyStatusChip } from '../../shared';
import { commissionSplit, daysBetween, formatMoney, policyTermDays } from '../../logic';
import type { Claim, Policy } from '../../types';

const PolicyDetail = () => {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const { canManage } = useInsuranceAccess();
  const [policy, setPolicy] = useState<Policy | null>(null);
  const [claims, setClaims] = useState<Claim[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmBind, setConfirmBind] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [p] = await rows<Policy>(
        table('ins_policies')
          .select('*, ins_clients(bd_clients(name)), ins_insurers(name), ins_product_lines(name)')
          .eq('id', id),
      );
      setPolicy(p ?? null);
      setClaims(
        await rows<Claim>(table('ins_claims').select('id, claim_no, status, loss_date, reserve_amount, approved_amount, paid_amount, created_at, loss_description, notified_date, insurer_claim_ref, policy_id, settled_at').eq('policy_id', id).order('created_at', { ascending: false })),
      );
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  const bind = async () => {
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_bind_policy', { p_policy_id: id });
      setConfirmBind(false);
      await load();
    } catch (e) {
      setError(errorText(e));
      setConfirmBind(false);
    } finally {
      setBusy(false);
    }
  };

  const renew = async () => {
    setBusy(true);
    setError(null);
    try {
      const draft = await rpc<{ id: string }>('ins_create_renewal_draft', { p_policy_id: id });
      navigate(`/insurance/policies/${draft.id}`);
    } catch (e) {
      setError(errorText(e));
      setBusy(false);
    }
  };

  const remove = async () => {
    setBusy(true);
    try {
      await write(table('ins_policies').delete().eq('id', id));
      navigate('/insurance/policies');
    } catch (e) {
      setError(errorText(e));
      setBusy(false);
      setConfirmDelete(false);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;
  if (!policy) return <Box sx={{ p: 3 }}><Alert severity="warning">Policy not found, or you do not have access to it.</Alert></Box>;

  const split = commissionSplit(policy.gross_premium, policy.commission_rate_pct);
  const term = policyTermDays(policy.inception_date, policy.expiry_date);
  const daysLeft = daysBetween(new Date().toISOString().slice(0, 10), policy.expiry_date);

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <PageHeader
        title={policy.policy_no}
        subtitle={`${policy.ins_clients?.bd_clients?.name ?? 'Client'} · ${policy.ins_insurers?.name ?? 'Insurer'} · ${policy.ins_product_lines?.name ?? 'Product'}`}
        actions={
          <Stack direction="row" spacing={1} alignItems="center">
            <PolicyStatusChip status={policy.status} />
            {canManage && policy.status === 'draft' && (
              <Button variant="contained" color="primary" onClick={() => setConfirmBind(true)} disabled={busy}>Bind policy</Button>
            )}
            {canManage && policy.status === 'draft' && (
              <Button color="error" onClick={() => setConfirmDelete(true)} disabled={busy}>Delete draft</Button>
            )}
            {policy.status === 'active' && (
              <Button variant="outlined" onClick={renew} disabled={busy}>Start renewal</Button>
            )}
            {policy.status !== 'draft' && (
              <Button variant="outlined" onClick={() => navigate(`/insurance/claims/new?policy=${policy.id}`)}>Report claim</Button>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {policy.status === 'draft' && (
        <Alert severity="info" sx={{ mb: 2 }}>
          This is a draft. Binding books the premium: the client is billed the gross premium, the insurer is owed the net, and the commission is recognised. Bound policies are locked.
        </Alert>
      )}

      <Grid container spacing={2}>
        <Grid item xs={12} md={6}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="subtitle2" gutterBottom>Cover</Typography>
              <Row label="Period" value={`${policy.inception_date} to ${policy.expiry_date} (${term} days)`} />
              <Row label="Days to expiry" value={policy.status === 'draft' ? '-' : daysLeft < 0 ? `Expired ${-daysLeft} days ago` : `${daysLeft}`} />
              <Row label="Sum insured" value={formatMoney(policy.sum_insured, policy.currency)} />
              <Row label="Risk" value={policy.risk_description ?? '-'} />
              {policy.renewal_of_id && <Row label="Renewal of" value={<Button size="small" onClick={() => navigate(`/insurance/policies/${policy.renewal_of_id}`)}>Previous policy</Button>} />}
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="subtitle2" gutterBottom>Premium</Typography>
              <Row label="Gross premium (billed to client)" value={formatMoney(policy.gross_premium, policy.currency)} />
              <Row label="Commission rate" value={`${Number(policy.commission_rate_pct).toFixed(2)}%`} />
              <Row
                label="Commission (brokerage)"
                value={policy.status === 'draft' ? `${formatMoney(split.commission, policy.currency)} (preview)` : formatMoney(policy.commission_amount, policy.currency)}
              />
              <Row
                label="Net to insurer"
                value={policy.status === 'draft' ? `${formatMoney(split.net, policy.currency)} (preview)` : formatMoney(policy.net_premium_to_insurer, policy.currency)}
              />
              {policy.bound_at && <Row label="Bound" value={new Date(policy.bound_at).toLocaleString()} />}
              {policy.journal_entry_id && <Row label="Journal entry" value={<Chip size="small" variant="outlined" label={policy.journal_entry_id.slice(0, 8)} />} />}
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Box sx={{ mt: 3 }}>
        <Typography variant="h6" gutterBottom>Claims on this policy</Typography>
        <Card variant="outlined">
          <CardContent sx={{ p: 0 }}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Claim no</TableCell>
                  <TableCell>Loss date</TableCell>
                  <TableCell>Description</TableCell>
                  <TableCell align="right">Reserve</TableCell>
                  <TableCell>Status</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {claims.length === 0 ? (
                  <EmptyRow colSpan={5} text="No claims on this policy." />
                ) : (
                  claims.map((c) => (
                    <TableRow key={c.id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/claims/${c.id}`)}>
                      <TableCell sx={{ fontFamily: 'monospace' }}>{c.claim_no}</TableCell>
                      <TableCell>{c.loss_date}</TableCell>
                      <TableCell>{c.loss_description}</TableCell>
                      <TableCell align="right">{formatMoney(c.reserve_amount, policy.currency)}</TableCell>
                      <TableCell><ClaimStatusChip status={c.status} /></TableCell>
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      </Box>

      <Dialog open={confirmBind} onClose={() => !busy && setConfirmBind(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Bind {policy.policy_no}?</DialogTitle>
        <DialogContent>
          <DialogContentText component="div">
            <p>This books the premium in the ledger on the inception date:</p>
            <ul>
              <li>Receivable from the client: <strong>{formatMoney(policy.gross_premium, policy.currency)}</strong></li>
              <li>Payable to the insurer: <strong>{formatMoney(split.net, policy.currency)}</strong></li>
              <li>Commission income: <strong>{formatMoney(split.commission, policy.currency)}</strong></li>
            </ul>
            <p>The policy is then locked. Binding cannot be undone from this screen. A bound policy is corrected by a reversing entry (not yet available in this release).</p>
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setConfirmBind(false)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={bind} disabled={busy}>{busy ? 'Binding…' : 'Bind policy'}</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={confirmDelete} onClose={() => !busy && setConfirmDelete(false)}>
        <DialogTitle>Delete draft {policy.policy_no}?</DialogTitle>
        <DialogContent>
          <DialogContentText>Only the draft is removed. Its number is not reused.</DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setConfirmDelete(false)} disabled={busy}>Cancel</Button>
          <Button color="error" variant="contained" onClick={remove} disabled={busy}>Delete</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

function Row({ label, value }: { label: string; value: ReactNode }) {
  return (
    <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ py: 0.5, gap: 2 }}>
      <Typography variant="body2" color="text.secondary">{label}</Typography>
      <Typography variant="body2" sx={{ textAlign: 'right' }}>{value}</Typography>
    </Stack>
  );
}

export default PolicyDetail;
