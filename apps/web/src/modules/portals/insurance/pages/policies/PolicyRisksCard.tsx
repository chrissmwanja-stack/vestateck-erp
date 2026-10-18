import { useCallback, useEffect, useState } from 'react';
import { Alert, Button, Card, CardContent, MenuItem, Stack, TextField, Typography } from '@mui/material';
import { errorText, rows, rpc, table } from '../../db';
import { ErrorBanner } from '../../shared';
import type { InsCertificate, InsRisk } from '../../types';
import { lineNeedsCertificate } from '../../risks';

interface LinkedRisk { risk_id: string; ins_risks: InsRisk | null }

/**
 * Risks and motor certificate for a DRAFT policy. The server enforces every rule
 * (draft only, same client, certificate issued to a linked risk); this card only
 * offers the choices that are allowed.
 */
export default function PolicyRisksCard({
  policyId, clientId, productLineId, canManage, onChanged,
}: {
  policyId: string;
  clientId: string;
  productLineId: string;
  canManage: boolean;
  onChanged?: () => void;
}) {
  const [needsCertificate, setNeedsCertificate] = useState(false);
  const [linked, setLinked] = useState<LinkedRisk[]>([]);
  const [clientRisks, setClientRisks] = useState<InsRisk[]>([]);
  const [attached, setAttached] = useState<InsCertificate | null>(null);
  const [available, setAvailable] = useState<InsCertificate[]>([]);
  const [pickRisk, setPickRisk] = useState('');
  const [pickSerial, setPickSerial] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const line = await rows<{ code: string; requires_certificate: boolean }>(table('ins_product_lines').select('code, requires_certificate').eq('id', productLineId));
      setNeedsCertificate(lineNeedsCertificate(line[0]));
      const [lr, risks, att, avail] = await Promise.all([
        rows<LinkedRisk>(table('ins_policy_risks').select('risk_id, ins_risks(id, client_id, risk_type, description, reg_no, chassis_no, status, sum_insured, product_line_id, engine_no, make, model, year_made, ins_clients(client_id, bd_clients(name)), ins_product_lines(code, name))').eq('policy_id', policyId)),
        rows<InsRisk>(table('ins_risks').select('id, client_id, risk_type, description, reg_no, chassis_no, status').eq('client_id', clientId).eq('status', 'active').order('created_at', { ascending: false })),
        rows<InsCertificate>(table('ins_certificate_stock').select('id, serial_no, status, issued_to, risk_id, policy_id, issued_at, close_reason, ins_risks(reg_no, chassis_no, description)').eq('policy_id', policyId)),
        rows<InsCertificate>(table('ins_certificate_stock').select('id, serial_no, status, issued_to, risk_id, policy_id, issued_at, close_reason, ins_risks(reg_no, chassis_no, description)').eq('status', 'issued').is('policy_id', null).order('serial_no', { ascending: true })),
      ]);
      setLinked(lr);
      setClientRisks(risks);
      setAttached(att[0] ?? null);
      setAvailable(avail);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    }
  }, [policyId, clientId, productLineId]);

  useEffect(() => {
    load();
  }, [load]);

  const linkedIds = new Set(linked.map((l) => l.risk_id));
  const linkable = clientRisks.filter((r) => !linkedIds.has(r.id));
  const attachable = available.filter((c) => c.risk_id && linkedIds.has(c.risk_id));

  const run = async (fn: () => Promise<unknown>, after?: () => void) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      after?.();
      await load();
      onChanged?.();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card variant="outlined" sx={{ mb: 2 }}>
      <CardContent>
        <Typography variant="subtitle1" gutterBottom>Insured risks and certificate</Typography>
        <ErrorBanner message={error} />

        {linked.length === 0 ? (
          <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>No risk linked to this policy yet.</Typography>
        ) : (
          <Stack spacing={1} sx={{ mb: 2 }}>
            {linked.map((l) => (
              <Stack key={l.risk_id} direction="row" spacing={2} alignItems="center">
                <Typography variant="body2" sx={{ flexGrow: 1 }}>
                  {l.ins_risks?.description ?? 'Risk'}
                  {l.ins_risks?.reg_no ? ` (${l.ins_risks.reg_no})` : ''}
                  {l.ins_risks?.chassis_no ? ` chassis ${l.ins_risks.chassis_no}` : ''}
                </Typography>
                {canManage && (
                  <Button size="small" color="warning" disabled={busy}
                    onClick={() => run(() => rpc('ins_unlink_policy_risk', { p_policy_id: policyId, p_risk_id: l.risk_id }))}>
                    Unlink
                  </Button>
                )}
              </Stack>
            ))}
          </Stack>
        )}

        {canManage && linkable.length > 0 && (
          <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} alignItems="flex-start" sx={{ mb: 2 }}>
            <TextField select size="small" label="Client risk" value={pickRisk} onChange={(e) => setPickRisk(e.target.value)} sx={{ minWidth: 280 }}>
              {linkable.map((r) => (
                <MenuItem key={r.id} value={r.id}>{r.description}{r.reg_no ? ` (${r.reg_no})` : ''}</MenuItem>
              ))}
            </TextField>
            <Button variant="outlined" disabled={busy || !pickRisk}
              onClick={() => run(() => rpc('ins_link_policy_risk', { p_policy_id: policyId, p_risk_id: pickRisk }), () => setPickRisk(''))}>
              Link risk
            </Button>
          </Stack>
        )}

        {needsCertificate && (
          <>
            <Typography variant="subtitle2" gutterBottom>Certificate</Typography>
            {attached ? (
              <Alert severity="success" sx={{ mb: 1 }}>
                Certificate {attached.serial_no} is attached. It is used when the policy is bound.
              </Alert>
            ) : (
              <Alert severity="warning" sx={{ mb: 1 }}>
                This product line needs a certificate: the policy cannot be bound until an issued certificate is attached to it.
              </Alert>
            )}
            {canManage && !attached && (
              attachable.length === 0 ? (
                <Typography variant="body2" color="text.secondary">
                  No issued certificate for a linked risk. Issue one on the certificate stock screen.
                </Typography>
              ) : (
                <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} alignItems="flex-start">
                  <TextField select size="small" label="Certificate" value={pickSerial} onChange={(e) => setPickSerial(e.target.value)} sx={{ minWidth: 280 }}>
                    {attachable.map((c) => <MenuItem key={c.id} value={c.serial_no}>{c.serial_no}</MenuItem>)}
                  </TextField>
                  <Button variant="outlined" disabled={busy || !pickSerial}
                    onClick={() => run(() => rpc('ins_attach_certificate', { p_policy_id: policyId, p_serial_no: pickSerial }), () => setPickSerial(''))}>
                    Attach certificate
                  </Button>
                </Stack>
              )
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}
