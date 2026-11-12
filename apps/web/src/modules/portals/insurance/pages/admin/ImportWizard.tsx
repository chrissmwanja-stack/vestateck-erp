import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Stack, Step,
  StepLabel, Stepper, Table, TableBody, TableCell, TableHead, TableRow,
  TextField,
} from '@mui/material';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { parseCsv } from '../../../../../lib/csvParser';
import { parseXlsx, type ParsedWorkbook } from '../../../../../lib/xlsxParser';
import { useInsuranceAccess } from '../../access';
import { errorText, rows, rpc, table } from '../../db';
import { ErrorBanner, PageHeader } from '../../shared';

// In-force portfolio import wizard (IN_FORCE_IMPORT.md build order step 4):
// upload -> stage -> validate -> commit -> opening position -> reconcile.

interface BatchRow { id: string; label: string; status: string; cut_over_date: string; error_count: number; }
interface RowProblem { sheet: string; line: number; errors: { code: string; message: string }[]; }
// control_amount / match are null when the batch's control_totals sheet did
// not record that measure: "not recorded" is not the same as "differs".
interface ReconRow {
  currency: string; measure: string; imported_amount: number;
  control_amount: number | null; match: boolean | null;
}

// The post-posting report (ins_import_opening_report): what the opening journal
// posted, what the sub-ledger holds, and what the legacy ledger said. Nothing
// here gates anything; it is for a reviewer to read and explain.
interface OpeningRow {
  currency: string; measure: string; posted_amount: number;
  open_item_amount: number | null; control_amount: number | null;
  match: boolean | null; subledger_match: boolean | null;
}

const STEPS = ['Upload & stage', 'Validate', 'Commit policies', 'Opening position', 'Reconcile'];

