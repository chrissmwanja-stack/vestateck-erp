import { useMemo, useState } from 'react';
import {
  Alert, Button, Card, CardContent, Chip, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle, MenuItem, Stack, Table,
  TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { errorText, rpc } from '../../../db';
import {
  ASSIGNMENT_STATE_LABEL, assignmentState, isValidReason, validateAssignment, type ApprovalAssignment, type AssignmentInput, type AssignmentState,
  type ParamDefinition,
} from '../../../regulatory';
import { EmptyRow } from '../../../shared';
import type { PersonRow } from '../RegulatoryRules';

const STATE_COLOR: Record<AssignmentState, 'success' | 'info' | 'default'> = { in_force: 'success', scheduled: 'info', ended: 'default', withdrawn: 'default' };

interface Props {
  defs: ParamDefinition[];
  assignments: ApprovalAssignment[];
  people: PersonRow[];
  isCompanyAdmin: boolean;
  today: string;
  onChanged: () => Promise<void>;
  onError: (message: string | null) => void;
}

// Who may approve what. Approval follows the responsibility for a submission, not a role:
// the Insurance Admin prepares drafts but approves nothing by role, and a company admin
// is not an approver by role either. A company admin assigns and withdraws approvers.
export default function ApproversPanel({ defs, assignments, people, isCompanyAdmin, today, onChanged, onError }: Props) {
  const emptyForm = (): AssignmentInput => ({ userId: '', scope: 'category', scopeValue: '', responsibility: '', from: today, to: '' });
  const [assigning, setAssigning] = useState(false);
  const [form, setForm] = useState<AssignmentInput>(emptyForm);
  const [formErrors, setFormErrors] = useState<Partial<Record<keyof AssignmentInput, string>>>({});
  const [withdrawing, setWithdrawing] = useState<ApprovalAssignment | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);

  const nameOf = (id: string | null) => {
    const p = people.find((x) => x.id === id);
    return p ? p.name || p.email : id ? 'Unknown user' : '-';
  };
  const categories = useMemo(() => [...new Set(defs.map((d) => d.category))].sort(), [defs]);
  const scopeOptions = form.scope === 'key' ? defs.map((d) => d.key) : categories;

  const assign = async () => {
    const errors = validateAssignment(form);
    setFormErrors(errors);
    if (Object.keys(errors).length > 0) return;
    setBusy(true);
    onError(null);
    try {
      await rpc('reg_assign_approver', {
        p_user_id: form.userId,
        p_scope: form.scope,
        p_scope_value: form.scopeValue,
        p_responsibility: form.responsibility.trim(),
        p_effective_from: form.from,
        p_effective_to: form.to || null,
      });
      setAssigning(false);
      await onChanged();
    } catch (e) {
      onError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const withdraw = async () => {
    if (!withdrawing) return;
    setBusy(true);
    onError(null);
    try {
      await rpc('reg_withdraw_approver', { p_assignment_id: withdrawing.id, p_reason: reason.trim() });
      setWithdrawing(null);
      await onChanged();
    } catch (e) {
      onError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Stack spacing={2}>
      <Alert severity="info">
        Approval follows the responsibility for a submission, not a role. The Insurance Admin prepares values but approves none by role, and company
        admins are not approvers by role either. Nobody can approve a value they proposed themselves.
        {isCompanyAdmin ? '' : ' Only a company admin can assign or withdraw approvers; you see your own assignments here.'}
      </Alert>
      <Stack direction="row" justifyContent="space-between" alignItems="center">
        <Typography variant="subtitle1" fontWeight={700}>Approver assignments</Typography>
        {isCompanyAdmin && (
          <Button variant="contained" startIcon={<Add />} onClick={() => { setForm(emptyForm()); setFormErrors({}); setAssigning(true); }}>
            Assign approver
          </Button>
        )}
      </Stack>
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Approver</TableCell>
                <TableCell>Covers</TableCell>
                <TableCell>Responsibility</TableCell>
                <TableCell>Period</TableCell>
                <TableCell>Status</TableCell>
                {isCompanyAdmin && <TableCell align="right">Action</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {assignments.length === 0 ? (
                <EmptyRow colSpan={isCompanyAdmin ? 6 : 5} text="No approvers assigned yet. Until someone is assigned, no value can be approved." />
              ) : (
                assignments.map((a) => {
                  const state = assignmentState(a, today);
                  return (
                    <TableRow key={a.id} hover>
                      <TableCell sx={{ fontWeight: 600 }}>{nameOf(a.user_id)}</TableCell>
                      <TableCell>
                        <Typography variant="body2" sx={{ fontFamily: a.scope === 'key' ? 'monospace' : undefined }}>{a.scope_value}</Typography>
                        <Typography variant="caption" color="text.secondary">{a.scope === 'key' ? 'One rule' : 'Whole category'}</Typography>
                      </TableCell>
                      <TableCell>{a.responsibility}</TableCell>
                      <TableCell>{a.effective_from} to {a.effective_to ?? 'open'}</TableCell>
                      <TableCell>
                        <Chip size="small" color={STATE_COLOR[state]} variant={state === 'in_force' ? 'filled' : 'outlined'} label={ASSIGNMENT_STATE_LABEL[state]} />
                        {a.withdrawn_reason && <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>{a.withdrawn_reason}</Typography>}
                      </TableCell>
                      {isCompanyAdmin && (
                        <TableCell align="right">
                          {!a.withdrawn_at && (
                            <Button size="small" color="error" onClick={() => { setWithdrawing(a); setReason(''); }}>Withdraw</Button>
                          )}
                        </TableCell>
                      )}
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={assigning} onClose={() => !busy && setAssigning(false)} fullWidth maxWidth="sm">
        <DialogTitle>Assign approver</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="Approver" required value={form.userId} onChange={(e) => setForm({ ...form, userId: e.target.value })}
              error={!!formErrors.userId} helperText={formErrors.userId}>
              {people.map((p) => <MenuItem key={p.id} value={p.id}>{p.name || p.email}{p.name ? ` (${p.email})` : ''}</MenuItem>)}
            </TextField>
            <TextField select label="Covers" value={form.scope} onChange={(e) => setForm({ ...form, scope: e.target.value as AssignmentInput['scope'], scopeValue: '' })}>
              <MenuItem value="category">A whole category</MenuItem>
              <MenuItem value="key">One rule</MenuItem>
            </TextField>
            <TextField select label={form.scope === 'key' ? 'Rule' : 'Category'} required value={form.scopeValue}
              onChange={(e) => setForm({ ...form, scopeValue: e.target.value })} error={!!formErrors.scopeValue} helperText={formErrors.scopeValue}>
              {scopeOptions.map((o) => <MenuItem key={o} value={o}>{o}</MenuItem>)}
            </TextField>
            <TextField label="Responsibility" required multiline minRows={2} value={form.responsibility}
              onChange={(e) => setForm({ ...form, responsibility: e.target.value })} error={!!formErrors.responsibility}
              helperText={formErrors.responsibility ?? 'The submission or duty this approval supports, for example the quarterly regulator return.'} />
            <Stack direction="row" spacing={2}>
              <TextField fullWidth type="date" label="From" InputLabelProps={{ shrink: true }} value={form.from}
                onChange={(e) => setForm({ ...form, from: e.target.value })} error={!!formErrors.from} helperText={formErrors.from} />
              <TextField fullWidth type="date" label="To (optional)" InputLabelProps={{ shrink: true }} value={form.to}
                onChange={(e) => setForm({ ...form, to: e.target.value })} error={!!formErrors.to} helperText={formErrors.to} />
            </Stack>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAssigning(false)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={assign} disabled={busy}>{busy ? 'Saving…' : 'Assign'}</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={withdrawing !== null} onClose={() => !busy && setWithdrawing(null)} fullWidth maxWidth="sm">
        <DialogTitle>Withdraw approver</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            {withdrawing ? `${nameOf(withdrawing.user_id)} will no longer be able to approve ${withdrawing.scope_value}.` : ''} The assignment stays on record.
          </DialogContentText>
          <TextField autoFocus fullWidth label="Reason" required multiline minRows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setWithdrawing(null)} disabled={busy}>Cancel</Button>
          <Button color="error" variant="contained" onClick={withdraw} disabled={busy || !isValidReason(reason)}>Withdraw</Button>
        </DialogActions>
      </Dialog>
    </Stack>
  );
}
