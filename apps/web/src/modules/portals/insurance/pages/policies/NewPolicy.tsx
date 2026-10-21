import { useEffect, useMemo, useState } from 'react';
import { Alert, Box, Button, Card, CardContent, CircularProgress, Grid, MenuItem, Stack, TextField, Typography } from '@mui/material';
import { useNavigate, useParams } from 'react-router-dom';
import { errorText, rows, rpc, table } from '../../db';
import { draftUpdate } from '../../policyDraft';
import { commissionSplit, formatMoney, validatePolicyInput } from '../../logic';
import type { AgentOption, InsClient, Insurer, InsurerProductRate, OrgOption, Policy, ProductLine } from '../../types';
import { KYC_LABEL } from '../../clientKyc';
import { ErrorBanner, PageHeader } from '../../shared';

const today = () => new Date().toISOString().slice(0, 10);
const oneYearOn = () => {
  const d = new Date();
  d.setFullYear(d.getFullYear() + 1);
  d.setDate(d.getDate() - 1);
  return d.toISOString().slice(0, 10);
};

// Creates a DRAFT policy, or edits one when the route has an id. Binding (premium booking) is a separate,
// deliberate step on the detail page. Only drafts can be edited; the server locks a policy once it is bound.
export default function NewPolicy() {
  const navigate = useNavigate();
  const { id: editId } = useParams();
  const editing = Boolean(editId);
  const [policyNo, setPolicyNo] = useState('');
  const [notDraft, setNotDraft] = useState(false);
  // Saved insurer shares own the insurer and commission rate (see draftUpdate).
  const [configured, setConfigured] = useState(false);
  // Linked risks lock the client and product line (the server enforces it too: INS_POLICY_LINKED).
  const [risksLinked, setRisksLinked] = useState(false);
  const [clients, setClients] = useState<InsClient[]>([]);
  const [insurers, setInsurers] = useState<Insurer[]>([]);
  const [products, setProducts] = useState<ProductLine[]>([]);
  const [branches, setBranches] = useState<OrgOption[]>([]);
  const [agents, setAgents] = useState<AgentOption[]>([]);
  const [matrixRates, setMatrixRates] = useState<InsurerProductRate[]>([]);
  // The rate the form was pre-filled with from the approved matrix (shown as a hint, not a lock).
  const [matrixRate, setMatrixRate] = useState<number | null>(null);
  // The company's own currency, and the other currencies that have an approved exchange rate.
  const [functional, setFunctional] = useState('UGX');
  const [otherCurrencies, setOtherCurrencies] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({
    clientId: '',
    insurerId: '',
    productLineId: '',
    branchId: '',
    agentId: '',
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
        const [c, i, p, settings, rates, br, ag, matrix] = await Promise.all([
          rows<InsClient>(table('ins_clients').select('id, client_id, bd_clients(name), kyc_status, risk_rating').order('created_at', { ascending: false })),
          rows<Insurer>(table('ins_insurers').select('*').eq('is_active', true).order('name', { ascending: true })),
          rows<ProductLine>(table('ins_product_lines').select('*').eq('is_active', true).order('name', { ascending: true })),
          rows<{ functional_currency: string }>(table('tenant_ledger_settings').select('functional_currency')),
          // Reading rates is a convenience. If it fails the form still works in the company's currency.
          rows<{ currency: string }>(table('fx_rates').select('currency').eq('status', 'approved')).catch(() => [] as { currency: string }[]),
          // Branch and agent are optional dimensions; a failure to read them leaves the selects empty.
          // Branches live in another module's table, so the insurance-gated RPC resolves them (and the
          // names) for insurance users; edit mode also asks for inactive branches so a draft's saved
          // branch stays selectable.
          rpc<OrgOption[]>('ins_branch_options', { p_include_inactive: Boolean(editId) }).catch(() => [] as OrgOption[]),
          rows<AgentOption>(table('ins_intermediaries').select('id, name, category').eq('status', 'active').order('name', { ascending: true })).catch(() => [] as AgentOption[]),
          // Approved commission matrix rates in force today. If this fails, commission stays manual.
          rows<InsurerProductRate>(
            table('ins_insurer_product_rates').select('insurer_id, product_line_id, rate, effective_from, effective_to')
              .eq('status', 'approved').lte('effective_from', today())
              .or(`effective_to.is.null,effective_to.gte.${today()}`),
          ).catch(() => [] as InsurerProductRate[]),
        ]);
        const own = settings[0]?.functional_currency ?? 'UGX';
        setFunctional(own);
        setOtherCurrencies([...new Set(rates.map((r) => r.currency))].filter((cur) => cur !== own).sort());
        setForm((f) => ({ ...f, currency: own }));
        let ins = i;
        let prods = p;
        let brs = br;
        let ags = ag;
        if (editId) {
          const [pol] = await rows<Policy>(table('ins_policies').select('*').eq('id', editId));
          if (!pol) throw new Error('Policy not found.');
          setPolicyNo(pol.policy_no);
          if (pol.status !== 'draft') setNotDraft(true);
          // A draft may point at an insurer or product line that has since been deactivated; keep it selectable.
          if (!ins.some((x) => x.id === pol.insurer_id)) ins = [...ins, ...(await rows<Insurer>(table('ins_insurers').select('*').eq('id', pol.insurer_id)))];
          if (!prods.some((x) => x.id === pol.product_line_id)) prods = [...prods, ...(await rows<ProductLine>(table('ins_product_lines').select('*').eq('id', pol.product_line_id)))];
          // Same for the agent saved on the draft (it may have been deactivated since; the branch RPC
          // above already includes inactive branches in edit mode).
          if (pol.agent_id && !ags.some((x) => x.id === pol.agent_id)) ags = [...ags, ...(await rows<AgentOption>(table('ins_intermediaries').select('id, name, category').eq('id', pol.agent_id)))];
          const shares = await rows<{ id: string }>(table('ins_policy_insurer_shares').select('id').eq('policy_id', editId));
          setConfigured(shares.length > 0);
          const linked = await rows<{ risk_id: string }>(table('ins_policy_risks').select('risk_id').eq('policy_id', editId));
          setRisksLinked(linked.length > 0);
          setForm({
            clientId: pol.client_id, insurerId: pol.insurer_id, productLineId: pol.product_line_id,
            branchId: pol.branch_id ?? '',
            agentId: pol.agent_id ?? '',
            inception: pol.inception_date, expiry: pol.expiry_date, sumInsured: String(pol.sum_insured), currency: pol.currency,
            grossPremium: String(pol.gross_premium), commissionRatePct: String(pol.commission_rate_pct),
            riskDescription: pol.risk_description ?? '', notes: pol.notes ?? '',
          });
          // A draft saved in a currency that has since lost its rate must still show that currency.
          if (pol.currency !== own) setOtherCurrencies((cur) => [...new Set([...cur, pol.currency])].sort());
        }
        setClients(c);
        setInsurers(ins);
        setProducts(prods);
        setBranches(brs);
        setAgents(ags);
        setMatrixRates(matrix);
      } catch (e) {
        setError(errorText(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [editId]);

  // Pre-fill the commission from the approved rate matrix once an insurer AND product line are
  // chosen. The matrix rate is specific to the pair, so it beats the insurer's general default
  // that picking an insurer applies. It is a default, not a lock: the field stays editable, and
  // an existing draft keeps its saved rate (this only runs for new drafts).
  useEffect(() => {
    if (editId || !form.insurerId || !form.productLineId || matrixRates.length === 0) {
      setMatrixRate(null);
      return;
    }
    const day = today();
    const match = matrixRates
      .filter((r) => r.insurer_id === form.insurerId && r.product_line_id === form.productLineId
        && r.effective_from <= day && (!r.effective_to || r.effective_to >= day))
      .sort((a, b) => b.effective_from.localeCompare(a.effective_from))[0];
    if (match) {
      setForm((f) => ({ ...f, commissionRatePct: String(match.rate) }));
      setMatrixRate(match.rate);
    } else {
      setMatrixRate(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editId, form.insurerId, form.productLineId, matrixRates]);

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

  const currencies = [functional, ...otherCurrencies];
  const foreign = form.currency !== functional;
  // A warning, not a block: whether a client whose KYC is not verified may be bound is a
  // compliance decision that has not been made yet (see the UI review, step 3b).
  // A client without a KYC status on the row (nothing fetched) raises no warning.
  const selectedClient = clients.find((c) => c.id === form.clientId) ?? null;
  const kycWarning = selectedClient && selectedClient.kyc_status
    && (selectedClient.kyc_status !== 'verified' || selectedClient.risk_rating === 'high');

  const pickInsurer = (id: string) => {
    const ins = insurers.find((i) => i.id === id);
    setForm({ ...form, insurerId: id, commissionRatePct: ins ? String(ins.default_commission_rate_pct) : form.commissionRatePct });
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      if (editId) {
        // .select('id') returns the rows changed, so a policy bound meanwhile (no longer a draft) shows up as none.
        const changed = await rows<{ id: string }>(table('ins_policies').update(draftUpdate(form, configured, risksLinked)).eq('id', editId).select('id'));
        if (changed.length === 0) throw new Error('This policy is no longer a draft, so it cannot be edited.');
        navigate(`/insurance/policies/${editId}`);
        return;
      }
      const row = await rpc<{ id: string }>('ins_create_policy', {
        p_client_id: form.clientId,
        p_insurer_id: form.insurerId,
        p_product_line_id: form.productLineId,
        p_branch_id: form.branchId || null,
        p_agent_id: form.agentId || null,
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
      <PageHeader
        title={editing ? `Edit draft ${policyNo}` : 'New policy (draft)'}
        subtitle={editing ? 'Changes are saved to the draft. Nothing is booked until you bind it.' : 'Saved as a draft. Nothing is booked until you bind it.'}
      />
      <ErrorBanner message={error} />
      {notDraft && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          This policy has been bound, so it can no longer be edited here.
        </Alert>
      )}
      {risksLinked && (
        <Alert severity="info" sx={{ mb: 2 }}>
          Risks are linked to this draft, so its client and product line are locked. To change them, unlink the risks on the policy page first.
        </Alert>
      )}
      {configured && (
        <Alert severity="info" sx={{ mb: 2 }}>
          This draft has saved insurer shares. Change the insurer and commission in Financial configuration on the policy page.
        </Alert>
      )}
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
              <TextField select fullWidth label="Client" required value={form.clientId} onChange={(e) => setForm({ ...form, clientId: e.target.value })}
                disabled={risksLinked} helperText={risksLinked ? 'Locked while risks are linked.' : undefined}>
                {clients.map((c) => (
                  <MenuItem key={c.id} value={c.id}>{c.bd_clients?.name ?? c.id}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField select fullWidth label="Insurer" required value={form.insurerId} onChange={(e) => pickInsurer(e.target.value)} disabled={configured}
                helperText={configured ? 'Set by the saved insurer shares.' : 'Selecting an insurer pre-fills its default commission.'}>
                {insurers.map((i) => (
                  <MenuItem key={i.id} value={i.id}>{i.name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField select fullWidth label="Product line" required value={form.productLineId} onChange={(e) => setForm({ ...form, productLineId: e.target.value })}
                disabled={risksLinked} helperText={risksLinked ? 'Locked while risks are linked.' : undefined}>
                {products.map((p) => (
                  <MenuItem key={p.id} value={p.id}>{p.name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField select fullWidth label="Branch" value={form.branchId} onChange={(e) => setForm({ ...form, branchId: e.target.value })}
                helperText="Optional: the branch this policy belongs to.">
                <MenuItem value=""><em>None</em></MenuItem>
                {branches.map((b) => (
                  <MenuItem key={b.id} value={b.id}>{b.site_name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} md={6}>
              <TextField select fullWidth label="Agent" value={form.agentId} onChange={(e) => setForm({ ...form, agentId: e.target.value })}
                helperText="Optional: the agent who introduced the policy. Active agents only.">
                <MenuItem value=""><em>None</em></MenuItem>
                {agents.map((a) => (
                  <MenuItem key={a.id} value={a.id}>{a.name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Inception" InputLabelProps={{ shrink: true }} value={form.inception} onChange={(e) => setForm({ ...form, inception: e.target.value })} />
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Expiry" InputLabelProps={{ shrink: true }} value={form.expiry} onChange={(e) => setForm({ ...form, expiry: e.target.value })} />
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField select fullWidth label="Currency" value={form.currency} onChange={(e) => setForm({ ...form, currency: e.target.value })}
                helperText={otherCurrencies.length === 0 ? 'Other currencies appear here once an exchange rate is approved.' : undefined}>
                {currencies.map((cur) => (
                  <MenuItem key={cur} value={cur}>{cur === functional ? `${cur} (company currency)` : cur}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="number" label="Sum insured" value={form.sumInsured} onChange={(e) => setForm({ ...form, sumInsured: e.target.value })} inputProps={{ min: 0, step: '0.01' }} />
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="number" label="Gross premium" value={form.grossPremium} onChange={(e) => setForm({ ...form, grossPremium: e.target.value })} inputProps={{ min: 0, step: '0.01' }} />
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="number" label="Commission (%)" disabled={configured} value={form.commissionRatePct} onChange={(e) => setForm({ ...form, commissionRatePct: e.target.value })}
                inputProps={{ min: 0, max: 99.99, step: '0.01' }}
                helperText={matrixRate != null ? `Pre-filled from the approved rate matrix (${matrixRate}%).` : undefined} />
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
          {foreign && (
            <Alert severity="info" sx={{ mt: 2 }}>
              {form.currency} is not the company currency ({functional}). The draft can be saved, but it cannot be bound until
              foreign-currency posting is finished. Binding is refused with a message until then.
            </Alert>
          )}
          {kycWarning && selectedClient && (
            <Alert severity="warning" sx={{ mt: 2 }}>
              {selectedClient.bd_clients?.name ?? 'This client'}: KYC is {KYC_LABEL[selectedClient.kyc_status].toLowerCase()}
              {selectedClient.risk_rating === 'high' ? '; the risk rating is high' : ''}. The draft can be saved, but check
              KYC before binding. Whether a client whose KYC is not verified may be bound is still to be decided.
            </Alert>
          )}
          {problems.length > 0 && (
            <Alert severity="warning" sx={{ mt: 2 }}>
              {problems.map((p) => <div key={p}>{p}</div>)}
            </Alert>
          )}
          <Stack direction="row" spacing={1} justifyContent="flex-end" sx={{ mt: 3 }}>
            <Button onClick={() => navigate(editing ? `/insurance/policies/${editId}` : '/insurance/policies')}>Cancel</Button>
            <Button variant="contained" onClick={save} disabled={saving || problems.length > 0 || notDraft}>
              {saving ? 'Saving…' : editing ? 'Save changes' : 'Save draft'}
            </Button>
          </Stack>
        </CardContent>
      </Card>
    </Box>
  );
}
