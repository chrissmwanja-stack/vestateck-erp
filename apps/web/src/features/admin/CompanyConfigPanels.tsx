import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  MenuItem,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  ToggleButton,
  ToggleButtonGroup,
  Tooltip,
  Typography,
} from '@mui/material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { friendlyPlatformError } from './usePlatformAdminSession';
import { choiceOf, describeFlag, enabledFromChoice, type FlagChoice, type TemplateRow, type TenantFlagRow } from './platformConfig';

// Two panels mounted on Company Detail (20260923090000):
//   TenantFeatureFlagsPanel  -- the "Feature flags" tab: per-company
//                               override of every platform flag.
//   ApplyWorkflowTemplate    -- button + dialog on the "Approval
//                               thresholds" tab: replace this company's
//                               pipeline with a template's.
// Kept out of CompanyDetail.tsx, which is already long, and so each can
// be tested on its own.

const MIN_REASON = 5;

export function TenantFeatureFlagsPanel({ tenantId, blockedReason }: { tenantId: string; blockedReason: string | null }) {
  const [rows, setRows] = useState<TenantFlagRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [savingKey, setSavingKey] = useState<string | null>(null);
  const [notes, setNotes] = useState<Record<string, string>>({});

  const load = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('get_tenant_feature_flags', { p_tenant_id: tenantId });
    if (err) {
      setError(friendlyPlatformError(err.message));
      setRows([]);
      return;
    }
    const list = (data ?? []) as TenantFlagRow[];
    setRows(list);
    setNotes(Object.fromEntries(list.map((r) => [r.key, r.note ?? ''])));
  }, [tenantId]);

  useEffect(() => {
    void load();
  }, [load]);

  const set = async (key: string, choice: FlagChoice) => {
    setSavingKey(key);
    setError(null);
    const { error: err } = await supabase.rpc('set_tenant_feature_flag', {
      p_tenant_id: tenantId,
      p_key: key,
      p_enabled: enabledFromChoice(choice),
      p_note: notes[key]?.trim() || null,
    });
    setSavingKey(null);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    void load();
  };

  if (rows === null) return <CircularProgress size={24} />;

  return (
    <>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Switches inside the product for this company only. "Default" follows the platform-wide setting; "On"/"Off"
        pins it here. Manage the flags themselves under <RouterLink to="/admin/flags">Feature flags</RouterLink>.
      </Typography>
      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {rows.length === 0 ? (
        <Typography variant="body2" color="text.secondary">
          No feature flags exist yet.
        </Typography>
      ) : (
        <Paper variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Flag</TableCell>
                <TableCell>Effective</TableCell>
                <TableCell>Setting for this company</TableCell>
                <TableCell>Note</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((r) => {
                const choice = choiceOf(r);
                return (
                  <TableRow key={r.key}>
                    <TableCell>
                      <Typography variant="body2" sx={{ fontFamily: 'monospace' }}>
                        {r.key}
                      </Typography>
                      {r.description && (
                        <Typography variant="caption" color="text.secondary">
                          {r.description}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={describeFlag(r)} color={r.effective ? 'success' : 'default'} variant={r.override == null ? 'outlined' : 'filled'} />
                    </TableCell>
                    <TableCell>
                      <Tooltip title={blockedReason ?? ''}>
                        <span>
                          <ToggleButtonGroup
                            size="small"
                            exclusive
                            value={choice}
                            disabled={!!blockedReason || savingKey === r.key}
                            onChange={(_, v: FlagChoice | null) => {
                              if (v && v !== choice) void set(r.key, v);
                            }}
                            aria-label={`${r.key} setting`}
                          >
                            <ToggleButton value="default">Default ({r.default_enabled ? 'on' : 'off'})</ToggleButton>
                            <ToggleButton value="on">On</ToggleButton>
                            <ToggleButton value="off">Off</ToggleButton>
                          </ToggleButtonGroup>
                        </span>
                      </Tooltip>
                    </TableCell>
                    <TableCell sx={{ width: 260 }}>
                      <TextField
                        size="small"
                        placeholder="why (goes in the audit log)"
                        value={notes[r.key] ?? ''}
                        onChange={(e) => setNotes((prev) => ({ ...prev, [r.key]: e.target.value }))}
                        onBlur={() => {
                          if (r.override != null && (notes[r.key] ?? '') !== (r.note ?? '')) void set(r.key, choice);
                        }}
                        fullWidth
                        disabled={!!blockedReason}
                      />
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </Paper>
      )}
    </>
  );
}

export function ApplyWorkflowTemplate({
  tenantId,
  tenantName,
  currentTemplate,
  blockedReason,
  onApplied,
}: {
  tenantId: string;
  tenantName: string;
  currentTemplate: string | null;
  blockedReason: string | null;
  onApplied: (msg: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [templates, setTemplates] = useState<TemplateRow[] | null>(null);
  const [key, setKey] = useState('');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open || templates !== null) return;
    supabase.rpc('list_industry_templates', { p_include_inactive: false }).then(({ data, error: err }) => {
      if (err) {
        setError(friendlyPlatformError(err.message));
        setTemplates([]);
        return;
      }
      const list = (data ?? []) as TemplateRow[];
      setTemplates(list);
      setKey(list.find((t) => t.key === currentTemplate)?.key ?? list.find((t) => t.is_default)?.key ?? list[0]?.key ?? '');
    });
  }, [open, templates, currentTemplate]);

  const selected = useMemo(() => templates?.find((t) => t.key === key) ?? null, [templates, key]);
  const canApply = !!key && reason.trim().length >= MIN_REASON && !busy;

  const apply = async () => {
    setBusy(true);
    setError(null);
    const { data, error: err } = await supabase.rpc('apply_workflow_template', { p_tenant_id: tenantId, p_template_key: key, p_reason: reason.trim() });
    setBusy(false);
    if (err) {
      setError(friendlyPlatformError(err.message).replace(/^(WORKFLOW_IN_USE|REASON_REQUIRED|TEMPLATE_NOT_FOUND):\s*/, ''));
      return;
    }
    const res = (data ?? {}) as { stages_created?: number; stages_retired?: number };
    setOpen(false);
    setReason('');
    onApplied(`Applied "${selected?.name ?? key}": ${res.stages_created ?? 0} stages created, ${res.stages_retired ?? 0} retired.`);
  };

  return (
    <>
      <Tooltip title={blockedReason ?? ''}>
        <span>
          <Button size="small" variant="outlined" onClick={() => setOpen(true)} disabled={!!blockedReason}>
            Apply template…
          </Button>
        </span>
      </Tooltip>
      <Dialog open={open} onClose={busy ? undefined : () => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Apply a workflow template to {tenantName}</DialogTitle>
        <DialogContent dividers>
          <Stack spacing={2}>
            <DialogContentText>
              Replaces this company's request approval pipeline with the template's stages. The current stages are
              retired (kept for history), not deleted. Refused while any request is mid-approval.
            </DialogContentText>
            {templates === null ? (
              <CircularProgress size={20} />
            ) : (
              <TextField select label="Template" value={key} onChange={(e) => setKey(e.target.value)} fullWidth>
                {templates.map((t) => (
                  <MenuItem key={t.key} value={t.key}>
                    {t.name} — {t.stage_count} stage{t.stage_count === 1 ? '' : 's'}
                    {t.key === currentTemplate ? ' (created from this)' : ''}
                  </MenuItem>
                ))}
              </TextField>
            )}
            {selected?.description && (
              <Typography variant="caption" color="text.secondary">
                {selected.description}
              </Typography>
            )}
            <TextField
              label="Reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              helperText={`At least ${MIN_REASON} characters — recorded in the audit log`}
              fullWidth
              multiline
              minRows={2}
            />
            {error && <Alert severity="error">{error}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)} disabled={busy}>
            Cancel
          </Button>
          <Button variant="contained" color="warning" onClick={() => void apply()} disabled={!canApply}>
            {busy ? 'Applying…' : 'Apply template'}
          </Button>
        </DialogActions>
      </Dialog>
    </>
  );
}
