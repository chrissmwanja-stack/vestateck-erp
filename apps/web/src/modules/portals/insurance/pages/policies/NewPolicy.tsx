import { useEffect, useMemo, useState } from 'react';
import { Alert, Box, Button, Card, CardContent, CircularProgress, Grid, MenuItem, Stack, TextField, Typography } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { errorText, rows, rpc, table } from '../../db';
import { commissionSplit, formatMoney, validatePolicyInput } from '../../logic';
import type { InsClient, Insurer, ProductLine } from '../../types';
import { ErrorBanner, PageHeader } from '../../shared';

const today = () => new Date().toISOString().slice(0, 10);
const oneYearOn = () => {
  const d = new Date();
  d.setFullYear(d.getFullYear() + 1);
  d.setDate(d.getDate() - 1);
  return d.toISOString().slice(0, 10);
};

// Creates a DRAFT policy. Binding (premium booking) is a separate, deliberate step on the detail page.
export default function NewPolicy() {
  const navigate = useNavigate();
  const [clients, setClients] = useState<InsClient[]>([]);
  const [insurers, setInsurers] = useState<Insurer[]>([]);
  const [products, setProducts] = useState<ProductLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({
    clientId: '',
    insurerId: '',
    productLineId: '',
    inception: today(),
    expiry: oneYearOn(),
    sumInsured: '0',
    currency: 'UGX',
    grossPremium: '0',
    commissionRatePct: '0',
    riskDescription: '',
    notes: '',
  });

  useEffect(() => {
    (async () => {
      try {
        const [c, i, p] = await Promise.all([
          rows<InsClient>(table('ins_clients').select('id, client_id, bd_clients(name)').order('created_at', { ascending: false })),
          rows<Insurer>(table('ins_insurers').select('*').eq('is_active', true).order('name', { ascending: true })),
          rows<ProductLine>(table('ins_product_lines').select('*').eq('is_active', true).order('name', { ascending: true })),
        ]);
        setClients(c);
        setInsurers(i);
        setProducts(p);
      } catch (e) {
        setError(errorText(e));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const gross = Number(form.grossPremium) || 0;
  const rate = Number(form.commissionRatePct) || 0;
  const split = useMemo(() => commissionSplit(gross, rate), [gross, rate]);
  const problems = validatePolicyInput({
    clientId: form.clientId,
    insurerId: form.insurerId,
    productLineId: form.productLineId,
    inception: form.inception,
    expiry: form.expiry,
    sumInsured: Number(form.sumInsured) || 0,
    grossPremium: gross,
    commissionRatePct: rate,
  });

  const pickInsurer = (id: string) => {
    const ins = insurers.find((i) => i.id === id);
    setForm({ ...form, insurerId: id, commissionRatePct: ins ? String(ins.default_commission_rate_pct) : form.commissionRatePct });
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const row = await rpc<{ id: string }>('ins_create_policy', {
        p_client_id: form.clientId,
        p_insurer_id: form.insurerId,
        p_product_line_id: form.productLineId,
        p_inception_date: form.inception,
        p_expiry_date: form.expiry,
        p_sum_insured: Number(form.sumInsured) || 0,
        p_currency: form.currency,
        p_gross_premium: gross,
        p_commission_rate_pct: rate,
        p_risk_description: form.riskDescription || null,
        p_notes: form.notes || null,
      });
      navigate(`/insurance/policies/${row.id}`);
    } catch (e) {
      setError(errorText(e));
      setSaving(false);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  const noClients = clients.length === 0;
  const noInsurers = insurers.length === 0;
  const noProducts = products.length === 0;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <PageHeader title="New policy (draft)" subtitle="Saved as a draft. Nothing is booked until you bind it." />
      <ErrorBanner message={error} />
      {(noClients || noInsurers || noProducts) && (
        <Alert severity="info" sx={{ mb: 2 }}>
          {noClients && 'Add a client first. '}
          {noInsurers && 'Add an insurer first. '}
          {noProducts && 'Add a product line first (Admin).'}
        </Alert>
      )}
      <Card>
        <CardContent>
          <Grid container spacing={2}>
            <Grid item xs={12} md={6}>
              <TextField select fullWidth label="Client" required value={form.clientId} onChange={(e) => setForm({ ...form, clientId: e.target.value })}>
                {clients.map((c) => (
                  <MenuItem key={c.id} value={c.id}>{c.bd_clients?.name ?? c.id}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField select fullWidth label="Insurer" required value={form.insurerId} onChange={(e) => pickInsurer(e.target.value)}
                helperText="Selecting an insurer pre-fills its default commission.">
                {insurers.map((i) => (
                  <MenuItem key={i.id} value={i.id}>{i.name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField select fullWidth label="Product line" required value={form.productLineId} onChange={(e) => setForm({ ...form, productLineId: e.target.value })}>
                {products.map((p) => (
                  <MenuItem key={p.id} value={p.id}>{p.name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Inception" InputLabelProps={{ shrink: true }} value={form.inception} onChange={(e) => setForm({ ...form, inception: e.target.value })} />
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Expiry" InputLabelProps={{ shrink: true }} value={form.expiry} onChange={(e) => setForm({ ...form, expiry: e.target.value })} />
            </Grid>
            <Grid item xs={12} md={4}>
              <TextField fullWidth type="number" label="Sum insured" value={form.sumInsured} onChange={(e) => setForm({ ...form, sumInsured: e.target.value })} inputProps={{ min: 0, step: '0.01' }} />
            </Grid>
            <Grid item xs={6} md={4}>
              <TextField fullWidth type="number" label="Gross premium" value={form.grossPremium} onChange={(e) => setForm({ ...form, grossPremium: e.target.value })} inputProps={{ min: 0, step: '0.01' }} />
            </Grid>
            <Grid item xs={6} md={4}>
              <TextField fullWidth type="number" label="Commission (%)" value={form.commissionRatePct} onChange={(e) => setForm({ ...form, commissionRatePct: e.target.value })} inputProps={{ min: 0, max: 99.99, step: '0.01' }} />
            </Grid>
            <Grid item xs={12}>
              <TextField fullWidth label="Risk description" multiline minRows={2} value={form.riskDescription} onChange={(e) => setForm({ ...form, riskDescription: e.target.value })} />
            </Grid>
            <Grid item xs={12}>
              <TextField fullWidth label="Internal notes" multiline minRows={2} value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
            </Grid>
            <Grid item xs={12}>
              <Box sx={{ p: 2, borderRadius: 1, bgcolor: 'action.hover' }}>
                <Typography variant="subtitle2" gutterBottom>On bind (preview)</Typography>
                <Typography variant="body2">
                  Client is billed <strong>{formatMoney(gross, form.currency)}</strong>. Commission to the brokerage{' '}
                  <strong>{formatMoney(split.commission, form.currency)}</strong>. Net remitted to the insurer{' '}
                  <strong>{formatMoney(split.net, form.currency)}</strong>.
                </Typography>
              </Box>
            </Grid>
          </Grid>
          {problems.length > 0 && (
            <Alert severity="warning" sx={{ mt: 2 }}>
              {problems.map((p) => <div key={p}>{p}</div>)}
            </Alert>
          )}
          <Stack direction="row" spacing={1} justifyContent="flex-end" sx={{ mt: 3 }}>
            <Button onClick={() => navigate('/insurance/policies')}>Cancel</Button>
            <Button variant="contained" onClick={save} disabled={saving || problems.length > 0}>
              {saving ? 'Saving…' : 'Save draft'}
            </Button>
          </Stack>
        </CardContent>
      </Card>
    </Box>
  );
}
