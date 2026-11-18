import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle,
  MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { errorText, rpc } from '../../db';
import { useInsuranceAccess } from '../../access';
import { formatMoney } from '../../logic';
import { ErrorBanner } from '../../shared';
import {
  accrualRefusalText, monthPeriod, periodProblem, previewTotalsText, runResultText,
  type AccrualBlockedLine, type AccrualCheck, type AccrualPreview, type AccrualPreviewLine, type AccrualRunResult,
} from '../../agentCommission';

interface PolicyOption { id: string; policy_no: string | null }

/**
 * Two actions, one dialog each, both of which post nothing themselves.
 *
 * `Accrue one` asks the server about a single policy and shows the answer before
 * anything is written: either the refusal in words, or the share the accrual
 * WOULD create and the currency it would carry. `Run a period` previews, then
 * runs, then reports. Neither offers a way to type an amount — there is no
 * parameter for one on the server either, so this is a limit of the system and
 * not of the form.
 */
const AccrualDialogs = ({
  onDone,
  policyOptions,
}: {
  onDone: () => void;
  policyOptions: PolicyOption[];
}) => {
  const { canManage } = useInsuranceAccess();

  const [oneOpen, setOneOpen] = useState(false);
  const [policyId, setPolicyId] = useState('');
  const [reason, setReason] = useState('');
  const [check, setCheck] = useState<AccrualCheck | null>(null);
  const [checking, setChecking] = useState(false);
  const [saving, setSaving] = useState(false);
  const [oneError, setOneError] = useState<string | null>(null);
  const [oneDone, setOneDone] = useState<string | null>(null);

  const [runOpen, setRunOpen] = useState(false);
  const initial = monthPeriod();
  const [from, setFrom] = useState(initial.from);
  const [to, setTo] = useState(initial.to);
  const [preview, setPreview] = useState<AccrualPreview | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [running, setRunning] = useState(false);
  const [runError, setRunError] = useState<string | null>(null);
  const [run, setRun] = useState<AccrualRunResult | null>(null);

  // Ask the server what it would do, every time the choice changes. Deliberately
  // not memoised on the policy's contents: the answer depends on the ledger, not
  // on anything this screen holds.
  const checkPolicy = useCallback(async (id: string) => {
    if (!id) { setCheck(null); return; }
    setChecking(true);
    setOneError(null);
    try {
      setCheck(await rpc<AccrualCheck>('ins_agent_commission_blocked_reason', { p_policy_id: id }));
    } catch (e) {
      setOneError(errorText(e));
      setCheck(null);
    } finally {
      setChecking(false);
    }
  }, []);

  useEffect(() => { void checkPolicy(policyId); }, [policyId, checkPolicy]);

  const accrueOne = async () => {
    setSaving(true);
    setOneError(null);
    setOneDone(null);
    try {
      const out = await rpc<{ accrued: boolean; reason?: string; gross_amount?: number }>(
        'ins_agent_commission_accrue_manual',
        { p_policy_id: policyId, p_reason: reason.trim() || null },
      );
      if (out.accrued) {
        setOneDone(`Accrued ${formatMoney(Number(out.gross_amount ?? 0), check?.currency ?? 'UGX')}.`);
        setPolicyId('');
        onDone();
      } else {
        setOneError(out.reason ?? 'The server declined to accrue this policy.');
      }
    } catch (e) {
      setOneError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  const loadPreview = async () => {
    const problem = periodProblem(from, to);
    if (problem) { setRunError(problem); return; }
    setPreviewing(true);
    setRunError(null);
    setRun(null);
    try {
      setPreview(await rpc<AccrualPreview>('ins_agent_commission_accrual_preview', { p_from: from, p_to: to }));
    } catch (e) {
      setRunError(errorText(e));
      setPreview(null);
    } finally {
      setPreviewing(false);
    }
  };

  const runPeriod = async () => {
    setRunning(true);
    setRunError(null);
    try {
      const out = await rpc<AccrualRunResult>('ins_run_agent_commission_accruals', {
        p_from: from, p_to: to, p_reason: reason.trim() || null,
      });
      setRun(out);
      onDone();
    } catch (e) {
      setRunError(errorText(e));
    } finally {
      setRunning(false);
    }
  };

  if (!canManage) return null;

  const oneBlocked = checking ? false : check !== null && check.code !== null;

  return (
    <Stack direction="row" spacing={1} sx={{ mb: 2 }}>
      <Button variant="outlined" onClick={() => { setOneOpen(true); setOneError(null); setOneDone(null); }}>
        Accrue Commission
      </Button>
      <Button variant="outlined" onClick={() => { setRunOpen(true); setRunError(null); setRun(null); setPreview(null); }}>
        Run Accruals
      </Button>

      {/* ---- one policy ---- */}
      <Dialog open={oneOpen} onClose={() => setOneOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>Accrue commission for one policy</DialogTitle>
        <DialogContent dividers>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            The share comes from the approved agreement in force on the policy&apos;s inception date. You cannot
            enter an amount, and the action will not overrule the recognition point: if the brokerage has not earned
            its commission yet, the policy cannot be accrued and you will be told why.
          </Typography>

          <ErrorBanner message={oneError} />
          {oneDone && <Alert severity="success" sx={{ mb: 2 }}>{oneDone}</Alert>}

          <TextField
            select fullWidth size="small" label="Policy" value={policyId}
            onChange={(e) => setPolicyId(e.target.value)} sx={{ mb: 2 }}
          >
            <MenuItem value="">Choose a policy</MenuItem>
            {policyOptions.map((p) => (
              <MenuItem key={p.id} value={p.id}>{p.policy_no ?? p.id}</MenuItem>
            ))}
          </TextField>

          {checking && <CircularProgress size={20} />}

          {policyId && !checking && check && (
            oneBlocked ? (
              <Alert severity="info">{accrualRefusalText(check)}</Alert>
            ) : (
              <Alert severity="success">
                Will accrue {check.name ?? 'the agent'}&apos;s share of{' '}
                {formatMoney(Number(check.gross_amount ?? 0), check.currency ?? 'UGX')}
                {check.basis ? ` (${check.basis.replace(/_/g, ' ')})` : ''}.
              </Alert>
            )
          )}

          <TextField
            fullWidth size="small" multiline minRows={2} sx={{ mt: 2 }}
            label="Why (optional)" value={reason} onChange={(e) => setReason(e.target.value)}
            helperText="Recorded on the share's history, so the reason survives the person who gave it."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOneOpen(false)}>Close</Button>
          <Button
            variant="contained" disabled={!policyId || oneBlocked || saving} onClick={() => void accrueOne()}
          >
            {saving ? 'Accruing…' : 'Accrue'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* ---- a period ---- */}
      <Dialog open={runOpen} onClose={() => setRunOpen(false)} fullWidth maxWidth="md">
        <DialogTitle>Run accruals for a period</DialogTitle>
        <DialogContent dividers>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            Every policy in the period that is ready to accrue, in one run. Safe to repeat: a share already on the
            books is skipped, never accrued twice. Policies that cannot be accrued are listed with the reason rather
            than being quietly left out.
          </Typography>

          <ErrorBanner message={runError} />

          <Stack direction="row" spacing={2} sx={{ mb: 2 }}>
            <TextField size="small" type="date" label="From" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => { setFrom(e.target.value); setPreview(null); }} />
            <TextField size="small" type="date" label="To" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => { setTo(e.target.value); setPreview(null); }} />
            <Button onClick={() => void loadPreview()} disabled={previewing}>
              {previewing ? 'Checking…' : 'Check what would be accrued'}
            </Button>
          </Stack>

          {preview && (
            <>
              <Alert severity={preview.eligible_count === 0 ? 'info' : 'success'} sx={{ mb: 2 }}>
                {preview.eligible_count === 0
                  ? 'Nothing is ready to accrue in this period.'
                  : `${preview.eligible_count} ${preview.eligible_count === 1 ? 'policy is' : 'policies are'} ready: ${previewTotalsText(preview)}.`}
                {preview.blocked_count > 0 && ` ${preview.blocked_count} cannot be accrued and ${preview.blocked_count === 1 ? 'is' : 'are'} listed below.`}
              </Alert>

              {preview.eligible.length > 0 && (
                <Table size="small" sx={{ mb: 2 }}>
                  <TableHead>
                    <TableRow>
                      <TableCell>Policy</TableCell><TableCell>Agent</TableCell>
                      <TableCell align="right">Share</TableCell><TableCell>Currency</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {preview.eligible.map((e: AccrualPreviewLine) => (
                      <TableRow key={e.policy_id}>
                        <TableCell>{e.policy_no ?? e.policy_id}</TableCell>
                        <TableCell>{e.name ?? ''}</TableCell>
                        <TableCell align="right">{formatMoney(Number(e.gross_amount ?? 0), e.currency)}</TableCell>
                        <TableCell>{e.currency}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}

              {preview.blocked.length > 0 && (
                <Box>
                  <Typography variant="subtitle2" sx={{ mb: 1 }}>Cannot be accrued</Typography>
                  <Table size="small">
                    <TableHead>
                      <TableRow><TableCell>Policy</TableCell><TableCell>Why</TableCell></TableRow>
                    </TableHead>
                    <TableBody>
                      {preview.blocked.map((b: AccrualBlockedLine) => (
                        <TableRow key={b.policy_id}>
                          <TableCell>{b.policy_no ?? b.policy_id}</TableCell>
                          <TableCell>{b.reason}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </Box>
              )}
            </>
          )}

          {run && (
            <Alert severity={run.failed > 0 ? 'warning' : 'success'} sx={{ mt: 2 }}>
              {runResultText(run)}
              {run.failures.length > 0 && (
                <Box component="ul" sx={{ mt: 1, mb: 0, pl: 2 }}>
                  {run.failures.map((f) => (
                    <li key={f.policy_no ?? f.error}>{f.policy_no}: {f.error}</li>
                  ))}
                </Box>
              )}
            </Alert>
          )}

          <TextField
            fullWidth size="small" multiline minRows={2} sx={{ mt: 2 }}
            label="Why (optional)" value={reason} onChange={(e) => setReason(e.target.value)}
            helperText="Recorded on every share the run creates."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setRunOpen(false)}>Close</Button>
          <Button
            variant="contained"
            disabled={!preview || preview.eligible_count === 0 || running}
            onClick={() => void runPeriod()}
          >
            {running ? 'Running…' : `Accrue ${preview?.eligible_count ?? 0}`}
          </Button>
        </DialogActions>
      </Dialog>
    </Stack>
  );
};

export default AccrualDialogs;
