import { useState } from 'react';
import {
  Alert,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import { UploadFile as UploadFileIcon } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';
import { parseCsv } from './utils';

// A type alias, not an interface: only an alias is assignable to the generated
// Json type the RPC takes.
type StatementLine = {
  statement_date: string;
  description: string | null;
  reference: string | null;
  amount: number;
  currency: string | undefined;
};

// Paste or upload a bank statement CSV and import it as one batch.
//
// Before anything is written, preview_bank_statement_import says which lines
// are already on file for this account. If any are, the user chooses: skip
// those and import the rest, import everything anyway (a real statement can
// repeat a line, and an overlapping file can be deliberate), or go back and
// fix the file. The server does the matching; this component only asks.
//
// The pasted text survives Cancel (it is only cleared after a successful
// import); the error message does not outlive the dialog.
export function ImportStatementDialog({
  open,
  bankAccount,
  onClose,
  onImported,
}: {
  open: boolean;
  bankAccount: string;
  onClose: () => void;
  onImported: (count: number, skipped?: number) => void;
}) {
  const [importText, setImportText] = useState('');
  const [importing, setImporting] = useState(false);
  const [importError, setImportError] = useState<string | null>(null);
  // Set when the preview found lines that are already on file; waits for the
  // user's choice.
  const [pending, setPending] = useState<{ payload: StatementLine[]; flagged: number } | null>(null);

  const close = () => {
    setImportError(null);
    setPending(null);
    onClose();
  };

  async function runImport(payload: StatementLine[], skipDuplicates: boolean) {
    setImporting(true);
    setImportError(null);
    const { data, error: err } = await supabase.rpc('import_bank_statement_batch', {
      p_bank_account: bankAccount.trim(),
      p_lines: payload,
      p_skip_duplicates: skipDuplicates,
    });
    setImporting(false);
    if (err) {
      setImportError(err.message ?? 'Import failed.');
      return;
    }
    const result = (data ?? {}) as { imported?: number; skipped?: number };
    setPending(null);
    setImportText('');
    onImported(result.imported ?? payload.length, result.skipped ?? 0);
  }

  async function handleImport() {
    if (!bankAccount.trim()) {
      setImportError('Enter a bank account above before importing.');
      return;
    }
    const rows = parseCsv(importText);
    if (rows.length === 0) {
      setImportError('Paste CSV with a header row: statement_date, description, reference, amount[, currency]');
      return;
    }
    const payload: StatementLine[] = rows.map((r) => ({
      statement_date: r.statement_date || r.date,
      description: r.description || null,
      reference: r.reference || null,
      amount: Number(r.amount),
      currency: r.currency || undefined,
    }));
    if (payload.some((p) => !p.statement_date || Number.isNaN(p.amount))) {
      setImportError('Every row needs a statement_date and a numeric amount.');
      return;
    }

    setImporting(true);
    setImportError(null);
    const { data: preview, error: previewErr } = await supabase.rpc('preview_bank_statement_import', {
      p_bank_account: bankAccount.trim(),
      p_lines: payload,
    });
    setImporting(false);
    if (previewErr) {
      setImportError(previewErr.message ?? 'Could not check the file for lines that are already imported.');
      return;
    }
    const flagged = (preview ?? []).filter((row) => row.already_imported).length;
    if (flagged > 0) {
      setPending({ payload, flagged });
      return;
    }
    await runImport(payload, false);
  }

  function handleFilePick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      setImportText(String(reader.result ?? ''));
      setPending(null);
    };
    reader.readAsText(file);
  }

  return (
    <Dialog open={open} onClose={() => !importing && close()} maxWidth="sm" fullWidth>
      <DialogTitle>Import Bank Statement — {bankAccount || '(enter a bank account first)'}</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ mt: 1 }}>
          <Typography variant="body2" color="text.secondary">
            Upload a CSV or paste rows below. Expected columns: <code>statement_date, description, reference, amount</code>{' '}
            (positive = money in, negative = money out). <code>currency</code> is optional and defaults to UGX.
          </Typography>
          <Button component="label" variant="outlined" startIcon={<UploadFileIcon />}>
            Choose CSV File
            <input type="file" accept=".csv,text/csv" hidden onChange={handleFilePick} />
          </Button>
          <TextField
            label="CSV contents"
            multiline
            minRows={8}
            fullWidth
            value={importText}
            onChange={(e) => {
              setImportText(e.target.value);
              setPending(null);
            }}
            placeholder={'statement_date,description,reference,amount\n2026-09-06,SALARY PYMT,REF001,-1674500'}
          />
          {importError && <Alert severity="error">{importError}</Alert>}
          {pending && (
            <Alert severity="warning">
              {pending.flagged === pending.payload.length
                ? `All ${pending.payload.length} line${pending.payload.length === 1 ? ' is' : 's are'} already on file for this account. This looks like a statement that was imported before.`
                : `${pending.flagged} of ${pending.payload.length} lines are already on file for this account. This file may overlap a statement you imported before.`}
            </Alert>
          )}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={close} disabled={importing}>Cancel</Button>
        {pending ? (
          <>
            <Button onClick={() => setPending(null)} disabled={importing}>Back to file</Button>
            <Button onClick={() => runImport(pending.payload, false)} disabled={importing}>
              Import all anyway
            </Button>
            {pending.flagged < pending.payload.length && (
              <Button variant="contained" onClick={() => runImport(pending.payload, true)} disabled={importing}>
                {importing ? 'Importing…' : 'Skip duplicates and import the rest'}
              </Button>
            )}
          </>
        ) : (
          <Button variant="contained" onClick={handleImport} disabled={importing}>
            {importing ? 'Checking…' : 'Import'}
          </Button>
        )}
      </DialogActions>
    </Dialog>
  );
}
