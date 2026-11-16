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

// Paste or upload a bank statement CSV and send it to import_bank_statement_lines.
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
  onImported: (count: number) => void;
}) {
  const [importText, setImportText] = useState('');
  const [importing, setImporting] = useState(false);
  const [importError, setImportError] = useState<string | null>(null);

  const close = () => {
    setImportError(null);
    onClose();
  };

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
    const payload = rows.map((r) => ({
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
    const { error: err } = await supabase.rpc('import_bank_statement_lines', {
      p_bank_account: bankAccount.trim(),
      p_lines: payload,
    });
    setImporting(false);
    if (err) {
      setImportError(err.message ?? 'Import failed.');
      return;
    }
    setImportText('');
    onImported(payload.length);
  }

  function handleFilePick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => setImportText(String(reader.result ?? ''));
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
            onChange={(e) => setImportText(e.target.value)}
            placeholder={'statement_date,description,reference,amount\n2026-09-06,SALARY PYMT,REF001,-1674500'}
          />
          {importError && <Alert severity="error">{importError}</Alert>}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={close} disabled={importing}>Cancel</Button>
        <Button variant="contained" onClick={handleImport} disabled={importing}>
          {importing ? 'Importing…' : 'Import'}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
