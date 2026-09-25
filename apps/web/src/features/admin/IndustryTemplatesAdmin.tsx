import { useCallback, useEffect, useMemo, useState } from 'react';
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
  DialogContentText,
  DialogTitle,
  Divider,
  FormControlLabel,
  IconButton,
  MenuItem,
  Paper,
  Stack,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { Add, ArrowDownward, ArrowUpward, ContentCopy, Delete, Edit, Star, StarBorder } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from './usePlatformAdminSession';
import {
  TEMPLATE_MODULES,
  describeStage,
  draftFromTemplate,
  emptyStage,
  emptyTemplateDraft,
  itemsFromDraft,
  reindexStages,
  slugifyTemplateKey,
  validateTemplateDraft,
  type StageDraft,
  type TemplateDraft,
  type TemplateRow,
} from './platformConfig';

// /admin/templates -- industry templates as data.
//
// Until 20260923090000 the onboarding presets ('general', 'construction')
// were three hard-coded lists: in seed_tenant_defaults(), in the
// create-tenant edge function's allow-list and in the wizard's dropdown.
// Adding a vertical meant a deploy of all three. Now they are rows in
// industry_templates(+_items); the wizard, the edge function and the seed
// all read from there, and this screen is where they are edited.
//
// A template is: departments (names), modules (keys) and the approval
// pipeline (ordered stages with approver role, optional threshold and
// where each stage routes next -- by position, so the same template can
// be stamped onto any number of companies). Templates that companies
// were created from cannot be deleted (history), only deactivated.

