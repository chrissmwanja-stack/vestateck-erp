import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Checkbox,
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
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { Edit } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useTenantAdminAccess } from './useTenantAdminAccess';

const ALL_MODULES = ['hr', 'legal', 'bd', 'it', 'pmo', 'machine_operation', 'sustainability', 'procurement'] as const;
const MODULE_LABELS: Record<(typeof ALL_MODULES)[number], string> = {
  hr: 'HR',
  legal: 'Legal & Compliance',
  bd: 'Business Development',
  it: 'IT Support',
  pmo: 'Project Management Office',
  machine_operation: 'Machine Operation',
  sustainability: 'Sustainability & Business Excellence',
  procurement: 'Procurement & Purchasing',
};
const ROLES = ['admin', 'manager', 'member'] as const;

const FINANCE_ROLES = ['', 'cost_control', 'finance'] as const;
const FINANCE_ROLE_LABELS: Record<(typeof FINANCE_ROLES)[number], string> = {
  '': 'No finance access',
  cost_control: 'Cost Control (view only)',
  finance: 'Finance (view & edit)',
};

interface ModuleGrant {
  module: string;
  role: string;
}

interface TeamMember {
  user_id: string;
  name: string | null;
  email: string;
  role_title: string | null;
  is_company_admin: boolean;
  modules: ModuleGrant[];
  finance_role: 'finance' | 'cost_control' | null;
}

