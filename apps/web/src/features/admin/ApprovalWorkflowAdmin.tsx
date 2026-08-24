import { SyntheticEvent, useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  MenuItem,
  Paper,
  Stack,
  Switch,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Tabs,
  TextField,
  Typography,
} from '@mui/material';
import { Add as AddIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';
import { useTenantAdminAccess } from '../team/useTenantAdminAccess';

type AppliesTo = 'requests' | 'invoices';
type ScopeType = 'department' | 'cost_center' | 'global';

interface Stage {
  id: string;
  name: string;
  sequence_order: number;
  approver_role: string;
  threshold_amount: number | null;
  next_stage_low_id: string | null;
  next_stage_high_id: string | null;
  requires_offer_entry: boolean;
  requires_offer_selection: boolean;
  blocks_offer_submitter_approval: boolean;
  is_finance_terminal_stage: boolean;
  is_active: boolean;
  applies_to: AppliesTo;
}

interface Assignment {
  id: string;
  user_id: string;
  workflow_stage_id: string;
  scope_type: ScopeType;
  scope_id: string | null;
  threshold_max: number | null;
}

interface TeamMember {
  user_id: string;
  name: string | null;
  email: string;
}

interface LookupRow {
  id: string;
  name: string;
}

const emptyStageForm = {
  name: '',
  approver_role: '',
  sequence_order: 1,
  threshold_amount: '',
  next_stage_low_id: '',
  next_stage_high_id: '',
  requires_offer_entry: false,
  requires_offer_selection: false,
  blocks_offer_submitter_approval: false,
  is_finance_terminal_stage: false,
  is_active: true,
};

const emptyAssignmentForm = {
  user_id: '',
  workflow_stage_id: '',
  scope_type: 'global' as ScopeType,
  scope_id: '',
  threshold_max: '',
};

// This screen is company-admin only -- each tenant defines its own
// approval process, so it's scoped by useTenantAdminAccess the same way
// TeamMembersAdmin is, not by a module grant. Write RLS for both tables
// (workflow_stages, approval_assignments) is in
// 20260824110310_workflow_stages_and_assignments_admin_write.sql.
//
// Editing a stage's routing (threshold_amount, next_stage_low_id/high_id)
// or deactivating it doesn't corrupt data -- see
// count_open_items_at_workflow_stage() -- but it does silently change
// behavior for requests/invoices already sitting at that stage the next
// time they advance. saveStage() checks for that and shows a confirm-
// before-saving warning rather than blocking the edit outright.
export default function ApprovalWorkflowAdmin() {
  const access = useTenantAdminAccess();
  const { session } = useAuth();

  const [tab, setTab] = useState(0);
  const [appliesTo, setAppliesTo] = useState<AppliesTo>('requests');

  const [stages, setStages] = useState<Stage[]>([]);
  const [assignments, setAssignments] = useState<Assignment[]>([]);
  const [members, setMembers] = useState<TeamMember[]>([]);
  const [departments, setDepartments] = useState<LookupRow[]>([]);
  const [costCenters, setCostCenters] = useState<LookupRow[]>([]);

  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [stageDialogOpen, setStageDialogOpen] = useState(false);
  const [editStage, setEditStage] = useState<Stage | null>(null);
  const [stageForm, setStageForm] = useState(emptyStageForm);
  const [stageSaving, setStageSaving] = useState(false);
  const [stageSaveError, setStageSaveError] = useState<string | null>(null);
  // Set once a routing-relevant field changes on a stage that has open
  // requests/invoices sitting at it right now -- see
  // count_open_items_at_workflow_stage() for why this can't be answered
  // by just filtering the rows already loaded client-side. Cleared
  // whenever the dialog (re)opens or the admin edits the form again, so
  // a stale count from a previous edit can't be silently reused.
  const [occupancyWarning, setOccupancyWarning] = useState<{ openRequests: number; openInvoices: number } | null>(
    null,
  );
  const [occupancyChecking, setOccupancyChecking] = useState(false);

  const [assignmentDialogOpen, setAssignmentDialogOpen] = useState(false);
  const [editAssignment, setEditAssignment] = useState<Assignment | null>(null);
  const [assignmentForm, setAssignmentForm] = useState(emptyAssignmentForm);
  const [assignmentSaving, setAssignmentSaving] = useState(false);
  const [assignmentSaveError, setAssignmentSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError(null);

    const [stagesRes, assignmentsRes, membersRes, deptRes, costCenterRes] = await Promise.all([
      supabase
        .from('workflow_stages')
        .select(
          'id, name, sequence_order, approver_role, threshold_amount, next_stage_low_id, next_stage_high_id, requires_offer_entry, requires_offer_selection, blocks_offer_submitter_approval, is_finance_terminal_stage, is_active, applies_to',
        )
        .order('applies_to')
        .order('sequence_order'),
      supabase
        .from('approval_assignments')
        .select('id, user_id, workflow_stage_id, scope_type, scope_id, threshold_max'),
      supabase.rpc('get_tenant_team_members'),
      supabase.from('departments').select('id, name').order('name'),
      supabase.from('cost_centers').select('id, name').order('name'),
    ]);

    if (stagesRes.error) setLoadError(stagesRes.error.message);
    else setStages((stagesRes.data ?? []) as Stage[]);

    // Expected to come back scoped to "just my own rows" until the
    // Assignments RLS is broadened for admins -- see file header note.
    if (!assignmentsRes.error) setAssignments((assignmentsRes.data ?? []) as Assignment[]);

    if (!membersRes.error) {
      setMembers(
        ((membersRes.data ?? []) as unknown as Array<{ user_id: string; name: string | null; email: string }>).map(
          (m) => ({ user_id: m.user_id, name: m.name, email: m.email }),
        ),
      );
    }
    if (!deptRes.error) setDepartments((deptRes.data ?? []) as LookupRow[]);
    if (!costCenterRes.error) setCostCenters((costCenterRes.data ?? []) as LookupRow[]);

    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const handleTabChange = (_: SyntheticEvent, value: number) => setTab(value);

  const stagesForAppliesTo = useMemo(
    () => stages.filter((s) => s.applies_to === appliesTo).sort((a, b) => a.sequence_order - b.sequence_order),
    [stages, appliesTo],
  );

  const stageNameById = useMemo(() => new Map(stages.map((s) => [s.id, s.name])), [stages]);
  const memberLabelById = useMemo(
    () => new Map(members.map((m) => [m.user_id, m.name?.trim() || m.email])),
    [members],
  );
  const deptNameById = useMemo(() => new Map(departments.map((d) => [d.id, d.name])), [departments]);
  const costCenterNameById = useMemo(() => new Map(costCenters.map((c) => [c.id, c.name])), [costCenters]);

  // ---- Stages tab ----

  const openNewStage = () => {
    setEditStage(null);
    setStageForm({
      ...emptyStageForm,
      sequence_order: stagesForAppliesTo.length > 0 ? Math.max(...stagesForAppliesTo.map((s) => s.sequence_order)) + 1 : 1,
    });
    setStageSaveError(null);
    setStageDialogOpen(true);
  };

  const openEditStage = (stage: Stage) => {
    setEditStage(stage);
    setStageForm({
      name: stage.name,
      approver_role: stage.approver_role,
      sequence_order: stage.sequence_order,
      threshold_amount: stage.threshold_amount === null ? '' : String(stage.threshold_amount),
      next_stage_low_id: stage.next_stage_low_id ?? '',
      next_stage_high_id: stage.next_stage_high_id ?? '',
      requires_offer_entry: stage.requires_offer_entry,
      requires_offer_selection: stage.requires_offer_selection,
      blocks_offer_submitter_approval: stage.blocks_offer_submitter_approval,
      is_finance_terminal_stage: stage.is_finance_terminal_stage,
      is_active: stage.is_active,
    });
    setStageSaveError(null);
    setOccupancyWarning(null);
    setStageDialogOpen(true);
  };

  const closeStageDialog = () => {
    if (!stageSaving) setStageDialogOpen(false);
  };

  const hasThreshold = stageForm.threshold_amount.trim() !== '';

  // Routing-relevant fields: changing any of these takes effect the next
  // time an in-flight item advances (routing is evaluated live, not
  // stored -- see the RPC comment). Renaming a stage or toggling the
  // "requires offer entry"-style flags doesn't retroactively change
  // anything for items already sitting there, so those don't warrant the
  // warning.
  const routingFieldsChanged = (): boolean => {
    if (!editStage) return false;
    const newThreshold = hasThreshold ? Number(stageForm.threshold_amount) : null;
    return (
      newThreshold !== editStage.threshold_amount ||
      (stageForm.next_stage_low_id || null) !== editStage.next_stage_low_id ||
      (hasThreshold ? stageForm.next_stage_high_id || null : null) !== editStage.next_stage_high_id ||
      (editStage.is_active && !stageForm.is_active)
    );
  };

  const saveStage = async (skipOccupancyCheck = false) => {
    setStageSaveError(null);
    if (!stageForm.name.trim()) {
      setStageSaveError('Name is required.');
      return;
    }
    if (!stageForm.approver_role.trim()) {
      setStageSaveError('Approver role is required.');
      return;
    }
    if (editStage && (stageForm.next_stage_low_id === editStage.id || stageForm.next_stage_high_id === editStage.id)) {
      setStageSaveError('A stage cannot point to itself as its own next stage.');
      return;
    }
    if (hasThreshold && !stageForm.next_stage_high_id) {
      setStageSaveError('A threshold needs an "above threshold" next stage as well as an "at or below" one.');
      return;
    }

    if (!skipOccupancyCheck && editStage && routingFieldsChanged()) {
      setOccupancyChecking(true);
      const { data, error: rpcError } = await supabase
        .rpc('count_open_items_at_workflow_stage', { p_stage_id: editStage.id })
        .single();
      setOccupancyChecking(false);
      if (!rpcError && data) {
        const counts = data as { open_requests: number; open_invoices: number };
        if (counts.open_requests > 0 || counts.open_invoices > 0) {
          setOccupancyWarning({ openRequests: counts.open_requests, openInvoices: counts.open_invoices });
          return;
        }
      }
      // On an RPC error, fall through and save anyway rather than
      // blocking the admin on a check that itself failed -- the warning
      // is an FYI, not the source of truth for whether the save is safe.
    }

    setStageSaving(true);
    const payload = {
      name: stageForm.name.trim(),
      approver_role: stageForm.approver_role.trim(),
      sequence_order: stageForm.sequence_order,
      threshold_amount: hasThreshold ? Number(stageForm.threshold_amount) : null,
      next_stage_low_id: stageForm.next_stage_low_id || null,
      // Only meaningful when a threshold is set -- the branching RPC
      // logic (see next_stage_low_id/high_id in the migration) ignores
      // next_stage_high_id whenever threshold_amount is null.
      next_stage_high_id: hasThreshold ? stageForm.next_stage_high_id || null : null,
      requires_offer_entry: stageForm.requires_offer_entry,
      requires_offer_selection: stageForm.requires_offer_selection,
      blocks_offer_submitter_approval: stageForm.blocks_offer_submitter_approval,
      is_finance_terminal_stage: stageForm.is_finance_terminal_stage,
      is_active: stageForm.is_active,
      applies_to: appliesTo,
    };

    let err;
    if (editStage) {
      ({ error: err } = await supabase.from('workflow_stages').update(payload).eq('id', editStage.id));
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setStageSaving(false);
        setStageSaveError(tenantResult.error);
        return;
      }
      ({ error: err } = await supabase.from('workflow_stages').insert({ ...payload, tenant_id: tenantResult.tenantId }));
    }
    setStageSaving(false);
    if (err) {
      setStageSaveError(err.message);
      return;
    }
    setStageDialogOpen(false);
    load();
  };

  // ---- Assignments tab ----

  const openNewAssignment = () => {
    setEditAssignment(null);
    setAssignmentForm(emptyAssignmentForm);
    setAssignmentSaveError(null);
    setAssignmentDialogOpen(true);
  };

  const openEditAssignment = (a: Assignment) => {
    setEditAssignment(a);
    setAssignmentForm({
      user_id: a.user_id,
      workflow_stage_id: a.workflow_stage_id,
      scope_type: a.scope_type,
      scope_id: a.scope_id ?? '',
      threshold_max: a.threshold_max === null ? '' : String(a.threshold_max),
    });
    setAssignmentSaveError(null);
    setAssignmentDialogOpen(true);
  };

  const closeAssignmentDialog = () => {
    if (!assignmentSaving) setAssignmentDialogOpen(false);
  };

  const saveAssignment = async () => {
    setAssignmentSaveError(null);
    if (!assignmentForm.user_id) {
      setAssignmentSaveError('Choose a team member.');
      return;
    }
    if (!assignmentForm.workflow_stage_id) {
      setAssignmentSaveError('Choose a stage.');
      return;
    }
    if (assignmentForm.scope_type !== 'global' && !assignmentForm.scope_id) {
      setAssignmentSaveError('Choose a department or cost center for this scope, or switch scope to Global.');
      return;
    }

    setAssignmentSaving(true);
    const payload = {
      user_id: assignmentForm.user_id,
      workflow_stage_id: assignmentForm.workflow_stage_id,
      scope_type: assignmentForm.scope_type,
      scope_id: assignmentForm.scope_type === 'global' ? null : assignmentForm.scope_id,
      threshold_max: assignmentForm.threshold_max.trim() === '' ? null : Number(assignmentForm.threshold_max),
    };

    let err;
    if (editAssignment) {
      ({ error: err } = await supabase.from('approval_assignments').update(payload).eq('id', editAssignment.id));
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setAssignmentSaving(false);
        setAssignmentSaveError(tenantResult.error);
        return;
      }
      ({ error: err } = await supabase
        .from('approval_assignments')
        .insert({ ...payload, tenant_id: tenantResult.tenantId }));
    }
    setAssignmentSaving(false);
    if (err) {
      setAssignmentSaveError(err.message);
      return;
    }
    setAssignmentDialogOpen(false);
    load();
  };

  if (!access) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress size={24} />
      </Box>
    );
  }

  if (!access.isAdmin) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600 }}>
        Only your company's admin can configure the approval process. Ask a company admin for access, or reach out
        to your module admin if you believe this is wrong.
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1000 }}>
      <Typography variant="h5" sx={{ mb: 0.5 }}>
        Approval Workflow
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Define your company's own approval stages and thresholds, and who covers each one.
      </Typography>

      {loadError && <Alert severity="error" sx={{ mb: 2 }}>{loadError}</Alert>}

      <Paper variant="outlined">
        <Tabs value={tab} onChange={handleTabChange} sx={{ borderBottom: 1, borderColor: 'divider' }}>
          <Tab label="Approval Stages" />
          <Tab label="Approver Assignments" />
        </Tabs>

        <Box sx={{ p: 3 }}>
          {loading ? (
            <Box display="flex" justifyContent="center" py={4}>
              <CircularProgress size={24} />
            </Box>
          ) : tab === 0 ? (
            <>
              <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
                <TextField
                  select
                  size="small"
                  label="Applies to"
                  value={appliesTo}
                  onChange={(e) => setAppliesTo(e.target.value as AppliesTo)}
                  sx={{ width: 220 }}
                >
                  <MenuItem value="requests">Material / Purchase Requests</MenuItem>
                  <MenuItem value="invoices">Invoices</MenuItem>
                </TextField>
                <Button variant="contained" startIcon={<AddIcon />} onClick={openNewStage}>
                  New Stage
                </Button>
              </Stack>

              <TableContainer>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>Order</TableCell>
                      <TableCell>Name</TableCell>
                      <TableCell>Approver Role</TableCell>
                      <TableCell>Threshold</TableCell>
                      <TableCell>Branches to</TableCell>
                      <TableCell>Status</TableCell>
                      <TableCell align="right">Actions</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {stagesForAppliesTo.map((stage) => (
                      <TableRow key={stage.id} hover>
                        <TableCell>{stage.sequence_order}</TableCell>
                        <TableCell>
                          {stage.name}
                          {stage.is_finance_terminal_stage && (
                            <Chip size="small" label="Terminal" sx={{ ml: 1 }} />
                          )}
                        </TableCell>
                        <TableCell>{stage.approver_role}</TableCell>
                        <TableCell>
                          {stage.threshold_amount === null ? '—' : stage.threshold_amount.toLocaleString()}
                        </TableCell>
                        <TableCell>
                          {stage.threshold_amount !== null ? (
                            <>
                              ≤ threshold → {stage.next_stage_low_id ? stageNameById.get(stage.next_stage_low_id) ?? '—' : '—'}
                              <br />
                              &gt; threshold → {stage.next_stage_high_id ? stageNameById.get(stage.next_stage_high_id) ?? '—' : '—'}
                            </>
                          ) : (
                            (stage.next_stage_low_id ? stageNameById.get(stage.next_stage_low_id) : null) ?? '— (final)'
                          )}
                        </TableCell>
                        <TableCell>
                          <Chip
                            size="small"
                            label={stage.is_active ? 'Active' : 'Inactive'}
                            color={stage.is_active ? 'success' : 'default'}
                          />
                        </TableCell>
                        <TableCell align="right">
                          <Button size="small" onClick={() => openEditStage(stage)}>
                            Edit
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))}
                    {stagesForAppliesTo.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                          No stages configured yet for this type.
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </TableContainer>
            </>
          ) : (
            <>
              <Stack direction="row" justifyContent="flex-end" sx={{ mb: 2 }}>
                <Button variant="contained" startIcon={<AddIcon />} onClick={openNewAssignment}>
                  New Assignment
                </Button>
              </Stack>

              <TableContainer>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>Team Member</TableCell>
                      <TableCell>Stage</TableCell>
                      <TableCell>Scope</TableCell>
                      <TableCell>Cap</TableCell>
                      <TableCell align="right">Actions</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {assignments.map((a) => (
                      <TableRow key={a.id} hover>
                        <TableCell>{memberLabelById.get(a.user_id) ?? a.user_id}</TableCell>
                        <TableCell>{stageNameById.get(a.workflow_stage_id) ?? '—'}</TableCell>
                        <TableCell>
                          {a.scope_type === 'global'
                            ? 'Global'
                            : a.scope_type === 'department'
                              ? `Department: ${a.scope_id ? deptNameById.get(a.scope_id) ?? '—' : '—'}`
                              : `Cost center: ${a.scope_id ? costCenterNameById.get(a.scope_id) ?? '—' : '—'}`}
                        </TableCell>
                        <TableCell>{a.threshold_max === null ? '—' : a.threshold_max.toLocaleString()}</TableCell>
                        <TableCell align="right">
                          <Button size="small" onClick={() => openEditAssignment(a)}>
                            Edit
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))}
                    {assignments.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={5} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                          No assignments yet.
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </TableContainer>
            </>
          )}
        </Box>
      </Paper>

      {/* Stage dialog */}
      <Dialog open={stageDialogOpen} onClose={closeStageDialog} maxWidth="sm" fullWidth>
        <DialogTitle>{editStage ? 'Edit Stage' : 'New Stage'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              label="Stage name"
              fullWidth
              value={stageForm.name}
              onChange={(e) => setStageForm((v) => ({ ...v, name: e.target.value }))}
            />
            <TextField
              label="Approver role"
              fullWidth
              value={stageForm.approver_role}
              helperText="A role label, e.g. Cost Control Manager, PM, DGM, Finance."
              onChange={(e) => setStageForm((v) => ({ ...v, approver_role: e.target.value }))}
            />
            <TextField
              label="Sequence order"
              type="number"
              value={stageForm.sequence_order}
              onChange={(e) => setStageForm((v) => ({ ...v, sequence_order: Number(e.target.value) }))}
              sx={{ width: 200 }}
            />
            <TextField
              label="Threshold amount (optional)"
              type="number"
              value={stageForm.threshold_amount}
              helperText="Leave blank if this stage always goes to the same next stage regardless of amount."
              onChange={(e) => setStageForm((v) => ({ ...v, threshold_amount: e.target.value }))}
              fullWidth
            />
            <TextField
              select
              label={hasThreshold ? 'Next stage — at or below threshold' : 'Next stage'}
              fullWidth
              value={stageForm.next_stage_low_id}
              onChange={(e) => setStageForm((v) => ({ ...v, next_stage_low_id: e.target.value }))}
            >
              <MenuItem value="">None (this is a final stage)</MenuItem>
              {stagesForAppliesTo
                .filter((s) => !editStage || s.id !== editStage.id)
                .map((s) => (
                  <MenuItem key={s.id} value={s.id}>
                    {s.name}
                  </MenuItem>
                ))}
            </TextField>
            {hasThreshold && (
              <TextField
                select
                label="Next stage — above threshold"
                fullWidth
                value={stageForm.next_stage_high_id}
                onChange={(e) => setStageForm((v) => ({ ...v, next_stage_high_id: e.target.value }))}
              >
                <MenuItem value="">None</MenuItem>
                {stagesForAppliesTo
                  .filter((s) => !editStage || s.id !== editStage.id)
                  .map((s) => (
                    <MenuItem key={s.id} value={s.id}>
                      {s.name}
                    </MenuItem>
                  ))}
              </TextField>
            )}
            <FormControlLabel
              control={
                <Switch
                  checked={stageForm.requires_offer_entry}
                  onChange={(e) => setStageForm((v) => ({ ...v, requires_offer_entry: e.target.checked }))}
                />
              }
              label="Requires a vendor offer to be entered before this stage"
            />
            <FormControlLabel
              control={
                <Switch
                  checked={stageForm.requires_offer_selection}
                  onChange={(e) => setStageForm((v) => ({ ...v, requires_offer_selection: e.target.checked }))}
                />
              }
              label="Requires an offer to be selected before this stage"
            />
            <FormControlLabel
              control={
                <Switch
                  checked={stageForm.blocks_offer_submitter_approval}
                  onChange={(e) =>
                    setStageForm((v) => ({ ...v, blocks_offer_submitter_approval: e.target.checked }))
                  }
                />
              }
              label="The person who submitted the offer can't approve this stage"
            />
            <FormControlLabel
              control={
                <Switch
                  checked={stageForm.is_finance_terminal_stage}
                  onChange={(e) => setStageForm((v) => ({ ...v, is_finance_terminal_stage: e.target.checked }))}
                />
              }
              label="This is Finance's terminal stage"
            />
            <FormControlLabel
              control={
                <Switch
                  checked={stageForm.is_active}
                  onChange={(e) => setStageForm((v) => ({ ...v, is_active: e.target.checked }))}
                />
              }
              label="Active"
            />
            {occupancyWarning && (
              <Alert severity="warning">
                {occupancyWarning.openRequests > 0 && (
                  <>
                    {occupancyWarning.openRequests} open request{occupancyWarning.openRequests === 1 ? '' : 's'}
                  </>
                )}
                {occupancyWarning.openRequests > 0 && occupancyWarning.openInvoices > 0 && ' and '}
                {occupancyWarning.openInvoices > 0 && (
                  <>
                    {occupancyWarning.openInvoices} open invoice{occupancyWarning.openInvoices === 1 ? '' : 's'}
                  </>
                )}{' '}
                {occupancyWarning.openRequests + occupancyWarning.openInvoices === 1 ? 'is' : 'are'} currently
                sitting at this stage. This change applies the next time each one advances — it won't move or
                reroute anything that's already there.
              </Alert>
            )}
            {stageSaveError && <Alert severity="error">{stageSaveError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={closeStageDialog} disabled={stageSaving}>
            Cancel
          </Button>
          {occupancyWarning ? (
            <Button onClick={() => saveStage(true)} variant="contained" color="warning" disabled={stageSaving}>
              {stageSaving ? 'Saving…' : 'Save anyway'}
            </Button>
          ) : (
            <Button onClick={() => saveStage()} variant="contained" disabled={stageSaving || occupancyChecking}>
              {occupancyChecking ? 'Checking…' : stageSaving ? 'Saving…' : 'Save'}
            </Button>
          )}
        </DialogActions>
      </Dialog>

      {/* Assignment dialog */}
      <Dialog open={assignmentDialogOpen} onClose={closeAssignmentDialog} maxWidth="sm" fullWidth>
        <DialogTitle>{editAssignment ? 'Edit Assignment' : 'New Assignment'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              select
              label="Team member"
              fullWidth
              value={assignmentForm.user_id}
              onChange={(e) => setAssignmentForm((v) => ({ ...v, user_id: e.target.value }))}
            >
              {members.map((m) => (
                <MenuItem key={m.user_id} value={m.user_id}>
                  {m.name?.trim() || m.email}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              select
              label="Stage"
              fullWidth
              value={assignmentForm.workflow_stage_id}
              onChange={(e) => setAssignmentForm((v) => ({ ...v, workflow_stage_id: e.target.value }))}
            >
              {stages.map((s) => (
                <MenuItem key={s.id} value={s.id}>
                  {s.name} ({s.applies_to === 'requests' ? 'Requests' : 'Invoices'})
                </MenuItem>
              ))}
            </TextField>
            <TextField
              select
              label="Scope"
              fullWidth
              value={assignmentForm.scope_type}
              onChange={(e) =>
                setAssignmentForm((v) => ({ ...v, scope_type: e.target.value as ScopeType, scope_id: '' }))
              }
            >
              <MenuItem value="global">Global (whole company)</MenuItem>
              <MenuItem value="department">Department</MenuItem>
              <MenuItem value="cost_center">Cost center</MenuItem>
            </TextField>
            {assignmentForm.scope_type !== 'global' && (
              <TextField
                select
                label={assignmentForm.scope_type === 'department' ? 'Department' : 'Cost center'}
                fullWidth
                value={assignmentForm.scope_id}
                onChange={(e) => setAssignmentForm((v) => ({ ...v, scope_id: e.target.value }))}
              >
                {(assignmentForm.scope_type === 'department' ? departments : costCenters).map((row) => (
                  <MenuItem key={row.id} value={row.id}>
                    {row.name}
                  </MenuItem>
                ))}
              </TextField>
            )}
            <TextField
              label="Personal approval cap (optional)"
              type="number"
              fullWidth
              value={assignmentForm.threshold_max}
              helperText="Leave blank to allow up to the stage's own threshold."
              onChange={(e) => setAssignmentForm((v) => ({ ...v, threshold_max: e.target.value }))}
            />
            {assignmentSaveError && <Alert severity="error">{assignmentSaveError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={closeAssignmentDialog} disabled={assignmentSaving}>
            Cancel
          </Button>
          <Button onClick={saveAssignment} variant="contained" disabled={assignmentSaving}>
            {assignmentSaving ? 'Saving…' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}