export default function IndustryTemplatesAdmin() {
  const [rows, setRows] = useState<TemplateRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [editing, setEditing] = useState<TemplateDraft | null>(null);
  const [isNew, setIsNew] = useState(false);
  const [deleting, setDeleting] = useState<TemplateRow | null>(null);
  const [busy, setBusy] = useState(false);
  const { session } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(session);

  const load = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('list_industry_templates', { p_include_inactive: true });
    if (err) {
      setError(friendlyPlatformError(err.message));
      setRows([]);
      return;
    }
    setRows((data ?? []) as TemplateRow[]);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const openNew = () => {
    setIsNew(true);
    setEditing({ ...emptyTemplateDraft(), stages: [emptyStage(1)] });
  };
  const openEdit = (row: TemplateRow) => {
    setIsNew(false);
    setEditing(draftFromTemplate(row));
  };
  const openDuplicate = (row: TemplateRow) => {
    const d = draftFromTemplate(row);
    setIsNew(true);
    setEditing({ ...d, key: `${d.key}_copy`.slice(0, 40), name: `${d.name} (copy)` });
  };

  const setDefault = async (key: string) => {
    setBusy(true);
    const { error: err } = await supabase.rpc('set_default_industry_template', { p_key: key });
    setBusy(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    setNotice(`"${key}" is now the default the wizard pre-selects.`);
    void load();
  };

  const confirmDelete = async () => {
    if (!deleting) return;
    setBusy(true);
    const { error: err } = await supabase.rpc('delete_industry_template', { p_key: deleting.key });
    setBusy(false);
    setDeleting(null);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    setNotice('Template deleted.');
    void load();
  };

  return (
    <Box sx={{ p: 3 }}>
      <Stack direction="row" alignItems="flex-start" justifyContent="space-between" sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h5">Industry templates</Typography>
          <Typography variant="body2" color="text.secondary">
            What a new company starts with: departments, modules and the approval pipeline. The wizard offers every
            active template; onboarding a new vertical is a row here, not a deploy.
          </Typography>
        </Box>
        <Tooltip title={blockedReason ?? ''}>
          <span>
            <Button variant="contained" startIcon={<Add />} onClick={openNew} disabled={!!blockedReason}>
              New template
            </Button>
          </span>
        </Tooltip>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {notice && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setNotice(null)}>
          {notice}
        </Alert>
      )}

      {rows === null ? (
        <CircularProgress />
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Template</TableCell>
                <TableCell align="right">Departments</TableCell>
                <TableCell align="right">Modules</TableCell>
                <TableCell align="right">Stages</TableCell>
                <TableCell align="right">Companies</TableCell>
                <TableCell>Status</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.key} hover sx={{ opacity: r.is_active ? 1 : 0.6 }}>
                  <TableCell>
                    <Stack direction="row" spacing={1} alignItems="center">
                      <Tooltip title={r.is_default ? 'Default for the wizard' : 'Make default'}>
                        <span>
                          <IconButton
                            size="small"
                            aria-label={r.is_default ? 'default template' : `make ${r.key} default`}
                            disabled={r.is_default || !r.is_active || !!blockedReason || busy}
                            onClick={() => void setDefault(r.key)}
                          >
                            {r.is_default ? <Star fontSize="small" color="secondary" /> : <StarBorder fontSize="small" />}
                          </IconButton>
                        </span>
                      </Tooltip>
                      <Box>
                        <Typography variant="body2" fontWeight={600}>
                          {r.name} <Typography component="span" variant="caption" color="text.secondary">({r.key})</Typography>
                        </Typography>
                        {r.description && (
                          <Typography variant="caption" color="text.secondary" display="block">
                            {r.description}
                          </Typography>
                        )}
                      </Box>
                    </Stack>
                  </TableCell>
                  <TableCell align="right">{r.department_count}</TableCell>
                  <TableCell align="right">{r.module_count}</TableCell>
                  <TableCell align="right">{r.stage_count}</TableCell>
                  <TableCell align="right">{r.tenants_using}</TableCell>
                  <TableCell>
                    <Chip size="small" label={r.is_active ? 'Active' : 'Inactive'} color={r.is_active ? 'success' : 'default'} variant="outlined" />
                  </TableCell>
                  <TableCell align="right">
                    <Tooltip title="Edit">
                      <span>
                        <IconButton size="small" aria-label={`edit ${r.key}`} onClick={() => openEdit(r)} disabled={!!blockedReason}>
                          <Edit fontSize="small" />
                        </IconButton>
                      </span>
                    </Tooltip>
                    <Tooltip title="Duplicate">
                      <span>
                        <IconButton size="small" aria-label={`duplicate ${r.key}`} onClick={() => openDuplicate(r)} disabled={!!blockedReason}>
                          <ContentCopy fontSize="small" />
                        </IconButton>
                      </span>
                    </Tooltip>
                    <Tooltip title={r.tenants_using > 0 ? 'In use by companies — deactivate instead' : r.is_default ? 'Choose another default first' : 'Delete'}>
                      <span>
                        <IconButton
                          size="small"
                          aria-label={`delete ${r.key}`}
                          onClick={() => setDeleting(r)}
                          disabled={r.tenants_using > 0 || r.is_default || !!blockedReason}
                        >
                          <Delete fontSize="small" />
                        </IconButton>
                      </span>
                    </Tooltip>
                  </TableCell>
                </TableRow>
              ))}
              {rows.length === 0 && (
                <TableRow>
                  <TableCell colSpan={7}>
                    <Typography variant="body2" color="text.secondary">
                      No templates. The migration seeds "general" and "construction"; if they are missing the database is behind.
                    </Typography>
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {editing && (
        <TemplateEditorDialog
          draft={editing}
          isNew={isNew}
          existingKeys={(rows ?? []).map((r) => r.key)}
          onClose={() => setEditing(null)}
          onSaved={(msg) => {
            setEditing(null);
            setNotice(msg);
            void load();
          }}
        />
      )}

      <Dialog open={!!deleting} onClose={() => setDeleting(null)}>
        <DialogTitle>Delete template "{deleting?.name}"?</DialogTitle>
        <DialogContent>
          <DialogContentText>No company was created from it, so nothing else changes. This cannot be undone.</DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDeleting(null)}>Cancel</Button>
          <Button color="error" variant="contained" onClick={() => void confirmDelete()} disabled={busy}>
            Delete
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}