export default function TeamMembersAdmin() {
  const access = useTenantAdminAccess();

  const [members, setMembers] = useState<TeamMember[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [editing, setEditing] = useState<TeamMember | null>(null);
  const [draftModules, setDraftModules] = useState<Record<string, { checked: boolean; role: (typeof ROLES)[number] }>>({});
  const [draftFinanceRole, setDraftFinanceRole] = useState<(typeof FINANCE_ROLES)[number]>('');
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const loadMembers = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    const { data, error } = await supabase.rpc('get_tenant_team_members');
    if (error) setLoadError(error.message);
    else setMembers((data ?? []) as TeamMember[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    if (access?.isAdmin) loadMembers();
  }, [access?.isAdmin, loadMembers]);

  const openEdit = (member: TeamMember) => {
    setSaveError(null);
    setEditing(member);
    const modules: Record<string, { checked: boolean; role: (typeof ROLES)[number] }> = {};
    for (const m of ALL_MODULES) {
      const existing = member.modules.find((g) => g.module === m);
      modules[m] = { checked: !!existing, role: (existing?.role as (typeof ROLES)[number]) ?? 'member' };
    }
    setDraftModules(modules);
    setDraftFinanceRole((member.finance_role as (typeof FINANCE_ROLES)[number]) ?? '');
  };

  const toggleModule = (module: string) => {
    setDraftModules((v) => ({ ...v, [module]: { ...v[module], checked: !v[module].checked } }));
  };

  const setModuleRole = (module: string, role: (typeof ROLES)[number]) => {
    setDraftModules((v) => ({ ...v, [module]: { ...v[module], role } }));
  };

  const save = async () => {
    if (!editing) return;
    setSaving(true);
    setSaveError(null);

    try {
      const original = new Map(editing.modules.map((g) => [g.module, g.role]));
      for (const module of ALL_MODULES) {
        const draft = draftModules[module];
        const had = original.has(module);
        if (draft.checked) {
          if (!had || original.get(module) !== draft.role) {
            const { error } = await supabase.rpc('set_staff_module_role', {
              p_user_id: editing.user_id,
              p_module: module,
              p_role: draft.role,
            });
            if (error) throw error;
          }
        } else if (had) {
          const { error } = await supabase.rpc('remove_staff_module', {
            p_user_id: editing.user_id,
            p_module: module,
          });
          if (error) throw error;
        }
      }

      const originalFinance = editing.finance_role ?? '';
      if (draftFinanceRole !== originalFinance) {
        if (draftFinanceRole) {
          const { error } = await supabase.rpc('set_finance_role', {
            p_user_id: editing.user_id,
            p_role: draftFinanceRole,
          });
          if (error) throw error;
        } else {
          const { error } = await supabase.rpc('remove_finance_role', { p_user_id: editing.user_id });
          if (error) throw error;
        }
      }

      setNotice(`Updated access for ${editing.email}.`);
      setEditing(null);
      loadMembers();
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : 'Could not save changes.');
    } finally {
      setSaving(false);
    }
  };

  if (access?.isAdmin === false) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600, mx: 'auto', mt: 4 }}>
        Managing team member access is only available to company admins.
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1000 }}>
      <Typography variant="h5" sx={{ mb: 1 }}>
        Team members
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Change what an existing member has access to — add or remove modules and finance
        access any time after they've accepted their invite.
      </Typography>

      {loadError && <Alert severity="error" sx={{ mb: 2 }}>{loadError}</Alert>}
      {notice && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setNotice(null)}>
          {notice}
        </Alert>
      )}

      <Paper variant="outlined">
        {loading ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Name</TableCell>
                  <TableCell>Email</TableCell>
                  <TableCell>Modules</TableCell>
                  <TableCell>Finance</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {members.map((m) => (
                  <TableRow key={m.user_id}>
                    <TableCell>{m.name || '—'}</TableCell>
                    <TableCell>{m.email}</TableCell>
                    <TableCell>
                      <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap>
                        {m.is_company_admin && <Chip size="small" color="primary" label="Company admin" />}
                        {m.modules.map((g) => (
                          <Chip
                            key={g.module}
                            size="small"
                            label={`${MODULE_LABELS[g.module as (typeof ALL_MODULES)[number]] ?? g.module} (${g.role})`}
                          />
                        ))}
                        {m.modules.length === 0 && !m.is_company_admin && (
                          <Typography variant="body2" color="text.secondary">
                            None
                          </Typography>
                        )}
                      </Stack>
                    </TableCell>
                    <TableCell>
                      {m.finance_role ? (
                        <Chip size="small" label={FINANCE_ROLE_LABELS[m.finance_role]} />
                      ) : (
                        <Typography variant="body2" color="text.secondary">
                          None
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell align="right">
                      <Button size="small" startIcon={<Edit />} onClick={() => openEdit(m)}>
                        Edit access
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {members.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} align="center">
                      <Typography variant="body2" color="text.secondary" sx={{ py: 3 }}>
                        No team members yet.
                      </Typography>
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={!!editing} onClose={() => !saving && setEditing(null)} maxWidth="sm" fullWidth>
        <DialogTitle>Edit access — {editing?.email}</DialogTitle>
        <DialogContent>
          <Stack spacing={1.5} sx={{ mt: 1 }}>
            {ALL_MODULES.map((module) => (
              <Stack key={module} direction="row" spacing={2} alignItems="center">
                <FormControlLabel
                  sx={{ minWidth: 220 }}
                  control={
                    <Checkbox
                      checked={draftModules[module]?.checked ?? false}
                      onChange={() => toggleModule(module)}
                      disabled={saving}
                    />
                  }
                  label={MODULE_LABELS[module]}
                />
                <TextField
                  select
                  size="small"
                  label="Role"
                  value={draftModules[module]?.role ?? 'member'}
                  onChange={(e) => setModuleRole(module, e.target.value as (typeof ROLES)[number])}
                  disabled={!draftModules[module]?.checked || saving}
                  sx={{ width: 160 }}
                >
                  {ROLES.map((role) => (
                    <MenuItem key={role} value={role}>
                      {role}
                    </MenuItem>
                  ))}
                </TextField>
              </Stack>
            ))}

            <TextField
              select
              size="small"
              label="Finance access"
              value={draftFinanceRole}
              onChange={(e) => setDraftFinanceRole(e.target.value as (typeof FINANCE_ROLES)[number])}
              disabled={saving}
              sx={{ width: 320 }}
            >
              {FINANCE_ROLES.map((role) => (
                <MenuItem key={role} value={role}>
                  {FINANCE_ROLE_LABELS[role]}
                </MenuItem>
              ))}
            </TextField>

            {saveError && <Alert severity="error">{saveError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditing(null)} disabled={saving}>
            Cancel
          </Button>
          <Button variant="contained" onClick={save} disabled={saving}>
            {saving ? 'Saving…' : 'Save changes'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}