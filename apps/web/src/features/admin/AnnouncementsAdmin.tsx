import { useCallback, useEffect, useMemo, useState } from 'react';
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
import { Add, Delete, Edit } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from './usePlatformAdminSession';
import {
  ANNOUNCEMENT_STATE_LABEL,
  announcementDraftFrom,
  emptyAnnouncementDraft,
  fromLocalInput,
  sortAnnouncements,
  validateAnnouncement,
  type AnnouncementDraft,
  type AnnouncementRow,
  type AnnouncementState,
} from './platformConfig';

// /admin/announcements -- notices from the operator to the people using
// the platform. Shown as a banner (AnnouncementBanner, mounted app-wide)
// to every signed-in user of the targeted company, or of every company
// when no company is chosen. Scheduled by a start/end window; info and
// warning notices can be dismissed per user, critical ones cannot.

interface CompanyOption {
  id: string;
  name: string;
}

const SEVERITY_COLOR: Record<string, 'info' | 'warning' | 'error'> = { info: 'info', warning: 'warning', critical: 'error' };
const STATE_COLOR: Record<AnnouncementState, 'default' | 'success' | 'info' | 'warning'> = {
  live: 'success',
  scheduled: 'info',
  ended: 'default',
  disabled: 'warning',
};

function fmt(iso: string | null): string {
  return iso ? new Date(iso).toLocaleString() : '—';
}

