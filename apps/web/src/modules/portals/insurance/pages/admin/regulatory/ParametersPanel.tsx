import { useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle, MenuItem, Stack, Table,
  TableBody, TableCell, TableHead, TableRow, TextField, Tooltip, Typography,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { errorText, rows, rpc, table, write } from '../../../db';
import {
  PARAM_STATUS_LABEL, approveBlockedReason, canWithdrawDraft, formatParameterValue, isUnverified, isValidReason, missingApprovedKeys,
  validateDraft, validateEndDate, type ApprovalAssignment, type DraftInput, type ParamDefinition, type ParameterEvent, type ParamStatus,
  type RegulatoryParameter,
} from '../../../regulatory';
import { EmptyRow } from '../../../shared';
import type { PersonRow } from '../RegulatoryRules';

const STATUS_COLOR: Record<ParamStatus, 'warning' | 'success' | 'default'> = { draft: 'warning', approved: 'success', retired: 'default' };

type Action = { kind: 'approve' | 'end' | 'retire'; param: RegulatoryParameter };

interface Props {
  defs: ParamDefinition[];
  defByKey: Map<string, ParamDefinition>;
  params: RegulatoryParameter[];
  assignments: ApprovalAssignment[];
  people: PersonRow[];
  userId: string | null;
  tenantId: string | null;
  canDraft: boolean;
  isCompanyAdmin: boolean;
  today: string;
  onChanged: () => Promise<void>;
  onError: (message: string | null) => void;
}

const emptyDraft = (key = '', from = ''): DraftInput => ({ key, appliesTo: '', value: '', currency: 'UGX', from, to: '', source: '' });

export default function ParametersPanel({
  defs, defByKey, params, assignments, people, userId, tenantId, canDraft, isCompanyAdmin, today, onChanged, onError,
}: Props) {
  const [status, setStatus] = useState<'all' | ParamStatus>('all');
  const [category, setCategory] = useState('all');
  const [editing, setEditing] = useState<RegulatoryParameter | 'new' | null>(null);
  const [form, setForm] = useState<DraftInput>(emptyDraft());
  const [formErrors, setFormErrors] = useState<Partial<Record<keyof DraftInput, string>>>({});
  const [action, setAction] = useState<Action | null>(null);
  const [endDate, setEndDate] = useState('');
  const [reason, setReason] = useState('');
  const [history, setHistory] = useState<{ param: RegulatoryParameter; events: ParameterEvent[] } | null>(null);
  const [busy, setBusy] = useState(false);

  const nameOf = (id: string | null) => {
    const p = people.find((x) => x.id === id);
    return p ? p.name || p.email : id ? 'Unknown user' : '-';
  };
  const categories = useMemo(() => [...new Set(defs.map((d) => d.category))].sort(), [defs]);
  const missing = useMemo(() => missingApprovedKeys(defs, params, today), [defs, params, today]);
  const visible = params.filter(
    (p) => (status === 'all' || p.status === status) && (category === 'all' || defByKey.get(p.parameter_key)?.category === category),
  );
  const formDef = defByKey.get(form.key);

  const openNew = (key = '') => {
    setForm(emptyDraft(key, today));
    setFormErrors({});
    setEditing('new');
  };
  const openEdit = (p: RegulatoryParameter) => {
    setForm({
      key: p.parameter_key,
      appliesTo: p.applies_to ?? '',
      value: p.value_text ?? (p.value_num == null ? '' : String(Number(p.value_num))),
      currency: p.currency ?? 'UGX',
      from: p.effective_from,
      to: p.effective_to ?? '',
      source: p.source_ref,
    });
    setFormErrors({});
    setEditing(p);
  };

  const saveDraft = async () => {
    const result = validateDraft(formDef, form);
    if (!result.ok) {
      setFormErrors(result.errors);
      return;
    }
    if (editing === 'new' && !tenantId) {
      onError('Could not tell which company you are working in. Reload the page and try again.');
      return;
    }
    setBusy(true);
    onError(null);
    try {
      if (editing === 'new') {
        await write(table('regulatory_parameters').insert({ ...result.value, tenant_id: tenantId }));
      } else if (editing) {
        const { parameter_key: _key, ...changes } = result.value;
        await write(table('regulatory_parameters').update(changes).eq('id', editing.id));
      }
      setEditing(null);
      await onChanged();
    } catch (e) {
      onError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const runAction = async () => {
    if (!action) return;
    setBusy(true);
    onError(null);
    try {
      if (action.kind === 'approve') await rpc('reg_approve_parameter', { p_id: action.param.id });
      if (action.kind === 'end') await rpc('reg_end_parameter', { p_id: action.param.id, p_effective_to: endDate });
      if (action.kind === 'retire') await rpc('reg_retire_parameter', { p_id: action.param.id, p_reason: reason.trim() });
      setAction(null);
      await onChanged();
    } catch (e) {
      onError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const openHistory = async (p: RegulatoryParameter) => {
    onError(null);
    try {
      const events = await rows<ParameterEvent>(table('regulatory_parameter_events').select('*').eq('parameter_id', p.id).order('created_at', { ascending: true }));
      setHistory({ param: p, events });
    } catch (e) {
      onError(errorText(e));
    }
  };

  const endError = action?.kind === 'end' ? validateEndDate(action.param, endDate) : null;
  const actionDisabled = busy || (action?.kind === 'end' && endError !== null) || (action?.kind === 'retire' && !isValidReason(reason));

  return (
    <Stack spacing={2}>
      {missing.length > 0 && (
        <Alert severity="warning">
          <Typography variant="body2" sx={{ mb: 1 }}>
            {missing.length} {missing.length === 1 ? 'rule has' : 'rules have'} no approved value today. Anything that depends on a rule without a value
            stops with a clear message instead of using a guess.
          </Typography>
          <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
            {missing.map((d) => (
              <Tooltip key={d.key} title={d.description}>
                <Chip size="small" variant="outlined" label={d.key} onClick={canDraft ? () => openNew(d.key) : undefined} />
              </Tooltip>
            ))}
          </Stack>
          {canDraft && <Typography variant="caption" sx={{ display: 'block', mt: 1 }}>Select a rule to propose a value for it.</Typography>}
        </Alert>
      )}

      <Stack direction="row" spacing={2} alignItems="center" flexWrap="wrap" useFlexGap>
        <TextField select size="small" label="Status" value={status} onChange={(e) => setStatus(e.target.value as typeof status)} sx={{ minWidth: 200 }}>
          <MenuItem value="all">All</MenuItem>
          {(Object.keys(PARAM_STATUS_LABEL) as ParamStatus[]).map((s) => <MenuItem key={s} value={s}>{PARAM_STATUS_LABEL[s]}</MenuItem>)}
        </TextField>
        <TextField select size="small" label="Category" value={category} onChange={(e) => setCategory(e.target.value)} sx={{ minWidth: 180 }}>
          <MenuItem value="all">All</MenuItem>
          {categories.map((c) => <MenuItem key={c} value={c}>{c}</MenuItem>)}
        </TextField>
        <Box sx={{ flexGrow: 1 }} />
        {canDraft && <Button variant="contained" startIcon={<Add />} onClick={() => openNew()}>New value</Button>}
      </Stack>

      <Card>
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Rule</TableCell>
                <TableCell>Class</TableCell>
                <TableCell>Value</TableCell>
                <TableCell>Period</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Source</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {visible.length === 0 ? (
                <EmptyRow colSpan={7} text="No values match." />
              ) : (
                visible.map((p) => {
                  const def = defByKey.get(p.parameter_key);
                  const blocked = approveBlockedReason(p, def?.category, userId, assignments, today);
                  return (
                    <TableRow key={p.id} hover>
                      <TableCell>
                        <Typography variant="body2" sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{p.parameter_key}</Typography>
                        {def && <Typography variant="caption" color="text.secondary">{def.description}</Typography>}
                      </TableCell>
                      <TableCell>{p.applies_to ?? '-'}</TableCell>
                      <TableCell sx={{ fontWeight: 600 }}>{formatParameterValue(p, def?.value_type)}</TableCell>
                      <TableCell>{p.effective_from} to {p.effective_to ?? 'open'}</TableCell>
                      <TableCell>
                        <Chip size="small" color={STATUS_COLOR[p.status]} variant={p.status === 'approved' ? 'filled' : 'outlined'} label={PARAM_STATUS_LABEL[p.status]} />
                        {p.status === 'retired' && p.retired_reason && (
                          <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>{p.retired_reason}</Typography>
                        )}
                      </TableCell>
                      <TableCell sx={{ maxWidth: 260 }}>
                        {isUnverified(p.source_ref) && <Chip size="small" color="warning" label="Unverified" sx={{ mr: 0.5 }} />}
                        <Typography variant="caption">{p.source_ref}</Typography>
                        <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>
                          Proposed by {nameOf(p.created_by)}{p.approved_by ? `, approved by ${nameOf(p.approved_by)}` : ''}
                        </Typography>
                      </TableCell>
                      <TableCell align="right">
                        <Stack direction="row" spacing={0.5} justifyContent="flex-end" flexWrap="wrap" useFlexGap>
                          {p.status === 'draft' && (
                            <Tooltip title={blocked ?? 'Approve this value'}>
                              <span>
                                <Button size="small" variant="contained" disabled={blocked !== null} onClick={() => setAction({ kind: 'approve', param: p })}>Approve</Button>
                              </span>
                            </Tooltip>
                          )}
                          {p.status === 'draft' && canDraft && <Button size="small" onClick={() => openEdit(p)}>Edit</Button>}
                          {canWithdrawDraft(p, userId, isCompanyAdmin) && (
                            <Button size="small" color="error" onClick={() => { setAction({ kind: 'retire', param: p }); setReason(''); }}>Withdraw</Button>
                          )}
                          {p.status === 'approved' && isCompanyAdmin && (
                            <>
                              <Button size="small" onClick={() => { setAction({ kind: 'end', param: p }); setEndDate(''); }}>End-date</Button>
                              <Button size="small" color="error" onClick={() => { setAction({ kind: 'retire', param: p }); setReason(''); }}>Retire</Button>
                            </>
                          )}
                          <Button size="small" onClick={() => openHistory(p)}>History</Button>
                        </Stack>
                      </TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={editing !== null} onClose={() => !busy && setEditing(null)} fullWidth maxWidth="sm">
        <DialogTitle>{editing === 'new' ? 'Propose a value' : 'Edit draft'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="Rule" required value={form.key} disabled={editing !== 'new'} error={!!formErrors.key}
              helperText={formErrors.key ?? formDef?.description}
              onChange={(e) => setForm({ ...form, key: e.target.value, appliesTo: '' })}>
              {defs.map((d) => <MenuItem key={d.key} value={d.key}>{d.key}</MenuItem>)}
            </TextField>
            {formDef?.class_scoped && (
              <TextField label="Class (optional)" value={form.appliesTo} onChange={(e) => setForm({ ...form, appliesTo: e.target.value })}
                error={!!formErrors.appliesTo} helperText={formErrors.appliesTo ?? 'Leave empty for every class. A value for one class wins over the general one.'} />
            )}
            <Stack direction="row" spacing={2}>
              <TextField fullWidth label="Value" required type={formDef?.value_type === 'text' ? 'text' : 'number'} value={form.value}
                onChange={(e) => setForm({ ...form, value: e.target.value })} error={!!formErrors.value}
                helperText={formErrors.value ?? (formDef ? `A ${formDef.value_type === 'amount' ? 'money amount' : formDef.value_type}` : undefined)} />
              {formDef?.value_type === 'amount' && (
                <TextField label="Currency" required value={form.currency} sx={{ width: 140 }} inputProps={{ maxLength: 3 }}
                  onChange={(e) => setForm({ ...form, currency: e.target.value.toUpperCase() })} error={!!formErrors.currency} helperText={formErrors.currency} />
              )}
            </Stack>
            <Stack direction="row" spacing={2}>
              <TextField fullWidth type="date" label="Starts" InputLabelProps={{ shrink: true }} value={form.from}
                onChange={(e) => setForm({ ...form, from: e.target.value })} error={!!formErrors.from} helperText={formErrors.from} />
              <TextField fullWidth type="date" label="Ends before (optional)" InputLabelProps={{ shrink: true }} value={form.to}
                onChange={(e) => setForm({ ...form, to: e.target.value })} error={!!formErrors.to} helperText={formErrors.to} />
            </Stack>
            <TextField label="Source" required multiline minRows={2} value={form.source} onChange={(e) => setForm({ ...form, source: e.target.value })}
              error={!!formErrors.source}
              helperText={formErrors.source ?? 'Where the value comes from: statute section, circular, or the accountant or adviser and date. Start with UNVERIFIED until it is confirmed.'} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditing(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={saveDraft} disabled={busy}>{busy ? 'Saving…' : editing === 'new' ? 'Save draft' : 'Save changes'}</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={action !== null} onClose={() => !busy && setAction(null)} fullWidth maxWidth="sm">
        <DialogTitle>
          {action?.kind === 'approve' ? 'Approve this value?' : action?.kind === 'end' ? 'End-date this value' : action?.param.status === 'draft' ? 'Withdraw this draft' : 'Retire this value'}
        </DialogTitle>
        <DialogContent>
          {action && (
            <DialogContentText component="div" sx={{ mb: 2 }}>
              <strong>{action.param.parameter_key}</strong>: {formatParameterValue(action.param, defByKey.get(action.param.parameter_key)?.value_type)}, from {action.param.effective_from}
              {action.param.effective_to ? ` to ${action.param.effective_to}` : ''}.
              {action.kind === 'approve' && (
                <>
                  <p>Once approved, the value is used immediately for its dates and cannot be edited. It can only be end-dated or retired, and a change of value is a new row from a new date.</p>
                  {isUnverified(action.param.source_ref) && <Alert severity="warning">The source is marked UNVERIFIED. Approve only if it has since been confirmed.</Alert>}
                </>
              )}
              {action.kind === 'end' && <p>The value stops applying on the end date you choose. It can only be shortened, never extended.</p>}
              {action.kind === 'retire' && action.param.status === 'approved' && <p>A retired value is no longer used and cannot be brought back. Add a new value instead if one is needed.</p>}
            </DialogContentText>
          )}
          {action?.kind === 'end' && (
            <TextField autoFocus fullWidth type="date" label="Ends before" InputLabelProps={{ shrink: true }} value={endDate}
              onChange={(e) => setEndDate(e.target.value)} error={!!endDate && endError !== null} helperText={endDate ? endError ?? undefined : undefined} />
          )}
          {action?.kind === 'retire' && <TextField autoFocus fullWidth label="Reason" required multiline minRows={2} value={reason} onChange={(e) => setReason(e.target.value)} />}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAction(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" color={action?.kind === 'retire' ? 'error' : 'primary'} onClick={runAction} disabled={actionDisabled}>
            {busy ? 'Saving…' : action?.kind === 'approve' ? 'Approve' : action?.kind === 'end' ? 'End-date' : action?.param.status === 'draft' ? 'Withdraw' : 'Retire'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={history !== null} onClose={() => setHistory(null)} fullWidth maxWidth="sm">
        <DialogTitle>History: {history?.param.parameter_key}</DialogTitle>
        <DialogContent>
          {history && (
            <Stack spacing={1} sx={{ mt: 1 }}>
              <Box sx={{ borderLeft: 3, borderColor: 'primary.main', pl: 2 }}>
                <Typography variant="body2" fontWeight={600}>Proposed by {nameOf(history.param.created_by)}</Typography>
                <Typography variant="caption" color="text.secondary">{new Date(history.param.created_at).toLocaleString()}</Typography>
                <Typography variant="body2">{history.param.source_ref}</Typography>
              </Box>
              {history.events.map((e) => (
                <Box key={e.id} sx={{ borderLeft: 3, borderColor: 'primary.main', pl: 2 }}>
                  <Typography variant="body2" fontWeight={600} sx={{ textTransform: 'capitalize' }}>{e.event} by {nameOf(e.actor)}</Typography>
                  <Typography variant="caption" color="text.secondary">{new Date(e.created_at).toLocaleString()}</Typography>
                  {e.detail && <Typography variant="body2">{e.detail}</Typography>}
                </Box>
              ))}
              {history.events.length === 0 && <Typography variant="body2" color="text.secondary">Nothing has happened to this value since it was proposed.</Typography>}
            </Stack>
          )}
        </DialogContent>
        <DialogActions><Button onClick={() => setHistory(null)}>Close</Button></DialogActions>
      </Dialog>
    </Stack>
  );
}