// ---------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------
function TemplateEditorDialog({
  draft: initial,
  isNew,
  existingKeys,
  onClose,
  onSaved,
}: {
  draft: TemplateDraft;
  isNew: boolean;
  existingKeys: string[];
  onClose: () => void;
  onSaved: (msg: string) => void;
}) {
  const [d, setD] = useState<TemplateDraft>(initial);
  const [keyTouched, setKeyTouched] = useState(!isNew);
  const [newDept, setNewDept] = useState('');
  const [saving, setSaving] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);

  const errors = useMemo(() => {
    const e = validateTemplateDraft(d);
    if (isNew && existingKeys.includes(d.key)) e.push(`A template with key "${d.key}" already exists.`);
    return e;
  }, [d, isNew, existingKeys]);

  const patch = (p: Partial<TemplateDraft>) => setD((prev) => ({ ...prev, ...p }));
  const patchStage = (i: number, p: Partial<StageDraft>) =>
    setD((prev) => ({ ...prev, stages: prev.stages.map((s, j) => (j === i ? { ...s, ...p } : s)) }));

  const addDept = () => {
    const v = newDept.trim();
    if (!v) return;
    patch({ departments: [...d.departments, v] });
    setNewDept('');
  };

  const moveStage = (i: number, dir: -1 | 1) => {
    const j = i + dir;
    if (j < 0 || j >= d.stages.length) return;
    const arr = [...d.stages];
    [arr[i], arr[j]] = [arr[j], arr[i]];
    patch({ stages: reindexStages(arr) });
  };
  const removeStage = (i: number) => {
    const arr = d.stages.filter((_, j) => j !== i);
    patch({ stages: reindexStages(arr, i) });
  };

  const save = async () => {
    setSaving(true);
    setServerError(null);
    const { error } = await supabase.rpc('save_industry_template', {
      p_key: d.key,
      p_name: d.name.trim(),
      // the function does nullif(btrim(p_description), '') server-side
      p_description: d.description.trim(),
      p_items: itemsFromDraft(d) as unknown as import('@erp-platform/shared').Json,
      p_is_active: d.is_active,
    });
    setSaving(false);
    if (error) {
      setServerError(friendlyPlatformError(error.message).replace(/^TEMPLATE_[A-Z_]+:\s*/, ''));
      return;
    }
    onSaved(isNew ? `Template "${d.name}" created. It is now offered in the company wizard.` : `Template "${d.name}" saved. Existing companies are not changed.`);
  };

  const stageOptions = d.stages.map((s, i) => ({ value: i + 1, label: `${i + 1}. ${s.name || '(unnamed)'}` }));

  return (
    <Dialog open onClose={saving ? undefined : onClose} maxWidth="md" fullWidth>
      <DialogTitle>{isNew ? 'New industry template' : `Edit "${initial.name}"`}</DialogTitle>
      <DialogContent dividers>
        <Stack spacing={2.5}>
          <Stack direction="row" spacing={2}>
            <TextField
              label="Name"
              value={d.name}
              onChange={(e) => {
                const name = e.target.value;
                patch({ name, ...(isNew && !keyTouched ? { key: slugifyTemplateKey(name) } : {}) });
              }}
              fullWidth
              autoFocus
            />
            <TextField
              label="Key"
              value={d.key}
              onChange={(e) => {
                setKeyTouched(true);
                patch({ key: e.target.value.toLowerCase() });
              }}
              disabled={!isNew}
              helperText={isNew ? 'Stored on every company created from it; cannot change later.' : 'Fixed once created.'}
              sx={{ width: 280 }}
            />
          </Stack>
          <TextField label="Description" value={d.description} onChange={(e) => patch({ description: e.target.value })} fullWidth multiline minRows={1} helperText="Shown under the template in the wizard." />
          <FormControlLabel control={<Switch checked={d.is_active} onChange={(e) => patch({ is_active: e.target.checked })} />} label="Active (offered in the company wizard)" />

          <Divider />
          <Box>
            <Typography variant="subtitle2">Departments ({d.departments.length})</Typography>
            <Typography variant="caption" color="text.secondary">
              Created for the company on day one. Users are assigned to one of these; requests are raised against them.
            </Typography>
            <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap sx={{ mt: 1 }}>
              {d.departments.map((name, i) => (
                <Chip key={`${name}-${i}`} label={name} onDelete={() => patch({ departments: d.departments.filter((_, j) => j !== i) })} />
              ))}
            </Stack>
            <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
              <TextField
                size="small"
                label="Add department"
                value={newDept}
                onChange={(e) => setNewDept(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    addDept();
                  }
                }}
                sx={{ width: 320 }}
              />
              <Button size="small" onClick={addDept} disabled={!newDept.trim()}>
                Add
              </Button>
            </Stack>
          </Box>

          <Divider />
          <Box>
            <Typography variant="subtitle2">Modules enabled by default</Typography>
            <Typography variant="caption" color="text.secondary">
              Finance and core Procurement are always on. The wizard lets the operator adjust per company.
            </Typography>
            <Box sx={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', mt: 0.5 }}>
              {TEMPLATE_MODULES.map((m) => (
                <FormControlLabel
                  key={m.value}
                  control={
                    <Checkbox
                      size="small"
                      checked={d.modules.includes(m.value)}
                      onChange={(e) =>
                        patch({ modules: e.target.checked ? [...d.modules, m.value] : d.modules.filter((x) => x !== m.value) })
                      }
                    />
                  }
                  label={m.label}
                />
              ))}
            </Box>
          </Box>

          <Divider />
          <Box>
            <Stack direction="row" alignItems="center" justifyContent="space-between">
              <Box>
                <Typography variant="subtitle2">Approval pipeline ({d.stages.length} stages)</Typography>
                <Typography variant="caption" color="text.secondary">
                  Requests enter at stage 1 and follow "next". A stage with a threshold routes to "above" when the request
                  amount exceeds it. Leave "next" empty for a terminal stage.
                </Typography>
              </Box>
              <Button size="small" startIcon={<Add />} onClick={() => patch({ stages: [...d.stages, emptyStage(d.stages.length + 1)] })}>
                Add stage
              </Button>
            </Stack>
            <Stack spacing={1.5} sx={{ mt: 1.5 }}>
              {d.stages.map((s, i) => (
                <Paper key={i} variant="outlined" sx={{ p: 1.5 }}>
                  <Stack direction="row" spacing={1} alignItems="flex-start">
                    <Stack sx={{ pt: 0.5 }}>
                      <IconButton size="small" aria-label={`move stage ${i + 1} up`} disabled={i === 0} onClick={() => moveStage(i, -1)}>
                        <ArrowUpward fontSize="inherit" />
                      </IconButton>
                      <IconButton size="small" aria-label={`move stage ${i + 1} down`} disabled={i === d.stages.length - 1} onClick={() => moveStage(i, 1)}>
                        <ArrowDownward fontSize="inherit" />
                      </IconButton>
                    </Stack>
                    <Box sx={{ flex: 1 }}>
                      <Stack direction="row" spacing={1} sx={{ mb: 1 }}>
                        <Typography variant="body2" sx={{ pt: 1, width: 24, fontWeight: 700 }}>
                          {i + 1}.
                        </Typography>
                        <TextField size="small" label="Stage name" value={s.name} onChange={(e) => patchStage(i, { name: e.target.value })} sx={{ flex: 1 }} />
                        <TextField size="small" label="Approver role" value={s.approver_role} onChange={(e) => patchStage(i, { approver_role: e.target.value })} sx={{ flex: 1 }} helperText="Matched against staff role titles" />
                      </Stack>
                      <Stack direction="row" spacing={1} sx={{ pl: 4 }}>
                        <TextField
                          select
                          size="small"
                          label="Next"
                          value={s.next_low ?? ''}
                          onChange={(e) => patchStage(i, { next_low: e.target.value === '' ? null : Number(e.target.value) })}
                          sx={{ width: 220 }}
                        >
                          <MenuItem value="">— end of pipeline —</MenuItem>
                          {stageOptions.filter((o) => o.value !== i + 1).map((o) => (
                            <MenuItem key={o.value} value={o.value}>
                              {o.label}
                            </MenuItem>
                          ))}
                        </TextField>
                        <TextField
                          size="small"
                          type="number"
                          label="Threshold (UGX)"
                          value={s.threshold_amount}
                          onChange={(e) => patchStage(i, { threshold_amount: e.target.value })}
                          inputProps={{ min: 0 }}
                          sx={{ width: 170 }}
                        />
                        <TextField
                          select
                          size="small"
                          label="Above threshold →"
                          value={s.next_high ?? ''}
                          onChange={(e) => patchStage(i, { next_high: e.target.value === '' ? null : Number(e.target.value) })}
                          disabled={s.threshold_amount.trim() === ''}
                          sx={{ width: 220 }}
                        >
                          <MenuItem value="">—</MenuItem>
                          {stageOptions.filter((o) => o.value !== i + 1).map((o) => (
                            <MenuItem key={o.value} value={o.value}>
                              {o.label}
                            </MenuItem>
                          ))}
                        </TextField>
                        <FormControlLabel
                          control={<Checkbox size="small" checked={s.is_finance_terminal_stage} onChange={(e) => patchStage(i, { is_finance_terminal_stage: e.target.checked })} />}
                          label={<Typography variant="caption">Finance terminal</Typography>}
                        />
                      </Stack>
                      <Typography variant="caption" color="text.secondary" sx={{ pl: 4, display: 'block', mt: 0.5 }}>
                        {describeStage(s, d.stages)}
                      </Typography>
                    </Box>
                    <IconButton size="small" aria-label={`remove stage ${i + 1}`} onClick={() => removeStage(i)}>
                      <Delete fontSize="small" />
                    </IconButton>
                  </Stack>
                </Paper>
              ))}
            </Stack>
          </Box>

          {errors.length > 0 && (
            <Alert severity="warning">
              <ul style={{ margin: 0, paddingLeft: 18 }}>
                {errors.map((e) => (
                  <li key={e}>{e}</li>
                ))}
              </ul>
            </Alert>
          )}
          {serverError && <Alert severity="error">{serverError}</Alert>}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={saving}>
          Cancel
        </Button>
        <Button variant="contained" onClick={() => void save()} disabled={saving || errors.length > 0}>
          {saving ? 'Saving…' : isNew ? 'Create template' : 'Save changes'}
        </Button>
      </DialogActions>
    </Dialog>
  );
}