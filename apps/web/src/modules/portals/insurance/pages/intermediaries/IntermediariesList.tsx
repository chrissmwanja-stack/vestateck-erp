import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle,
  IconButton, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Tooltip, Typography,
} from '@mui/material';
import { Add, Edit, FactCheck, SwapHoriz } from '@mui/icons-material';
import { supabase } from '../../../../../lib/supabaseClient';
import { errorText, rows, rpc, table } from '../../db';
import { useInsuranceAccess } from '../../access';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import {
  CATEGORY_LABEL,
  STATUS_LABEL,
  allowedStatusMoves,
  canVerify,
  changeNeedsReverification,
  needsAppointment,
  needsLicence,
  needsParent,
  parentChoices,
  saveProblems,
  statusNeedsNote,
  type Intermediary,
  type IntermediaryCategory,
  type IntermediaryForm,
  type IntermediaryStatus,
} from '../../intermediaries';

const EMPTY: IntermediaryForm = {
  code: '', name: '', kind: 'business', category: 'independent_broker', parent_id: null,
  licence_ref: '', licence_authority: '', licence_valid_from: '', licence_valid_to: '',
  appointment_ref: '', authorisation_basis: '', authorisation_reference: '',
};

const STATUS_COLOR: Record<IntermediaryStatus, 'default' | 'primary' | 'success' | 'warning' | 'error'> = {
  pending_verification: 'warning',
  active: 'success',
  suspended: 'error',
  expired: 'error',
  terminated: 'default',
};

const today = () => new Date().toISOString().slice(0, 10);
const orNull = (v: string) => (v.trim() === '' ? null : v.trim());

