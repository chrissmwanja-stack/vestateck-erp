import { Alert, Button, CircularProgress, Paper, Stack, TextField, Typography } from '@mui/material';
import { fmtDateTime } from './utils';
import type { CompanyDetailState } from './useCompanyDetail';

export function NotesTab({ state }: { state: CompanyDetailState }) {
  const { notes, noteDraft, setNoteDraft, noteSaving, addNote } = state;

  return (
    <Stack spacing={2}>
      <Alert severity="info" icon={false}>
        Operator-only. Customers never see these notes — use them for account history, calls, commitments.
      </Alert>
      <Paper variant="outlined" sx={{ p: 2 }}>
        <TextField
          fullWidth
          multiline
          minRows={2}
          placeholder="e.g. Spoke with Jane — will pay INV-0231 by Friday; agreed to hold read-only until then."
          value={noteDraft}
          onChange={(e) => setNoteDraft(e.target.value)}
          disabled={noteSaving}
          inputProps={{ maxLength: 4000 }}
        />
        <Stack direction="row" justifyContent="flex-end" sx={{ mt: 1 }}>
          <Button variant="contained" size="small" onClick={addNote} disabled={noteSaving || noteDraft.trim().length === 0}>
            {noteSaving ? 'Adding…' : 'Add note'}
          </Button>
        </Stack>
      </Paper>
      {notes === null ? (
        <CircularProgress size={20} />
      ) : notes.length === 0 ? (
        <Typography variant="body2" color="text.secondary">
          No notes yet.
        </Typography>
      ) : (
        notes.map((n) => (
          <Paper key={n.id} variant="outlined" sx={{ p: 2 }}>
            <Typography variant="body2" sx={{ whiteSpace: 'pre-wrap' }}>
              {n.body}
            </Typography>
            <Typography variant="caption" color="text.secondary">
              {fmtDateTime(n.created_at)}
              {n.author_email && ` · ${n.author_email}`}
            </Typography>
          </Paper>
        ))
      )}
    </Stack>
  );
}