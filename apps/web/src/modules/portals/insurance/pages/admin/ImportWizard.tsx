import { useCallback, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Stack, Step,
  StepLabel, Stepper, Table, TableBody, TableCell, TableHead, TableRow,
  TextField,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { parseCsv, type ParsedCsv } from '../../../../../lib/csvParser';
import { parseXlsx } from '../../../../../lib/xlsxParser';
import { useInsuranceAccess } from '../../access';
import { errorText, rpc } from '../../db';
import { ErrorBanner, PageHeader } from '../../shared';

// In-force portfolio import wizard (IN_FORCE_IMPORT.md build order step 4):
// upload -> stage -> validate -> commit -> opening position -> reconcile.

interface BatchRow { id: string; label: string; status: string; cut_over_date: string; error_count: number; }
interface ReconRow { currency: string; measure: string; imported_amount: number; control_amount: number; match: boolean; }

const STEPS = ['Upload & stage', 'Validate', 'Commit policies', 'Opening position', 'Reconcile'];

export default function ImportWizard() {
  const navigate = useNavigate();
  const { canManage } = useInsuranceAccess();
  const [active, setActive] = useState(0);
  const [label, setLabel] = useState('');
  const [cutOver, setCutOver] = useState('');
  const [batch, setBatch] = useState<BatchRow | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [recon, setRecon] = useState<ReconRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const run = useCallback(async (fn: () => Promise<unknown>, next: number) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      setActive(next);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }, []);

  const upload = async () => {
    if (!file || !label || !cutOver) return;
    await run(async () => {
      const parsed = file.name.endsWith('.xlsx') ? await parseXlsx(file) : parseCsv(await file.text());
      // A multi-sheet workbook parser may attach per-sheet rows; a CSV or a
      // first-sheet-only parse has just `rows` (the policies sheet).
      const sheets = (parsed as ParsedCsv & { sheets?: Record<string, Record<string, string>[]> }).sheets;
      const b = await rpc<BatchRow>('ins_import_create_batch', { p_label: label, p_cut_over_date: cutOver });
      setBatch(b);
      for (const sheet of ['policies', 'receipts', 'remittances', 'shares', 'control_totals']) {
        const rows = sheets?.[sheet] ?? (sheet === 'policies' ? parsed.rows : []);
        if (!rows.length) continue;
        await rpc('ins_import_stage_rows', {
          p_batch_id: b.id, p_sheet: sheet,
          // ins_import_stage_rows takes the flat row objects and numbers the
          // lines itself; wrapping them as {line, raw} buried every field one
          // level down, so validation saw no legacy_policy_no etc.
          p_rows: rows,
        });
      }
      setNotice(`Staged ${parsed.rows.length}+ rows into batch ${b.id.slice(0, 8)}.`);
    }, 1);
  };

  const validate = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    await rpc('ins_import_validate_batch', { p_batch_id: batch.id });
    setBatch({ ...batch, status: 'validated', error_count: 0 });
    setNotice('Validation passed.');
  }, 2);

  const commit = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    await rpc('ins_import_commit_policies', { p_batch_id: batch.id });
    setBatch({ ...batch, status: 'committed' });
    setNotice('Policies committed (version 1, no bind journal).');
  }, 3);

  const postOpening = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    const r = await rpc<{ already_posted?: boolean; journal_entry_id?: string }>(
      'ins_import_post_opening_position', { p_batch_id: batch.id });
    setNotice(r.already_posted ? 'Opening position already posted.' : `Opening journal posted: ${r.journal_entry_id?.slice(0, 8)}`);
  }, 4);

  const reconcile = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    setRecon(await rpc<ReconRow[]>('ins_import_reconciliation', { p_batch_id: batch.id }));
  }, 5);

  return (
    <Box>
      <PageHeader
        title="In-force portfolio import"
        subtitle="Stage, validate, commit and reconcile a legacy book at cut-over. Migrated policies carry accounting-policy version 1 and post no bind journal."
      />
      <ErrorBanner message={error} />
      {notice && <Alert severity="success" sx={{ mb: 2 }} onClose={() => setNotice(null)}>{notice}</Alert>}
      <Stepper activeStep={active} sx={{ mb: 3 }}>
        {STEPS.map((s) => <Step key={s}><StepLabel>{s}</StepLabel></Step>)}
      </Stepper>

      <Card><CardContent>
        {active === 0 && (
          <Stack spacing={2}>
            <TextField label="Batch label" value={label} onChange={(e) => setLabel(e.target.value)} fullWidth />
            <TextField label="Cut-over date" type="date" InputLabelProps={{ shrink: true }}
              inputProps={{ max: new Date().toISOString().slice(0, 10) }}
              value={cutOver} onChange={(e) => setCutOver(e.target.value)} fullWidth />
            <Button variant="outlined" component="label">
              {file ? file.name : 'Choose workbook / CSV…'}
              <input hidden type="file" accept=".xlsx,.csv"
                onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
            </Button>
            <Button variant="contained" disabled={busy || !file || !label || !cutOver || !canManage} onClick={upload}>
              {busy ? 'Staging…' : 'Stage rows'}
            </Button>
          </Stack>
        )}
        {active === 1 && <Button variant="contained" disabled={busy || !batch || !canManage} onClick={validate}>Run validation</Button>}
        {active === 2 && <Button variant="contained" disabled={busy || !batch || !canManage} onClick={commit}>Commit policies</Button>}
        {active === 3 && <Button variant="contained" disabled={busy || !batch || !canManage} onClick={postOpening}>Post opening position</Button>}
        {/* >= 4: reconcile() advances to step 5 (all steps complete); the result table must stay on screen. */}
        {active >= 4 && (
          <Stack spacing={2}>
            <Button variant="contained" disabled={busy || !batch} onClick={reconcile}>Run reconciliation</Button>
            <Table size="small">
              <TableHead>
                <TableRow><TableCell>Currency</TableCell><TableCell>Measure</TableCell>
                  <TableCell align="right">Imported</TableCell><TableCell align="right">Control</TableCell><TableCell>Match</TableCell></TableRow>
              </TableHead>
              <TableBody>
                {recon.map((r) => (
                  <TableRow key={r.currency + r.measure}>
                    <TableCell>{r.currency}</TableCell><TableCell>{r.measure}</TableCell>
                    <TableCell align="right">{r.imported_amount.toLocaleString()}</TableCell>
                    <TableCell align="right">{r.control_amount.toLocaleString()}</TableCell>
                    <TableCell><Chip size="small" label={r.match ? 'match' : 'DIFF'} color={r.match ? 'success' : 'error'} /></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            <Button onClick={() => navigate('/insurance/reports')}>Back to reports</Button>
          </Stack>
        )}
        {busy && <CircularProgress size={20} sx={{ mt: 2 }} />}
      </CardContent></Card>
    </Box>
  );
}