// One table, shown twice: on the commit step (where the gate fires) and on the
// reconcile step. Three states per row, because they are three different
// facts: agrees, disagrees, or was never recorded.
function ReconTable({ rows }: { rows: ReconRow[] }) {
  return (
    <Table size="small">
      <TableHead>
        <TableRow><TableCell>Currency</TableCell><TableCell>Measure</TableCell>
          <TableCell align="right">Imported</TableCell><TableCell align="right">Control</TableCell><TableCell>Match</TableCell></TableRow>
      </TableHead>
      <TableBody>
        {rows.map((r) => (
          <TableRow key={r.currency + r.measure}>
            <TableCell>{r.currency}</TableCell><TableCell>{r.measure}</TableCell>
            <TableCell align="right">{r.imported_amount.toLocaleString()}</TableCell>
            <TableCell align="right">{r.control_amount === null ? '—' : r.control_amount.toLocaleString()}</TableCell>
            <TableCell>
              {r.match === null
                ? <Chip size="small" label="not recorded" variant="outlined" />
                : <Chip size="small" label={r.match ? 'match' : 'DIFF'} color={r.match ? 'success' : 'error'} />}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

// null means "nothing to compare" (not recorded, or no sub-ledger for that
// measure), which is a different fact from "differs".
function OpeningReportTable({ rows }: { rows: OpeningRow[] }) {
  return (
    <Table size="small">
      <TableHead>
        <TableRow>
          <TableCell>Currency</TableCell><TableCell>Measure</TableCell>
          <TableCell align="right">Posted</TableCell><TableCell align="right">Open items</TableCell>
          <TableCell align="right">Legacy</TableCell>
          <TableCell>Posted vs legacy</TableCell><TableCell>Posted vs open items</TableCell>
        </TableRow>
      </TableHead>
      <TableBody>
        {rows.map((r) => (
          <TableRow key={r.currency + r.measure}>
            <TableCell>{r.currency}</TableCell><TableCell>{r.measure}</TableCell>
            <TableCell align="right">{r.posted_amount.toLocaleString()}</TableCell>
            <TableCell align="right">{r.open_item_amount === null ? '—' : r.open_item_amount.toLocaleString()}</TableCell>
            <TableCell align="right">{r.control_amount === null ? '—' : r.control_amount.toLocaleString()}</TableCell>
            <TableCell>
              {r.match === null
                ? <Chip size="small" label="not recorded" variant="outlined" />
                : <Chip size="small" label={r.match ? 'match' : 'DIFF'} color={r.match ? 'success' : 'error'} />}
            </TableCell>
            <TableCell>
              {r.subledger_match === null
                ? <Chip size="small" label="n/a" variant="outlined" />
                : <Chip size="small" label={r.subledger_match ? 'match' : 'DIFF'} color={r.subledger_match ? 'success' : 'error'} />}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

export default function ImportWizard() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const { canManage } = useInsuranceAccess();
  const [active, setActive] = useState(0);
  const [label, setLabel] = useState('');
  const [cutOver, setCutOver] = useState('');
  const [batch, setBatch] = useState<BatchRow | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [recon, setRecon] = useState<ReconRow[]>([]);
  const [opening, setOpening] = useState<OpeningRow[]>([]);
  const [reason, setReason] = useState('');
  const [problems, setProblems] = useState<RowProblem[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // The person who approves a difference is, by rule, someone other than the
  // uploader (INS_IMPORT_CONTROL_OVERRIDE_SELF), and they are on another
  // machine with no state from this tab. The batch id therefore goes in the
  // URL when a batch is created, and opening that URL puts the wizard back on
  // the step the batch's status implies.
  const resumeId = params.get('batch');
  useEffect(() => {
    if (!resumeId || batch) return;
    let cancelled = false;
    setBusy(true);
    setError(null);
    (async () => {
      try {
        const found = await rows<BatchRow>(table('ins_import_batches')
          .select('id,label,status,cut_over_date,error_count')
          .eq('id', resumeId).limit(1));
        const b = found[0];
        if (cancelled) return;
        if (!b) throw new Error('That batch does not exist in this company.');
        setBatch(b);
        setLabel(b.label);
        setCutOver(b.cut_over_date);
        setActive(b.status === 'committed' ? 3 : b.status === 'validated' ? 2 : 1);
        setNotice(`Opened batch ${b.id.slice(0, 8)} (${b.status}).`);
      } catch (e) {
        if (!cancelled) setError(errorText(e));
      } finally {
        if (!cancelled) setBusy(false);
      }
    })();
    return () => { cancelled = true; };
  }, [resumeId, batch]);

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
      const parsed = file.name.endsWith('.xlsx')
        ? await parseXlsx(file)
        : parseCsv(await file.text());
      // The canonical import is one workbook with a sheet per file. A CSV (or
      // a first-sheet-only parse) has just `rows`, which is the policies sheet.
      const sheets = 'sheets' in parsed ? (parsed as ParsedWorkbook).sheets : undefined;
      const b = await rpc<BatchRow>('ins_import_create_batch', { p_label: label, p_cut_over_date: cutOver });
      setBatch(b);
      setParams({ batch: b.id }, { replace: true });
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
    setProblems([]);
    const report = await rpc<{ error_count: number }>('ins_import_validate_batch', { p_batch_id: batch.id });
    if (report.error_count > 0) {
      // The RPC records row errors and returns normally, so a refusal never
      // happens here: stay on this step and show which rows failed.
      setProblems(await rows<RowProblem>(
        table('ins_import_rows').select('sheet,line,errors')
          .eq('batch_id', batch.id).eq('status', 'error')
          .order('sheet').order('line').limit(25)));
      setBatch({ ...batch, status: 'staged', error_count: report.error_count });
      throw new Error(`${report.error_count} row(s) failed validation. Fix the file and stage it again.`);
    }
    setBatch({ ...batch, status: 'validated', error_count: 0 });
    setNotice('Validation passed.');
  }, 2);

  const loadRecon = async (batchId: string) => {
    const r = await rpc<ReconRow[]>('ins_import_reconciliation', { p_batch_id: batchId });
    setRecon(r);
    return r;
  };

  // Choosing a reason is the reviewer's job, not the uploader's; the server
  // refuses the uploader (INS_IMPORT_CONTROL_OVERRIDE_SELF), so the UI only
  // has to ask for the explanation and show what comes back.
  const approve = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    const r = await rpc<{ approved_differences: { currency: string; measure: string }[] }>(
      'ins_import_override_control_totals', { p_batch_id: batch.id, p_reason: reason });
    setNotice(`Approved ${r.approved_differences.length} difference(s). The commit can go ahead.`);
    setReason('');
  }, 2);

  const commit = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    await rpc('ins_import_commit_policies', { p_batch_id: batch.id });
    setBatch({ ...batch, status: 'committed' });
    setNotice('Policies committed (version 1, with their payment history).');
  }, 3);

  const checkTotals = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    const r = await loadRecon(batch.id);
    const diff = r.filter((x) => x.match === false).length;
    const missing = r.filter((x) => x.match === null).length;
    setNotice(diff === 0
      ? `Control totals agree${missing ? ` (${missing} measure(s) not recorded)` : ''}.`
      : `${diff} measure(s) disagree with the recorded control totals.`);
  }, 2);

  const postOpening = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    const r = await rpc<{ already_posted?: boolean; journal_entry_id?: string }>(
      'ins_import_post_opening_position', { p_batch_id: batch.id });
    setNotice(r.already_posted ? 'Opening position already posted.' : `Opening journal posted: ${r.journal_entry_id?.slice(0, 8)}`);
  }, 4);

  const reconcile = () => run(async () => {
    if (!batch) throw new Error('No batch selected');
    await loadRecon(batch.id);
    // Receivables, payables and unearned commission only exist once the
    // opening position is posted, so they are reported here and do not gate.
    setOpening((await rpc<OpeningRow[] | null>('ins_import_opening_report', { p_batch_id: batch.id })) ?? []);
  }, 5);

  const differences = recon.filter((r) => r.match === false);
  const openingDiffs = opening.filter((r) => r.match === false || r.subledger_match === false);

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
        {active === 1 && (
          <Stack spacing={2}>
            <Button variant="contained" disabled={busy || !batch || !canManage} onClick={validate}>Run validation</Button>
            {problems.length > 0 && (
              <>
                <Table size="small">
                  <TableHead>
                    <TableRow><TableCell>Sheet</TableCell><TableCell>Line</TableCell><TableCell>Problem</TableCell></TableRow>
                  </TableHead>
                  <TableBody>
                    {problems.map((p) => (
                      <TableRow key={p.sheet + p.line}>
                        <TableCell>{p.sheet}</TableCell><TableCell>{p.line}</TableCell>
                        <TableCell>{p.errors.map((e) => e.message).join('; ')}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                {(batch?.error_count ?? 0) > problems.length && (
                  <Alert severity="info">Showing the first {problems.length} of {batch?.error_count} failing rows.</Alert>
                )}
                <Button onClick={() => { setProblems([]); setBatch(null); setError(null); setActive(0); }}>
                  Back to upload
                </Button>
              </>
            )}
          </Stack>
        )}
        {active === 2 && (
          <Stack spacing={2}>
            <Button variant="outlined" disabled={busy || !batch} onClick={checkTotals}>
              Compare with control totals
            </Button>
            {recon.length > 0 && <ReconTable rows={recon} />}
            {differences.length > 0 && (
              <Alert severity="warning">
                The recorded control totals disagree with the staged book on{' '}
                {differences.length} measure(s). The commit is refused until either the
                totals or the book are corrected, or someone other than the uploader
                approves the difference.
              </Alert>
            )}
            {differences.length > 0 && (
              <Stack spacing={1}>
                <TextField
                  label="Why do the totals differ?"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  helperText="At least 10 characters. Recorded against the batch with your name."
                  fullWidth
                />
                <Button
                  variant="outlined"
                  disabled={busy || !canManage || reason.trim().length < 10}
                  onClick={approve}
                >
                  Approve difference
                </Button>
              </Stack>
            )}
            <Button variant="contained" disabled={busy || !batch || !canManage} onClick={commit}>
              Commit policies
            </Button>
          </Stack>
        )}
        {active === 3 && <Button variant="contained" disabled={busy || !batch || !canManage} onClick={postOpening}>Post opening position</Button>}
        {/* >= 4: reconcile() advances to step 5 (all steps complete); the result table must stay on screen. */}
        {active >= 4 && (
          <Stack spacing={2}>
            <Button variant="contained" disabled={busy || !batch} onClick={reconcile}>Run reconciliation</Button>
            <ReconTable rows={recon} />
            {opening.length > 0 && (
              <>
                <Alert severity={openingDiffs.length === 0 ? 'success' : 'warning'}>
                  {openingDiffs.length === 0
                    ? 'The opening journal, the open items and the legacy ledger agree on receivables, payables and unearned commission.'
                    : `${openingDiffs.length} line(s) differ. These measures are reported after posting and do not block anything: ` +
                      'explain each difference to whoever signs off the migration. A legacy unearned-commission figure can differ by design, ' +
                      'because commission is recognised when the insurer is settled, not over time.'}
                </Alert>
                <OpeningReportTable rows={opening} />
              </>
            )}
            <Button onClick={() => navigate('/insurance/reports')}>Back to reports</Button>
          </Stack>
        )}
        {busy && <CircularProgress size={20} sx={{ mt: 2 }} />}
      </CardContent></Card>
    </Box>
  );
}