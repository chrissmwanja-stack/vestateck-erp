import { useCallback, useEffect, useState } from 'react';
import {
  Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions,
  DialogContent, DialogTitle, MenuItem, Stack, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../../modules/portals/insurance/db';
import { EmptyRow, ErrorBanner, PageHeader } from '../../modules/portals/insurance/shared';

// Company Accounting & Tax Configuration (Stage 1 UI).
// Lists every accounting_setting_definitions key, the tenant's live value,
// review status and legal-review flag; company admins can propose, approve
// (maker-checker) and record reviews. Configurable != legally approved:
// requires_legal_review keys show a warning chip.

interface DefinitionRow {
  key: string;
  label: string;
  description: string;
  allowed_values: string[];
  implemented_values: string[];
  default_value: string;
  requires_legal_review: boolean;
}

interface SettingRow {
  id: string;
  setting_key: string;
  value: string;
  effective_from: string;
  status: 'draft' | 'approved' | 'withdrawn';
  review_status: 'unreviewed' | 'reviewed';
  review_reference: string | null;
  reviewer_name: string | null;
  rationale: string;
  created_by: string;
}

export default function AccountingSettingsAdmin() {
  const [defs, setDefs] = useState<DefinitionRow[]>([]);
  const [settings, setSettings] = useState<SettingRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [propose, setPropose] = useState<DefinitionRow | null>(null);
  const [form, setForm] = useState({ value: '', effective_from: '', rationale: '' });
  const [review, setReview] = useState<SettingRow | null>(null);
  const [reviewForm, setReviewForm] = useState({ reviewer_name: '', review_reference: '' });
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [d, s] = await Promise.all([
        rows<DefinitionRow>(table('accounting_setting_definitions').select('*').order('key')),
        rows<SettingRow>(
          table('company_accounting_settings')
            .select('*')
            .order('setting_key').order('effective_from', { ascending: false })),
      ]);
      setDefs(d);
      setSettings(s);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const liveFor = (key: string) =>
    settings.find((s) => s.setting_key === key && s.status === 'approved');
  const draftFor = (key: string) =>
    settings.find((s) => s.setting_key === key && s.status === 'draft');

  const submitPropose = async () => {
    if (!propose) return;
    setBusy(true);
    setError(null);
    try {
      await rpc('acct_setting_propose', {
        p_key: propose.key, p_value: form.value,
        p_effective_from: form.effective_from, p_rationale: form.rationale,
      });
      setPropose(null);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const approve = async (s: SettingRow) => {
    setError(null);
    try {
      await rpc('acct_setting_approve', { p_id: s.id });
      await load();
    } catch (e) {
      setError(errorText(e));
    }
  };

  const submitReview = async () => {
    if (!review) return;
    setBusy(true);
    setError(null);
    try {
      await rpc('acct_setting_record_review', {
        p_id: review.id, p_reviewer_name: reviewForm.reviewer_name,
        p_review_reference: reviewForm.review_reference,
      });
      setReview(null);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Box>
      <PageHeader
        title="Accounting & tax configuration"
        subtitle="Company-level treatments with effective dates, maker-checker approval and compliance review. Legal-applicability keys cannot be self-certified."
      />
      <ErrorBanner message={error} />
      {loading ? <CircularProgress /> : (
        <Card><CardContent>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Setting</TableCell><TableCell>Live value</TableCell>
                <TableCell>Effective from</TableCell><TableCell>Review</TableCell>
                <TableCell>Flags</TableCell><TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {defs.length === 0 && <EmptyRow colSpan={6} text="No configurable settings defined." />}
              {defs.map((d) => {
                const live = liveFor(d.key);
                const draft = draftFor(d.key);
                return (
                  <TableRow key={d.key}>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600}>{d.label}</Typography>
                      <Typography variant="caption" color="text.secondary">{d.description}</Typography>
                    </TableCell>
                    <TableCell>{live ? live.value : <em>default: {d.default_value}</em>}</TableCell>
                    <TableCell>{live?.effective_from ?? '—'}</TableCell>
                    <TableCell>
                      <Chip size="small"
                        label={live?.review_status ?? 'unreviewed'}
                        color={live?.review_status === 'reviewed' ? 'success' : 'warning'} />
                    </TableCell>
                    <TableCell>
                      {d.requires_legal_review && (
                        <Chip size="small" color="error" label="legal review required" />
                      )}
                    </TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end">
                        {draft && draft.status === 'draft' && (
                          <Button size="small" variant="outlined" onClick={() => approve(draft)}>Approve</Button>
                        )}
                        {live && live.review_status === 'unreviewed' && (
                          <Button size="small" onClick={() => setReview(live)}>Record review</Button>
                        )}
                        <Button size="small" onClick={() => {
                          setPropose(d);
                          setForm({ value: live?.value ?? d.default_value, effective_from: new Date().toISOString().slice(0, 10), rationale: '' });
                        }}>
                          {live ? 'Change…' : 'Set…'}
                        </Button>
                      </Stack>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </CardContent></Card>
      )}

      <Dialog open={!!propose} onClose={() => setPropose(null)} fullWidth maxWidth="sm">
        <DialogTitle>Propose: {propose?.label}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            {propose?.requires_legal_review && (
              <Typography variant="caption" color="error.main">
                This treatment's legal applicability must be confirmed by an accountant/compliance adviser before it is treated as approved.
              </Typography>
            )}
            <TextField select label="Value" value={form.value} fullWidth
              onChange={(e) => setForm({ ...form, value: e.target.value })}>
              {(propose?.allowed_values ?? []).map((v) => (
                <MenuItem key={v} value={v} disabled={!(propose?.implemented_values ?? []).includes(v)}>
                  {v}{(propose?.implemented_values ?? []).includes(v) ? '' : ' (planned — not yet implemented)'}
                </MenuItem>
              ))}
            </TextField>
            <TextField label="Effective from" type="date" InputLabelProps={{ shrink: true }}
              inputProps={{ min: new Date().toISOString().slice(0, 10) }}
              value={form.effective_from} fullWidth
              onChange={(e) => setForm({ ...form, effective_from: e.target.value })} />
            <TextField label="Rationale (required)" value={form.rationale} fullWidth multiline minRows={2}
              onChange={(e) => setForm({ ...form, rationale: e.target.value })} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setPropose(null)}>Cancel</Button>
          <Button variant="contained" disabled={busy || !form.value || !form.effective_from || form.rationale.trim().length < 10}
            onClick={submitPropose}>
            {busy ? 'Saving…' : 'Propose'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={!!review} onClose={() => setReview(null)} fullWidth maxWidth="sm">
        <DialogTitle>Record compliance review</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Reviewer name" value={reviewForm.reviewer_name} fullWidth
              onChange={(e) => setReviewForm({ ...reviewForm, reviewer_name: e.target.value })} />
            <TextField label="Reference (memo / advice)" value={reviewForm.review_reference} fullWidth
              onChange={(e) => setReviewForm({ ...reviewForm, review_reference: e.target.value })} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setReview(null)}>Cancel</Button>
          <Button variant="contained" disabled={busy || !reviewForm.reviewer_name || !reviewForm.review_reference}
            onClick={submitReview}>
            {busy ? 'Saving…' : 'Mark reviewed'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
