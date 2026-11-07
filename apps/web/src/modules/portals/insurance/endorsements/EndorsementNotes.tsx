import { useCallback, useEffect, useState } from 'react';
import {
  Button, Card, CardContent, CircularProgress, Stack, TextField, Typography,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../db';
import { ErrorBanner } from '../shared';

// Endorsement notes (correspondence depth): an append-only note trail per
// endorsement, visible to insurance members, written via RPC.

interface NoteRow {
  id: string;
  note: string;
  created_at: string;
  created_by: string | null;
}

export default function EndorsementNotes({ endorsementId }: { endorsementId: string }) {
  const [notes, setNotes] = useState<NoteRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setNotes(await rows<NoteRow>(
        table('ins_endorsement_notes').select('*').eq('endorsement_id', endorsementId)
          .order('created_at', { ascending: true })));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [endorsementId]);

  useEffect(() => { load(); }, [load]);

  const add = async () => {
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_log_endorsement_note', { p_endorsement_id: endorsementId, p_note: text });
      setText('');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card variant="outlined" sx={{ mt: 1 }}><CardContent>
      <Typography variant="subtitle2" gutterBottom>Notes</Typography>
      <ErrorBanner message={error} />
      {loading ? <CircularProgress size={18} /> : (
        notes.map((n) => (
          <Typography key={n.id} variant="body2" sx={{ mb: 0.5 }}>
            <strong>{n.created_at.slice(0, 16).replace('T', ' ')}</strong> — {n.note}
          </Typography>
        ))
      )}
      <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
        <TextField size="small" fullWidth placeholder="Add a note…" value={text}
          onChange={(e) => setText(e.target.value)} />
        <Button size="small" variant="outlined" disabled={busy || !text.trim()} onClick={add}>Add</Button>
      </Stack>
    </CardContent></Card>
  );
}
