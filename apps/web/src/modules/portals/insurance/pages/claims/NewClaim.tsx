import { useEffect, useState } from 'react';
import { Alert, Box, Button, Card, CardContent, CircularProgress, Grid, MenuItem, Stack, TextField } from '@mui/material';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { errorText, rows, rpc, table } from '../../db';
import { formatMoney } from '../../logic';
import type { Policy } from '../../types';
import { ErrorBanner, PageHeader } from '../../shared';

const today = () => new Date().toISOString().slice(0, 10);

// Notifies a loss against a bound policy. Assessment and decisions happen on the claim detail page.
export default function NewClaim() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({
    policyId: params.get('policy') ?? '',
    lossDate: today(),
    notifiedDate: today(),
    description: '',
    insurerRef: '',
    reserve: '0',
  });

  useEffect(() => {
    (async () => {
      try {
        // Only bound policies can have claims.
        setPolicies(
          await rows<Policy>(
            table('ins_policies')
              .select('id, policy_no, status, currency, sum_insured, expiry_date, ins_clients(bd_clients(name))')
              .in('status', ['active', 'renewed'])
              .order('expiry_date', { ascending: false }),
          ),
        );
      } catch (e) {
        setError(errorText(e));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const policy = policies.find((p) => p.id === form.policyId);
  const reserve = Number(form.reserve) || 0;
  const problems: string[] = [];
  if (!form.policyId) problems.push('Choose a policy.');
  if (!form.description.trim()) problems.push('Describe the loss.');
  if (form.lossDate && form.notifiedDate && form.notifiedDate < form.lossDate) problems.push('The notified date cannot be before the loss date.');
  if (policy && form.lossDate && (form.lossDate < dateOnly(policy.inception_date) || form.lossDate > policy.expiry_date)) {
    problems.push(`The loss date must fall within the policy period (${policy.inception_date} to ${policy.expiry_date}).`);
  }
  if (reserve < 0) problems.push('The reserve cannot be negative.');
  if (policy && policy.sum_insured > 0 && reserve > policy.sum_insured) problems.push('The reserve cannot exceed the sum insured.');

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const claim = await rpc<{ id: string }>('ins_create_claim', {
        p_policy_id: form.policyId,
        p_loss_date: form.lossDate,
        p_notified_date: form.notifiedDate,
        p_loss_description: form.description.trim(),
        p_insurer_claim_ref: form.insurerRef.trim() || null,
        p_reserve_amount: reserve,
      });
      navigate(`/insurance/claims/${claim.id}`);
    } catch (e) {
      setError(errorText(e));
      setSaving(false);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <PageHeader title="Report claim" subtitle="Notify a loss against a bound policy." />
      <ErrorBanner message={error} />
      {policies.length === 0 && <Alert severity="info" sx={{ mb: 2 }}>There are no bound policies to claim against.</Alert>}
      <Card>
        <CardContent>
          <Grid container spacing={2}>
            <Grid item xs={12}>
              <TextField select fullWidth label="Policy" required value={form.policyId} onChange={(e) => setForm({ ...form, policyId: e.target.value })}>
                {policies.map((p) => (
                  <MenuItem key={p.id} value={p.id}>
                    {p.policy_no} · {p.ins_clients?.bd_clients?.name ?? 'Client'} · expires {p.expiry_date}
                  </MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Loss date" InputLabelProps={{ shrink: true }} value={form.lossDate} onChange={(e) => setForm({ ...form, lossDate: e.target.value })} />
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Notified date" InputLabelProps={{ shrink: true }} value={form.notifiedDate} onChange={(e) => setForm({ ...form, notifiedDate: e.target.value })} />
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField fullWidth label="Insurer claim reference" value={form.insurerRef} onChange={(e) => setForm({ ...form, insurerRef: e.target.value })} />
            </Grid>
            <Grid item xs={12}>
              <TextField fullWidth label="Description of loss" required multiline minRows={3} value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField fullWidth type="number" label={`Initial reserve${policy ? ` (${policy.currency})` : ''}`} value={form.reserve}
                onChange={(e) => setForm({ ...form, reserve: e.target.value })} inputProps={{ min: 0, step: '0.01' }}
                helperText={policy ? `Estimated exposure. Sum insured ${formatMoney(policy.sum_insured, policy.currency)}.` : 'Estimated exposure.'} />
            </Grid>
          </Grid>
          {problems.length > 0 && form.policyId && (
            <Alert severity="warning" sx={{ mt: 2 }}>
              {problems.map((p) => <div key={p}>{p}</div>)}
            </Alert>
          )}
          <Stack direction="row" spacing={1} justifyContent="flex-end" sx={{ mt: 3 }}>
            <Button onClick={() => navigate('/insurance/claims')}>Cancel</Button>
            <Button variant="contained" onClick={save} disabled={saving || problems.length > 0}>
              {saving ? 'Saving…' : 'Report claim'}
            </Button>
          </Stack>
        </CardContent>
      </Card>
    </Box>
  );
}

function dateOnly(v: string): string {
  return v.slice(0, 10);
}
