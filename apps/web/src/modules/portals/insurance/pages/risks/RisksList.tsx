import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle,
  MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { allRows, errorText, rows, rpc, table } from '../../db';
import { useInsuranceAccess } from '../../access';
import type { InsRisk } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import { EMPTY_RISK_FORM, RISK_TYPES, lineNeedsCertificate, validateRisk, type RiskForm } from '../../risks';

interface ClientOption { id: string; bd_clients: { name: string } | null }
interface LineOption { id: string; code: string; name: string; requires_certificate: boolean }

export default function RisksList() {
  const { canManage } = useInsuranceAccess();
  const [risks, setRisks] = useState<InsRisk[]>([]);
  const [clients, setClients] = useState<ClientOption[]>([]);
  const [lines, setLines] = useState<LineOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<RiskForm>(EMPTY_RISK_FORM);
  const [clientId, setClientId] = useState('');
  const [lineId, setLineId] = useState('');
  const [saving, setSaving] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [r, c, l] = await Promise.all([
        allRows<InsRisk>(() => table('ins_risks')
          .select('id, client_id, product_line_id, risk_type, description, reg_no, chassis_no, engine_no, make, model, year_made, sum_insured, status, ins_clients(client_id, bd_clients(name)), ins_product_lines(code, name)')
          .order('created_at', { ascending: false }).order('id')),
        rows<ClientOption>(table('ins_clients').select('id, bd_clients(name)').order('created_at', { ascending: false })),
        rows<LineOption>(table('ins_product_lines').select('id, code, name, requires_certificate').eq('is_active', true).order('name', { ascending: true })),
      ]);
      setRisks(r);
      setClients(c);
      setLines(l);
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

  const selectedLine = useMemo(() => lines.find((l) => l.id === lineId) ?? null, [lines, lineId]);
  const validation = clientId && lineId ? validateRisk(form, selectedLine) : 'Choose a client and a product line.';

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      await rpc('ins_register_risk', {
        p_client_id: clientId,
        p_product_line_id: lineId,
        p_risk_type: form.riskType,
        p_description: form.description.trim(),
        p_reg_no: form.regNo || null,
        p_chassis_no: form.chassisNo || null,
        p_engine_no: form.engineNo || null,
        p_make: form.make || null,
        p_model: form.model || null,
        p_year_made: form.yearMade ? Number(form.yearMade) : null,
        p_sum_insured: form.sumInsured ? Number(form.sumInsured) : 0,
      });
      setOpen(false);
      setForm(EMPTY_RISK_FORM);
      setClientId('');
      setLineId('');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  const toggle = async (risk: InsRisk) => {
    setBusyId(risk.id);
    setError(null);
    try {
      await rpc('ins_set_risk_status', { p_risk_id: risk.id, p_status: risk.status === 'active' ? 'inactive' : 'active' });
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusyId(null);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Insured risks"
        subtitle={`${risks.length} risks. A policy on a line that needs a certificate (motor, for example) needs a vehicle risk and an issued certificate before it can be bound.`}
        actions={canManage ? <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New risk</Button> : undefined}
      />
      <ErrorBanner message={error} />
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Client</TableCell>
                <TableCell>Line</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Description</TableCell>
                <TableCell>Reg. no.</TableCell>
                <TableCell>Chassis no.</TableCell>
                <TableCell align="right">Sum insured</TableCell>
                <TableCell>Status</TableCell>
                {canManage && <TableCell />}
              </TableRow>
            </TableHead>
            <TableBody>
              {risks.length === 0 ? (
                <EmptyRow colSpan={canManage ? 9 : 8} text="No insured risks yet." />
              ) : (
                risks.map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell sx={{ fontWeight: 600 }}>{r.ins_clients?.bd_clients?.name ?? '-'}</TableCell>
                    <TableCell>{r.ins_product_lines?.code ?? '-'}</TableCell>
                    <TableCell sx={{ textTransform: 'capitalize' }}>{r.risk_type}</TableCell>
                    <TableCell>{r.description}</TableCell>
                    <TableCell>{r.reg_no ?? '-'}</TableCell>
                    <TableCell>{r.chassis_no ?? '-'}</TableCell>
                    <TableCell align="right">{Number(r.sum_insured).toLocaleString('en-UG', { maximumFractionDigits: 2 })}</TableCell>
                    <TableCell><Chip size="small" label={r.status} variant="outlined" color={r.status === 'active' ? 'success' : 'default'} /></TableCell>
                    {canManage && (
                      <TableCell align="right">
                        <Button size="small" disabled={busyId === r.id} onClick={() => toggle(r)}>
                          {r.status === 'active' ? 'Deactivate' : 'Activate'}
                        </Button>
                      </TableCell>
                    )}
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New insured risk</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="Client" required value={clientId} onChange={(e) => setClientId(e.target.value)}>
              {clients.map((c) => <MenuItem key={c.id} value={c.id}>{c.bd_clients?.name ?? c.id}</MenuItem>)}
            </TextField>
            <TextField select label="Product line" required value={lineId} onChange={(e) => {
              setLineId(e.target.value);
              const picked = lines.find((l) => l.id === e.target.value);
              if (lineNeedsCertificate(picked)) setForm({ ...form, riskType: 'vehicle' });
            }}>
              {lines.map((l) => <MenuItem key={l.id} value={l.id}>{l.code} - {l.name}</MenuItem>)}
            </TextField>
            <TextField select label="Risk type" value={form.riskType} onChange={(e) => setForm({ ...form, riskType: e.target.value })}>
              {RISK_TYPES.map((t) => <MenuItem key={t.value} value={t.value}>{t.label}</MenuItem>)}
            </TextField>
            <TextField label="Description" required value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
            {form.riskType === 'vehicle' && (
              <Stack direction="row" spacing={2}>
                <TextField fullWidth label="Registration no." value={form.regNo} onChange={(e) => setForm({ ...form, regNo: e.target.value })} />
                <TextField fullWidth label="Chassis no." value={form.chassisNo} onChange={(e) => setForm({ ...form, chassisNo: e.target.value })} />
              </Stack>
            )}
            {form.riskType === 'vehicle' && (
              <Stack direction="row" spacing={2}>
                <TextField fullWidth label="Engine no." value={form.engineNo} onChange={(e) => setForm({ ...form, engineNo: e.target.value })} />
                <TextField fullWidth label="Make" value={form.make} onChange={(e) => setForm({ ...form, make: e.target.value })} />
                <TextField fullWidth label="Model" value={form.model} onChange={(e) => setForm({ ...form, model: e.target.value })} />
              </Stack>
            )}
            <Stack direction="row" spacing={2}>
              <TextField fullWidth type="number" label="Year made" value={form.yearMade} onChange={(e) => setForm({ ...form, yearMade: e.target.value })} inputProps={{ min: 1950, max: 2100 }} />
              <TextField fullWidth type="number" label="Sum insured" value={form.sumInsured} onChange={(e) => setForm({ ...form, sumInsured: e.target.value })} inputProps={{ min: 0, step: '0.01' }} />
            </Stack>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={save} disabled={saving || Boolean(validation)} title={validation ?? undefined}>
            {saving ? 'Saving…' : 'Save risk'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