export default function AnnouncementsAdmin() {
  const [rows, setRows] = useState<AnnouncementRow[] | null>(null);
  const [companies, setCompanies] = useState<CompanyOption[]>([]);
  const [includePast, setIncludePast] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [editing, setEditing] = useState<AnnouncementDraft | null>(null);
  const [deleting, setDeleting] = useState<AnnouncementRow | null>(null);
  const [busy, setBusy] = useState(false);
  const { session } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(session);

  const load = useCallback(async () => {
    const [{ data, error: err }, { data: cos }] = await Promise.all([
      supabase.rpc('list_platform_announcements', { p_include_past: includePast }),
      supabase.rpc('get_companies_overview'),
    ]);
    if (err) {
      setError(friendlyPlatformError(err.message));
      setRows([]);
      return;
    }
    setRows(sortAnnouncements((data ?? []) as AnnouncementRow[]));
    setCompanies(((cos ?? []) as Array<{ tenant_id: string; name: string }>).map((c) => ({ id: c.tenant_id, name: c.name })));
  }, [includePast]);

  useEffect(() => {
    void load();
  }, [load]);

  const confirmDelete = async () => {
    if (!deleting) return;
    setBusy(true);
    const { error: err } = await supabase.rpc('delete_platform_announcement', { p_id: deleting.id });
    setBusy(false);
    setDeleting(null);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    setNotice('Announcement deleted.');
    void load();
  };

  const toggleActive = async (row: AnnouncementRow) => {
    setBusy(true);
    const { error: err } = await supabase.rpc('save_platform_announcement', {
      p_id: row.id,
      p_title: row.title,
      p_body: row.body,
      p_severity: row.severity,
      p_tenant_id: row.tenant_id,
      p_starts_at: row.starts_at,
      p_ends_at: row.ends_at,
      p_dismissible: row.dismissible,
      p_link_url: row.link_url,
      p_link_label: row.link_label,
      p_is_active: !row.is_active,
    });
    setBusy(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    void load();
  };

  return (
    <Box sx={{ p: 3 }}>
      <Stack direction="row" alignItems="flex-start" justifyContent="space-between" sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h5">Announcements</Typography>
          <Typography variant="body2" color="text.secondary">
            A banner every signed-in user sees — for one company or all of them. Use it for maintenance windows, new
            features and anything you would otherwise email.
          </Typography>
        </Box>
        <Stack direction="row" spacing={2} alignItems="center">
          <FormControlLabel control={<Switch size="small" checked={includePast} onChange={(e) => setIncludePast(e.target.checked)} />} label="Show ended" />
          <Tooltip title={blockedReason ?? ''}>
            <span>
              <Button variant="contained" startIcon={<Add />} onClick={() => setEditing(emptyAnnouncementDraft())} disabled={!!blockedReason}>
                New announcement
              </Button>
            </span>
          </Tooltip>
        </Stack>
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
                <TableCell>Announcement</TableCell>
                <TableCell>Audience</TableCell>
                <TableCell>Window</TableCell>
                <TableCell>State</TableCell>
                <TableCell align="right">Dismissed by</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.id} hover>
                  <TableCell sx={{ maxWidth: 420 }}>
                    <Stack direction="row" spacing={1} alignItems="center">
                      <Chip size="small" label={r.severity} color={SEVERITY_COLOR[r.severity] ?? 'info'} variant="outlined" />
                      <Typography variant="body2" fontWeight={600}>
                        {r.title}
                      </Typography>
                    </Stack>
                    <Typography variant="caption" color="text.secondary" sx={{ display: 'block', whiteSpace: 'pre-wrap' }}>
                      {r.body.length > 160 ? `${r.body.slice(0, 160)}…` : r.body}
                    </Typography>
                  </TableCell>
                  <TableCell>{r.tenant_id ? r.tenant_name ?? 'One company' : 'All companies'}</TableCell>
                  <TableCell>
                    <Typography variant="caption" display="block">
                      from {fmt(r.starts_at)}
                    </Typography>
                    <Typography variant="caption" display="block" color="text.secondary">
                      {r.ends_at ? `until ${fmt(r.ends_at)}` : 'open-ended'}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    <Chip size="small" label={ANNOUNCEMENT_STATE_LABEL[r.state as AnnouncementState] ?? r.state} color={STATE_COLOR[r.state as AnnouncementState] ?? 'default'} />
                  </TableCell>
                  <TableCell align="right">{r.dismissible ? r.dismissals : <Typography variant="caption" color="text.secondary">not dismissible</Typography>}</TableCell>
                  <TableCell align="right" sx={{ whiteSpace: 'nowrap' }}>
                    <Button size="small" onClick={() => void toggleActive(r)} disabled={!!blockedReason || busy}>
                      {r.is_active ? 'Disable' : 'Enable'}
                    </Button>
                    <IconButton size="small" aria-label={`edit ${r.title}`} onClick={() => setEditing(announcementDraftFrom(r))} disabled={!!blockedReason}>
                      <Edit fontSize="small" />
                    </IconButton>
                    <IconButton size="small" aria-label={`delete ${r.title}`} onClick={() => setDeleting(r)} disabled={!!blockedReason}>
                      <Delete fontSize="small" />
                    </IconButton>
                  </TableCell>
                </TableRow>
              ))}
              {rows.length === 0 && (
                <TableRow>
                  <TableCell colSpan={6}>
                    <Typography variant="body2" color="text.secondary">
                      Nothing published{includePast ? '' : ' (ended ones are hidden)'}.
                    </Typography>
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {editing && (
        <AnnouncementDialog
          draft={editing}
          companies={companies}
          onClose={() => setEditing(null)}
          onSaved={(msg) => {
            setEditing(null);
            setNotice(msg);
            void load();
          }}
        />
      )}

      <Dialog open={!!deleting} onClose={() => setDeleting(null)}>
        <DialogTitle>Delete "{deleting?.title}"?</DialogTitle>
        <DialogContent>
          <DialogContentText>It disappears from every banner immediately. To keep it for the record, disable it instead.</DialogContentText>
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

function AnnouncementDialog({
  draft: initial,
  companies,
  onClose,
  onSaved,
}: {
  draft: AnnouncementDraft;
  companies: CompanyOption[];
  onClose: () => void;
  onSaved: (msg: string) => void;
}) {
  const [d, setD] = useState(initial);
  const [saving, setSaving] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const errors = useMemo(() => validateAnnouncement(d), [d]);
  const patch = (p: Partial<AnnouncementDraft>) => setD((prev) => ({ ...prev, ...p }));

  const save = async () => {
    setSaving(true);
    setServerError(null);
    const { error } = await supabase.rpc('save_platform_announcement', {
      p_id: d.id,
      p_title: d.title.trim(),
      p_body: d.body.trim(),
      p_severity: d.severity,
      p_tenant_id: d.tenant_id,
      p_starts_at: fromLocalInput(d.starts_at) ?? new Date().toISOString(),
      p_ends_at: fromLocalInput(d.ends_at),
      p_dismissible: d.dismissible,
      p_link_url: d.link_url.trim() || null,
      p_link_label: d.link_label.trim() || null,
      p_is_active: d.is_active,
    });
    setSaving(false);
    if (error) {
      setServerError(friendlyPlatformError(error.message).replace(/^ANNOUNCEMENT_[A-Z_]+:\s*/, ''));
      return;
    }
    onSaved(d.id ? 'Announcement updated.' : 'Announcement published.');
  };

  return (
    <Dialog open onClose={saving ? undefined : onClose} maxWidth="sm" fullWidth>
      <DialogTitle>{d.id ? 'Edit announcement' : 'New announcement'}</DialogTitle>
      <DialogContent dividers>
        <Stack spacing={2}>
          <TextField label="Title" value={d.title} onChange={(e) => patch({ title: e.target.value })} fullWidth autoFocus inputProps={{ maxLength: 120 }} />
          <TextField label="Message" value={d.body} onChange={(e) => patch({ body: e.target.value })} fullWidth multiline minRows={3} inputProps={{ maxLength: 1000 }} />
          <Stack direction="row" spacing={2}>
            <TextField select label="Severity" value={d.severity} onChange={(e) => patch({ severity: e.target.value as AnnouncementDraft['severity'] })} sx={{ width: 180 }}>
              <MenuItem value="info">Info</MenuItem>
              <MenuItem value="warning">Warning</MenuItem>
              <MenuItem value="critical">Critical (cannot be dismissed)</MenuItem>
            </TextField>
            <TextField select label="Audience" value={d.tenant_id ?? ''} onChange={(e) => patch({ tenant_id: e.target.value || null })} fullWidth>
              <MenuItem value="">All companies</MenuItem>
              {companies.map((c) => (
                <MenuItem key={c.id} value={c.id}>
                  {c.name}
                </MenuItem>
              ))}
            </TextField>
          </Stack>
          <Stack direction="row" spacing={2}>
            <TextField
              label="Starts"
              type="datetime-local"
              value={d.starts_at}
              onChange={(e) => patch({ starts_at: e.target.value })}
              InputLabelProps={{ shrink: true }}
              helperText="Empty = now"
              fullWidth
            />
            <TextField
              label="Ends"
              type="datetime-local"
              value={d.ends_at}
              onChange={(e) => patch({ ends_at: e.target.value })}
              InputLabelProps={{ shrink: true }}
              helperText="Empty = until disabled"
              fullWidth
            />
          </Stack>
          <Stack direction="row" spacing={2}>
            <TextField label="Link (optional)" value={d.link_url} onChange={(e) => patch({ link_url: e.target.value })} placeholder="https://status.example.com or /help" fullWidth />
            <TextField label="Link label" value={d.link_label} onChange={(e) => patch({ link_label: e.target.value })} sx={{ width: 200 }} />
          </Stack>
          <Stack direction="row" spacing={2}>
            <FormControlLabel
              control={<Switch checked={d.dismissible} onChange={(e) => patch({ dismissible: e.target.checked })} disabled={d.severity === 'critical'} />}
              label="Users can dismiss"
            />
            <FormControlLabel control={<Switch checked={d.is_active} onChange={(e) => patch({ is_active: e.target.checked })} />} label="Active" />
          </Stack>
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
          {saving ? 'Saving…' : d.id ? 'Save' : 'Publish'}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
