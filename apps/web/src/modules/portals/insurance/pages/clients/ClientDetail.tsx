import { useCallback, useEffect, useState } from 'react';
import {
  Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle,
  Grid, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { useNavigate, useParams } from 'react-router-dom';
import { allRows, errorText, rows, table, write } from '../../db';
import { useInsuranceAccess } from '../../access';
import { EmptyRow, ErrorBanner, PageHeader, PolicyStatusChip } from '../../shared';
import { contactPatch, contactToForm, validateClientContact } from '../../clientContact';
import { formatMoney } from '../../logic';
import { KYC_ACTION_LABEL, KYC_LABEL, KYC_MEANING, kycTargets, type KycStatus } from '../../clientKyc';
import type { InsClient, Policy } from '../../types';

const KYC_COLOR: Record<KycStatus, 'default' | 'success' | 'warning'> = { pending: 'default', verified: 'success', expired: 'warning' };

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <Box>
      <Typography variant="caption" color="text.secondary">{label}</Typography>
      <Typography variant="body2" component="div" sx={{ fontWeight: 600 }}>{children}</Typography>
    </Box>
  );
}

export default function ClientDetail() {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const { canManage } = useInsuranceAccess();
  const [client, setClient] = useState<InsClient | null>(null);
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [pendingKyc, setPendingKyc] = useState<KycStatus | null>(null);
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState({ tax_id: '', risk_rating: 'medium', client_type: 'corporate', ...contactToForm(null) });

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [c] = await rows<InsClient>(
        table('ins_clients').select('id, client_id, client_type, tax_id, risk_rating, kyc_status, bd_clients(name, email, phone)').eq('id', id),
      );
      setClient(c ?? null);
      setPolicies(
        c
          ? await allRows<Policy>(() =>
              table('ins_policies')
                .select('id, policy_no, status, inception_date, expiry_date, gross_premium, currency, ins_insurers(name), ins_product_lines(name)')
                .eq('client_id', id)
                .order('inception_date', { ascending: false })
                .order('id'),
            )
          : [],
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

  const update = async (patch: Partial<Pick<InsClient, 'kyc_status' | 'tax_id' | 'risk_rating' | 'client_type'>>, done: () => void) => {
    setBusy(true);
    setError(null);
    try {
      await write(table('ins_clients').update(patch).eq('id', id));
      done();
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const startEdit = () => {
    if (!client) return;
    setForm({ tax_id: client.tax_id ?? '', risk_rating: client.risk_rating, client_type: client.client_type, ...contactToForm(client.bd_clients) });
    setEditing(true);
  };

  // A member cannot change the name, so a name the client master does not return must not block their save.
  const contactErrors = validateClientContact(form);
  if (!canManage) delete contactErrors.name;
  const hasContactErrors = Object.keys(contactErrors).length > 0;

  // Tax ID, type and rating live on the insurance profile; name, email and phone on the shared
  // client master. Each write is sent only when something in it changed.
  const saveProfile = async () => {
    if (!client || hasContactErrors) return;
    setBusy(true);
    setError(null);
    try {
      await write(table('ins_clients').update({ tax_id: form.tax_id.trim() || null, risk_rating: form.risk_rating, client_type: form.client_type }).eq('id', id));
      const patch = contactPatch(client.bd_clients, form);
      if (Object.keys(patch).length > 0) await write(table('bd_clients').update(patch).eq('id', client.client_id));
      setEditing(false);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;
  if (!client) {
    return (
      <Box sx={{ p: 3 }}>
        <ErrorBanner message={error ?? 'Client not found.'} />
        <Button onClick={() => navigate('/insurance/clients')}>Back to clients</Button>
      </Box>
    );
  }

  const name = client.bd_clients?.name ?? 'Client';
  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title={name}
        subtitle="Insurance profile on the shared client master."
        actions={
          <Stack direction="row" spacing={1}>
            <Button onClick={() => navigate('/insurance/clients')}>Back</Button>
            <Button variant="outlined" onClick={startEdit}>Edit profile</Button>
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      <Card sx={{ mb: 3 }}>
        <CardContent>
          <Grid container spacing={2}>
            <Grid item xs={6} md={3}><Fact label="Type"><span style={{ textTransform: 'capitalize' }}>{client.client_type}</span></Fact></Grid>
            <Grid item xs={6} md={3}><Fact label="Tax ID (TIN)">{client.tax_id ?? '-'}</Fact></Grid>
            <Grid item xs={6} md={3}><Fact label="Email">{client.bd_clients?.email ?? '-'}</Fact></Grid>
            <Grid item xs={6} md={3}><Fact label="Phone">{client.bd_clients?.phone ?? '-'}</Fact></Grid>
            <Grid item xs={6} md={3}><Fact label="Risk rating"><span style={{ textTransform: 'capitalize' }}>{client.risk_rating}</span></Fact></Grid>
            <Grid item xs={6} md={9}>
              <Fact label="KYC">
                <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap">
                  <Chip size="small" label={KYC_LABEL[client.kyc_status]} color={KYC_COLOR[client.kyc_status]} />
                  {canManage
                    ? kycTargets(client.kyc_status).map((s) => (
                        <Button key={s} size="small" variant={s === 'verified' ? 'contained' : 'outlined'} onClick={() => setPendingKyc(s)}>
                          {KYC_ACTION_LABEL[s]}
                        </Button>
                      ))
                    : <Typography variant="caption" color="text.secondary">Only insurance managers can change KYC status.</Typography>}
                </Stack>
              </Fact>
            </Grid>
          </Grid>
        </CardContent>
      </Card>

      <Typography variant="h6" fontWeight={700} sx={{ mb: 1 }}>Policies ({policies.length})</Typography>
      <Card>
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Policy</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Insurer</TableCell>
                <TableCell>Product</TableCell>
                <TableCell>Period</TableCell>
                <TableCell align="right">Gross premium</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {policies.length === 0 ? (
                <EmptyRow colSpan={6} text="This client has no policies yet." />
              ) : (
                policies.map((p) => (
                  <TableRow key={p.id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/policies/${p.id}`)}>
                    <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{p.policy_no}</TableCell>
                    <TableCell><PolicyStatusChip status={p.status} expiryDate={p.expiry_date} /></TableCell>
                    <TableCell>{p.ins_insurers?.name ?? '-'}</TableCell>
                    <TableCell>{p.ins_product_lines?.name ?? '-'}</TableCell>
                    <TableCell>{p.inception_date} to {p.expiry_date}</TableCell>
                    <TableCell align="right">{formatMoney(Number(p.gross_premium), p.currency)}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={pendingKyc !== null} onClose={() => setPendingKyc(null)}>
        <DialogTitle>{pendingKyc ? KYC_ACTION_LABEL[pendingKyc] : ''}</DialogTitle>
        <DialogContent>
          <DialogContentText>
            Set KYC for {name} to {pendingKyc ? KYC_LABEL[pendingKyc].toLowerCase() : ''}. {pendingKyc ? KYC_MEANING[pendingKyc] : ''}
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setPendingKyc(null)}>Cancel</Button>
          <Button variant="contained" disabled={busy} onClick={() => pendingKyc && update({ kyc_status: pendingKyc }, () => setPendingKyc(null))}>
            Confirm
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={editing} onClose={() => setEditing(false)} fullWidth maxWidth="sm">
        <DialogTitle>Edit profile</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              label="Name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })}
              disabled={!canManage} error={!!contactErrors.name}
              helperText={contactErrors.name ?? (canManage ? 'Documents already issued keep the name they were issued with.' : 'Only insurance managers can change the name.')}
            />
            <TextField label="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} error={!!contactErrors.email} helperText={contactErrors.email} />
            <TextField label="Phone" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} error={!!contactErrors.phone} helperText={contactErrors.phone} />
            <TextField select label="Type" value={form.client_type} onChange={(e) => setForm({ ...form, client_type: e.target.value })}>
              <MenuItem value="corporate">Corporate</MenuItem>
              <MenuItem value="individual">Individual</MenuItem>
            </TextField>
            <TextField label="Tax ID (TIN)" value={form.tax_id} onChange={(e) => setForm({ ...form, tax_id: e.target.value })} />
            <TextField select label="Risk rating" value={form.risk_rating} onChange={(e) => setForm({ ...form, risk_rating: e.target.value })}>
              <MenuItem value="low">Low</MenuItem>
              <MenuItem value="medium">Medium</MenuItem>
              <MenuItem value="high">High</MenuItem>
            </TextField>
            <Typography variant="caption" color="text.secondary">Name, email and phone are shared with Business Development, so a change here shows there too.</Typography>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditing(false)}>Cancel</Button>
          <Button
            variant="contained"
            disabled={busy || hasContactErrors}
            onClick={saveProfile}
          >
            Save
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