// Agents and sub-agents: external intermediaries, not employees. Nothing here posts;
// commission comes in a later slice once the agency agreement is in place.
export default function IntermediariesList() {
  const { canManage } = useInsuranceAccess();
  const [all, setAll] = useState<Intermediary[]>([]);
  const [actorId, setActorId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Intermediary | 'new' | null>(null);
  const [form, setForm] = useState<IntermediaryForm>(EMPTY);
  const [saving, setSaving] = useState(false);
  const [statusFor, setStatusFor] = useState<Intermediary | null>(null);
  const [statusTo, setStatusTo] = useState<IntermediaryStatus | ''>('');
  const [statusNote, setStatusNote] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setAll(await rows<Intermediary>(table('ins_intermediaries').select('*').order('name', { ascending: true })));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
    supabase.auth.getUser().then(({ data }) => setActorId(data.user?.id ?? null));
  }, [load]);

  const byId = useMemo(() => new Map(all.map((i) => [i.id, i])), [all]);
  const selfId = editing && editing !== 'new' ? editing.id : null;
  const parents = useMemo(() => parentChoices(all, selfId), [all, selfId]);
  const problems = useMemo(() => saveProblems(form, all, selfId, today()), [form, all, selfId]);
  const reverify = editing && editing !== 'new'
    ? changeNeedsReverification(editing, {
        category: form.category, parent_id: form.parent_id,
        licence_ref: orNull(form.licence_ref), licence_authority: orNull(form.licence_authority),
        licence_valid_from: orNull(form.licence_valid_from), licence_valid_to: orNull(form.licence_valid_to),
        appointment_ref: orNull(form.appointment_ref), authorisation_basis: orNull(form.authorisation_basis),
        authorisation_reference: orNull(form.authorisation_reference),
      })
    : false;

  const openNew = () => {
    setForm(EMPTY);
    setEditing('new');
  };
  const openEdit = (i: Intermediary) => {
    setForm({
      code: i.code, name: i.name, kind: i.kind, category: i.category, parent_id: i.parent_id,
      licence_ref: i.licence_ref ?? '', licence_authority: i.licence_authority ?? '',
      licence_valid_from: i.licence_valid_from ?? '', licence_valid_to: i.licence_valid_to ?? '',
      appointment_ref: i.appointment_ref ?? '', authorisation_basis: i.authorisation_basis ?? '',
      authorisation_reference: i.authorisation_reference ?? '',
    });
    setEditing(i);
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      await rpc('ins_save_intermediary', {
        p_id: editing && editing !== 'new' ? editing.id : null,
        p_code: form.code.trim().toUpperCase(),
        p_kind: form.kind,
        p_name: form.name.trim(),
        p_category: form.category,
        p_contact_email: null,
        p_contact_phone: null,
        p_parent_id: form.parent_id,
        p_licence_ref: needsLicence(form.category) ? orNull(form.licence_ref) : null,
        p_licence_authority: needsLicence(form.category) ? orNull(form.licence_authority) : null,
        p_licence_valid_from: needsLicence(form.category) ? orNull(form.licence_valid_from) : null,
        p_licence_valid_to: needsLicence(form.category) ? orNull(form.licence_valid_to) : null,
        p_appointment_ref: needsAppointment(form.category) ? orNull(form.appointment_ref) : null,
        p_authorisation_basis: needsParent(form.category) ? orNull(form.authorisation_basis) : null,
        p_authorisation_reference: needsParent(form.category) ? orNull(form.authorisation_reference) : null,
      });
      setEditing(null);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  const verify = async (i: Intermediary) => {
    setError(null);
    try {
      await rpc('ins_verify_intermediary', { p_id: i.id, p_note: null });
      await load();
    } catch (e) {
      setError(errorText(e));
    }
  };

  const openStatus = (i: Intermediary) => {
    setStatusFor(i);
    setStatusTo('');
    setStatusNote('');
  };

  const changeStatus = async () => {
    if (!statusFor || !statusTo) return;
    setSaving(true);
    setError(null);
    try {
      await rpc('ins_set_intermediary_status', { p_id: statusFor.id, p_to: statusTo, p_note: orNull(statusNote) });
      setStatusFor(null);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  const set = <K extends keyof IntermediaryForm>(key: K, value: IntermediaryForm[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Intermediaries"
        subtitle="Agents, brokers, sub-agents and referral partners. These are external intermediaries, not employees. Nothing here posts money."
        actions={canManage && <Button variant="contained" startIcon={<Add />} onClick={openNew}>New intermediary</Button>}
      />
      <ErrorBanner message={error} />
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Code</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Parent</TableCell>
                <TableCell>Licence</TableCell>
                <TableCell>Appointment</TableCell>
                <TableCell>Status</TableCell>
                {canManage && <TableCell align="right">Actions</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {all.length === 0 ? (
                <EmptyRow colSpan={canManage ? 8 : 7} text="No intermediaries yet." />
              ) : (
                all.map((i) => {
                  const verifyState = canVerify(i, actorId);
                  const moves = allowedStatusMoves(i.status);
                  return (
                    <TableRow key={i.id} hover>
                      <TableCell><Typography fontFamily="monospace">{i.code}</Typography></TableCell>
                      <TableCell sx={{ fontWeight: 600 }}>{i.name}</TableCell>
                      <TableCell>{CATEGORY_LABEL[i.category]}</TableCell>
                      <TableCell>{i.parent_id ? byId.get(i.parent_id)?.name ?? '-' : '-'}</TableCell>
                      <TableCell>
                        {i.licence_ref ? `${i.licence_ref} (${i.licence_authority ?? '-'}, to ${i.licence_valid_to ?? '-'})` : '-'}
                      </TableCell>
                      <TableCell>{i.appointment_ref ?? '-'}</TableCell>
                      <TableCell><Chip size="small" color={STATUS_COLOR[i.status]} label={STATUS_LABEL[i.status]} variant="outlined" /></TableCell>
                      {canManage && (
                        <TableCell align="right">
                          <Tooltip title="Edit">
                            <IconButton size="small" aria-label={`Edit ${i.name}`} onClick={() => openEdit(i)}>
                              <Edit fontSize="small" />
                            </IconButton>
                          </Tooltip>
                          {i.status === 'pending_verification' && (
                            <Tooltip title={verifyState.ok ? 'Verify' : verifyState.reason ?? 'Verify'}>
                              <span>
                                <IconButton size="small" aria-label={`Verify ${i.name}`} disabled={!verifyState.ok} onClick={() => verify(i)}>
                                  <FactCheck fontSize="small" />
                                </IconButton>
                              </span>
                            </Tooltip>
                          )}
                          {moves.length > 0 && (
                            <Tooltip title="Change status">
                              <IconButton size="small" aria-label={`Change status of ${i.name}`} onClick={() => openStatus(i)}>
                                <SwapHoriz fontSize="small" />
                              </IconButton>
                            </Tooltip>
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

      <Dialog open={editing !== null} onClose={() => setEditing(null)} fullWidth maxWidth="md">
        <DialogTitle>{editing === 'new' ? 'New intermediary' : 'Edit intermediary'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            {reverify && (
              <Alert severity="warning">
                This changes a credential, the category or the parent. It will go back to pending verification, and another manager must verify it.
              </Alert>
            )}
            {problems.length > 0 && (
              <Alert severity="info">
                <Stack component="ul" sx={{ m: 0, pl: 2 }}>
                  {problems.map((p) => <li key={p}>{p}</li>)}
                </Stack>
              </Alert>
            )}
            <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
              <TextField label="Reference code" value={form.code} onChange={(e) => set('code', e.target.value)} fullWidth />
              <TextField label="Name" value={form.name} onChange={(e) => set('name', e.target.value)} fullWidth />
              <TextField select label="Kind" value={form.kind} onChange={(e) => set('kind', e.target.value as IntermediaryForm['kind'])} sx={{ minWidth: 160 }}>
                <MenuItem value="business">Business</MenuItem>
                <MenuItem value="individual">Individual</MenuItem>
              </TextField>
            </Stack>
            <TextField
              select label="Category" value={form.category}
              onChange={(e) => set('category', e.target.value as IntermediaryCategory)}
              helperText={needsParent(form.category) ? 'A sub-agent must sit under an active parent.' : ' '}
            >
              {(Object.keys(CATEGORY_LABEL) as IntermediaryCategory[]).map((c) => (
                <MenuItem key={c} value={c}>{CATEGORY_LABEL[c]}</MenuItem>
              ))}
            </TextField>
            <TextField
              select label={needsParent(form.category) ? 'Parent intermediary (required)' : 'Parent intermediary (optional)'}
              value={form.parent_id ?? ''}
              onChange={(e) => set('parent_id', e.target.value || null)}
              helperText="Only active intermediaries that are not referral partners are offered."
            >
              <MenuItem value="">None</MenuItem>
              {parents.map((p) => <MenuItem key={p.id} value={p.id}>{p.name} ({p.code})</MenuItem>)}
            </TextField>
            {needsLicence(form.category) && (
              <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
                <TextField label="Licence reference" value={form.licence_ref} onChange={(e) => set('licence_ref', e.target.value)} fullWidth />
                <TextField label="Issuing authority" value={form.licence_authority} onChange={(e) => set('licence_authority', e.target.value)} fullWidth />
                <TextField type="date" label="Valid from" InputLabelProps={{ shrink: true }} value={form.licence_valid_from} onChange={(e) => set('licence_valid_from', e.target.value)} />
                <TextField type="date" label="Valid to" InputLabelProps={{ shrink: true }} value={form.licence_valid_to} onChange={(e) => set('licence_valid_to', e.target.value)} />
              </Stack>
            )}
            {needsAppointment(form.category) && (
              <TextField label="Insurer appointment reference" helperText="Separate from the licence. The insurer's own appointment record."
                value={form.appointment_ref} onChange={(e) => set('appointment_ref', e.target.value)} />
            )}
            {needsParent(form.category) && (
              <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
                <TextField label="Basis of the parent's authority" helperText="For example, a written appointment or agency letter."
                  value={form.authorisation_basis} onChange={(e) => set('authorisation_basis', e.target.value)} fullWidth />
                <TextField label="Authorisation reference" value={form.authorisation_reference} onChange={(e) => set('authorisation_reference', e.target.value)} fullWidth />
              </Stack>
            )}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditing(null)}>Cancel</Button>
          <Button variant="contained" onClick={save} disabled={saving || problems.length > 0}>Save</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={statusFor !== null} onClose={() => setStatusFor(null)} fullWidth maxWidth="sm">
        <DialogTitle>Change status{statusFor ? `: ${statusFor.name}` : ''}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="New status" value={statusTo} onChange={(e) => setStatusTo(e.target.value as IntermediaryStatus)}>
              {(statusFor ? allowedStatusMoves(statusFor.status) : []).map((s) => (
                <MenuItem key={s} value={s}>{STATUS_LABEL[s]}</MenuItem>
              ))}
            </TextField>
            <TextField
              label="Reason" value={statusNote} onChange={(e) => setStatusNote(e.target.value)}
              required={statusTo !== '' && statusNeedsNote(statusTo)}
              helperText="Required for a suspension or termination."
            />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatusFor(null)}>Cancel</Button>
          <Button
            variant="contained" onClick={changeStatus}
            disabled={saving || !statusTo || (statusNeedsNote(statusTo) && statusNote.trim() === '')}
          >
            Apply
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
