import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle,
  MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { allRows, errorText, rows, rpc, table } from '../../db';
import { useInsuranceAccess } from '../../access';
import type { InsCertificate, InsRisk } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import {
  CERTIFICATE_STATUS_LABEL, EMPTY_CERTIFICATE_RANGE, canCloseCertificate, countCertificatesByStatus, firstSerial,
  validateCertificateRange, type CertificateRange,
} from '../../risks';

type Action = { kind: 'issue' | 'close'; cert: InsCertificate } | null;

export default function CertificateStock() {
  const { canManage } = useInsuranceAccess();
  const [certs, setCerts] = useState<InsCertificate[]>([]);
  const [vehicles, setVehicles] = useState<InsRisk[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState('all');
  const [range, setRange] = useState<CertificateRange>(EMPTY_CERTIFICATE_RANGE);
  const [loadingRange, setLoadingRange] = useState(false);
  const [action, setAction] = useState<Action>(null);
  const [riskId, setRiskId] = useState('');
  const [issuedTo, setIssuedTo] = useState('');
  const [closeStatus, setCloseStatus] = useState<'spoiled' | 'voided'>('spoiled');
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [c, v] = await Promise.all([
        allRows<InsCertificate>(() => table('ins_certificate_stock')
          .select('id, serial_no, status, issued_to, risk_id, policy_id, issued_at, close_reason, ins_risks(reg_no, chassis_no, description)')
          .order('serial_no', { ascending: true }).order('id')),
        rows<InsRisk>(table('ins_risks').select('id, client_id, risk_type, description, reg_no, chassis_no, status, ins_clients(client_id, bd_clients(name))')
          .eq('risk_type', 'vehicle').eq('status', 'active').order('created_at', { ascending: false })),
      ]);
      setCerts(c);
      setVehicles(v);
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

  const counts = useMemo(() => countCertificatesByStatus(certs), [certs]);
  const shown = useMemo(() => certs.filter((c) => statusFilter === 'all' || c.status === statusFilter), [certs, statusFilter]);
  const rangeProblem = range.prefix !== '' || range.from !== '' || range.to !== '' ? validateCertificateRange(range) : 'Enter a range.';

  const loadRange = async () => {
    setLoadingRange(true);
    setError(null);
    setNotice(null);
    try {
      const count = await rpc<number>('ins_load_certificate_range', {
        p_prefix: range.prefix.trim(),
        p_from: Number(range.from),
        p_to: Number(range.to),
        p_width: Number(range.width),
      });
      setNotice(`Loaded ${count} certificates, from ${firstSerial(range)}.`);
      setRange(EMPTY_CERTIFICATE_RANGE);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoadingRange(false);
    }
  };

  const openAction = (kind: 'issue' | 'close', cert: InsCertificate) => {
    setAction({ kind, cert });
    setRiskId('');
    setIssuedTo('');
    setCloseStatus('spoiled');
    setReason('');
    setError(null);
  };

  const submit = async () => {
    if (!action) return;
    setSaving(true);
    setError(null);
    try {
      if (action.kind === 'issue') {
        await rpc('ins_issue_certificate', { p_serial_no: action.cert.serial_no, p_risk_id: riskId, p_issued_to: issuedTo || null });
        setNotice(`Certificate ${action.cert.serial_no} issued.`);
      } else {
        await rpc('ins_void_certificate', { p_serial_no: action.cert.serial_no, p_status: closeStatus, p_reason: reason.trim() });
        setNotice(`Certificate ${action.cert.serial_no} marked ${closeStatus}.`);
      }
      setAction(null);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  const canSubmit = action?.kind === 'issue' ? riskId !== '' : reason.trim() !== '';

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Motor certificate stock"
        subtitle="Serial-numbered certificates. Issue one to a vehicle risk, then attach it to a draft motor policy."
      />
      <ErrorBanner message={error} />
      {notice && <Alert severity="success" sx={{ mb: 2 }} onClose={() => setNotice(null)}>{notice}</Alert>}

      <Stack direction="row" spacing={1} sx={{ mb: 2, flexWrap: 'wrap' }}>
        {Object.keys(CERTIFICATE_STATUS_LABEL).map((s) => (
          <Chip
            key={s}
            label={`${CERTIFICATE_STATUS_LABEL[s]}: ${counts[s] ?? 0}`}
            variant={statusFilter === s ? 'filled' : 'outlined'}
            onClick={() => setStatusFilter(statusFilter === s ? 'all' : s)}
          />
        ))}
      </Stack>

      {canManage && (
        <Card variant="outlined" sx={{ mb: 2 }}>
          <CardContent>
            <Typography variant="subtitle1" gutterBottom>Load a serial range</Typography>
            <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} alignItems="flex-start">
              <TextField label="Prefix" value={range.prefix} onChange={(e) => setRange({ ...range, prefix: e.target.value })} helperText="Optional, e.g. MC-" />
              <TextField label="First number" type="number" value={range.from} onChange={(e) => setRange({ ...range, from: e.target.value })} inputProps={{ min: 0 }} />
              <TextField label="Last number" type="number" value={range.to} onChange={(e) => setRange({ ...range, to: e.target.value })} inputProps={{ min: 0 }} />
              <TextField label="Digits" type="number" value={range.width} onChange={(e) => setRange({ ...range, width: e.target.value })} inputProps={{ min: 1, max: 20 }} />
              <Button variant="contained" disabled={loadingRange || rangeProblem !== null} onClick={loadRange} title={rangeProblem ?? undefined}>
                {loadingRange ? 'Loading…' : 'Load range'}
              </Button>
            </Stack>
            {rangeProblem ? (
              <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>{rangeProblem}</Typography>
            ) : (
              <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
                This loads {Number(range.to) - Number(range.from) + 1} certificates, from {firstSerial(range)}. A serial that is already in stock stops the whole load.
              </Typography>
            )}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Serial</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Vehicle</TableCell>
                <TableCell>Issued to</TableCell>
                <TableCell>Notes</TableCell>
                {canManage && <TableCell />}
              </TableRow>
            </TableHead>
            <TableBody>
              {shown.length === 0 ? (
                <EmptyRow colSpan={canManage ? 6 : 5} text={certs.length === 0 ? 'No certificates in stock yet.' : 'No certificates with this status.'} />
              ) : (
                shown.slice(0, 500).map((c) => (
                  <TableRow key={c.id} hover>
                    <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{c.serial_no}</TableCell>
                    <TableCell>{CERTIFICATE_STATUS_LABEL[c.status] ?? c.status}</TableCell>
                    <TableCell>{c.ins_risks ? (c.ins_risks.reg_no ?? c.ins_risks.chassis_no ?? c.ins_risks.description) : '-'}</TableCell>
                    <TableCell>{c.issued_to ?? '-'}</TableCell>
                    <TableCell>{c.policy_id ? 'Attached to a policy' : c.close_reason ?? '-'}</TableCell>
                    {canManage && (
                      <TableCell align="right">
                        {c.status === 'in_stock' && <Button size="small" onClick={() => openAction('issue', c)}>Issue</Button>}
                        {canCloseCertificate(c) && <Button size="small" color="warning" onClick={() => openAction('close', c)}>Spoil or void</Button>}
                      </TableCell>
                    )}
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
          {shown.length > 500 && (
            <Typography variant="body2" color="text.secondary" sx={{ p: 2 }}>Showing the first 500 of {shown.length}. Filter by status to narrow the list.</Typography>
          )}
        </CardContent>
      </Card>

      <Dialog open={action !== null} onClose={() => !saving && setAction(null)} fullWidth maxWidth="sm">
        <DialogTitle>
          {action?.kind === 'issue' ? `Issue ${action.cert.serial_no}` : `Spoil or void ${action?.cert.serial_no ?? ''}`}
        </DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            {action?.kind === 'issue' ? (
              <>
                <TextField select label="Vehicle risk" required value={riskId} onChange={(e) => setRiskId(e.target.value)}
                  helperText={vehicles.length === 0 ? 'Register an active vehicle risk first.' : undefined}>
                  {vehicles.map((v) => (
                    <MenuItem key={v.id} value={v.id}>
                      {v.reg_no ?? v.chassis_no ?? v.description} - {v.ins_clients?.bd_clients?.name ?? ''}
                    </MenuItem>
                  ))}
                </TextField>
                <TextField label="Issued to (branch or agent)" value={issuedTo} onChange={(e) => setIssuedTo(e.target.value)} />
              </>
            ) : (
              <>
                <TextField select label="Result" value={closeStatus} onChange={(e) => setCloseStatus(e.target.value as 'spoiled' | 'voided')}>
                  <MenuItem value="spoiled">Spoiled (printing error)</MenuItem>
                  <MenuItem value="voided">Voided</MenuItem>
                </TextField>
                <TextField label="Reason" required value={reason} onChange={(e) => setReason(e.target.value)} />
              </>
            )}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAction(null)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={submit} disabled={saving || !canSubmit}>
            {saving ? 'Saving…' : action?.kind === 'issue' ? 'Issue certificate' : 'Confirm'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
