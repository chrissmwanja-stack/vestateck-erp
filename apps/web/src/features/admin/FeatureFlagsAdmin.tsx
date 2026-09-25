import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  FormControlLabel,
  IconButton,
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
import { Add, Delete, Edit } from '@mui/icons-material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from './usePlatformAdminSession';
import { FLAG_KEY_RE, overridesOf, type FlagRow } from './platformConfig';

// /admin/flags -- feature flags, independent of module entitlement.
//
// A module (tenant_modules) is what a company pays for; a flag is a
// switch inside the product: a redesign in pilot, a risky integration, a
// behaviour one customer asked to hide. Each flag has a platform default
// and optional per-company overrides (set here or on Company Detail ->
// Feature flags). Code checks feature_enabled('key') server-side or
// get_my_feature_flags() on the client; unknown keys are false, so a flag
// can be created here before -- or after -- the code that reads it ships.

interface FlagDraft {
  key: string;
  description: string;
  default_enabled: boolean;
  isNew: boolean;
}

export default function FeatureFlagsAdmin() {
  const [rows, setRows] = useState<FlagRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [editing, setEditing] = useState<FlagDraft | null>(null);
  const [deleting, setDeleting] = useState<FlagRow | null>(null);
  const [busy, setBusy] = useState(false);
  const { session } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(session);

  const load = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('list_feature_flags');
    if (err) {
      setError(friendlyPlatformError(err.message));
      setRows([]);
      return;
    }
    setRows((data ?? []) as FlagRow[]);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const save = async () => {
    if (!editing) return;
    setBusy(true);
    const { error: err } = await supabase.rpc('save_feature_flag', {
      p_key: editing.key.trim(),
      // the function does nullif(btrim(p_description), '') server-side,
      // so an empty string round-trips to NULL without us sending it here
      p_description: editing.description.trim(),
      p_default_enabled: editing.default_enabled,
    });
    setBusy(false);
    if (err) {
      setError(friendlyPlatformError(err.message).replace(/^FLAG_[A-Z_]+:\s*/, ''));
      return;
    }
    setNotice(editing.isNew ? `Flag "${editing.key}" created.` : `Flag "${editing.key}" saved.`);
    setEditing(null);
    void load();
  };

  const confirmDelete = async () => {
    if (!deleting) return;
    setBusy(true);
    const { error: err } = await supabase.rpc('delete_feature_flag', { p_key: deleting.key });
    setBusy(false);
    setDeleting(null);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    setNotice('Flag deleted; every company falls back to "off".');
    void load();
  };

  const clearOverride = async (tenantId: string, key: string) => {
    setBusy(true);
    // p_enabled has no SQL default; NULL is the explicit "clear override" signal
    // (see set_tenant_feature_flag), so this cast reflects a deliberate null.
    const { error: err } = await supabase.rpc('set_tenant_feature_flag', { p_tenant_id: tenantId, p_key: key, p_enabled: null as unknown as boolean });
    setBusy(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    void load();
  };

  const keyValid = !editing || !editing.isNew || FLAG_KEY_RE.test(editing.key.trim());

  return (
    <Box sx={{ p: 3 }}>
      <Stack direction="row" alignItems="flex-start" justifyContent="space-between" sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h5">Feature flags</Typography>
          <Typography variant="body2" color="text.secondary">
            Switches inside the product, separate from which modules a company pays for. Set a platform default here and
            override per company from its detail page.
          </Typography>
        </Box>
        <Tooltip title={blockedReason ?? ''}>
          <span>
            <Button
              variant="contained"
              startIcon={<Add />}
              onClick={() => setEditing({ key: '', description: '', default_enabled: false, isNew: true })}
              disabled={!!blockedReason}
            >
              New flag
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
      ) : rows.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 3 }}>
          <Typography variant="body2" color="text.secondary">
            No flags yet. Create one, then read it in code with <code>feature_enabled('key')</code> (SQL) or{' '}
            <code>get_my_feature_flags()</code> (client). Until a flag exists it resolves to off.
          </Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Flag</TableCell>
                <TableCell>Default</TableCell>
                <TableCell>Overrides</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((r) => {
                const overrides = overridesOf(r);
                return (
                  <TableRow key={r.key} hover>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600} sx={{ fontFamily: 'monospace' }}>
                        {r.key}
                      </Typography>
                      {r.description && (
                        <Typography variant="caption" color="text.secondary">
                          {r.description}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={r.default_enabled ? 'on' : 'off'} color={r.default_enabled ? 'success' : 'default'} />
                    </TableCell>
                    <TableCell>
                      {overrides.length === 0 ? (
                        <Typography variant="caption" color="text.secondary">
                          none — every company uses the default
                        </Typography>
                      ) : (
                        <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap>
                          {overrides.map((o) => (
                            <Tooltip key={o.tenant_id} title={o.note ?? ''}>
                              <Chip
                                size="small"
                                variant="outlined"
                                color={o.enabled ? 'success' : 'warning'}
                                label={`${o.tenant_name}: ${o.enabled ? 'on' : 'off'}`}
                                component={RouterLink}
                                to={`/admin/companies/${o.tenant_id}?tab=flags`}
                                clickable
                                onDelete={blockedReason ? undefined : () => void clearOverride(o.tenant_id, r.key)}
                              />
                            </Tooltip>
                          ))}
                        </Stack>
                      )}
                    </TableCell>
                    <TableCell align="right" sx={{ whiteSpace: 'nowrap' }}>
                      <IconButton
                        size="small"
                        aria-label={`edit ${r.key}`}
                        onClick={() => setEditing({ key: r.key, description: r.description ?? '', default_enabled: r.default_enabled, isNew: false })}
                        disabled={!!blockedReason}
                      >
                        <Edit fontSize="small" />
                      </IconButton>
                      <IconButton size="small" aria-label={`delete ${r.key}`} onClick={() => setDeleting(r)} disabled={!!blockedReason}>
                        <Delete fontSize="small" />
                      </IconButton>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Dialog open={!!editing} onClose={busy ? undefined : () => setEditing(null)} maxWidth="xs" fullWidth>
        <DialogTitle>{editing?.isNew ? 'New feature flag' : `Edit ${editing?.key}`}</DialogTitle>
        <DialogContent dividers>
          {editing && (
            <Stack spacing={2}>
              <TextField
                label="Key"
                value={editing.key}
                onChange={(e) => setEditing({ ...editing, key: e.target.value.toLowerCase() })}
                disabled={!editing.isNew}
                error={!keyValid}
                helperText={keyValid ? 'e.g. new_dashboard or pmo.gantt_v2 — this is what code checks' : 'Lowercase letters, digits, dots or underscores; 2–64 chars; starts with a letter'}
                autoFocus
                fullWidth
              />
              <TextField
                label="What it switches"
                value={editing.description}
                onChange={(e) => setEditing({ ...editing, description: e.target.value })}
                fullWidth
                multiline
                minRows={2}
              />
              <FormControlLabel
                control={<Switch checked={editing.default_enabled} onChange={(e) => setEditing({ ...editing, default_enabled: e.target.checked })} />}
                label={`Default: ${editing.default_enabled ? 'on' : 'off'} for every company without an override`}
              />
            </Stack>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditing(null)} disabled={busy}>
            Cancel
          </Button>
          <Button variant="contained" onClick={() => void save()} disabled={busy || !keyValid || !editing?.key.trim()}>
            {busy ? 'Saving…' : editing?.isNew ? 'Create' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={!!deleting} onClose={() => setDeleting(null)}>
        <DialogTitle>Delete flag "{deleting?.key}"?</DialogTitle>
        <DialogContent>
          <DialogContentText>
            Its per-company overrides go with it and any code still checking it will see "off". Fine for a flag whose
            feature has fully shipped or been abandoned.
          </DialogContentText>
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