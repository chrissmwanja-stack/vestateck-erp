import { useCallback, useEffect, useState } from 'react';
import {
  Button, Card, CardContent, Chip, CircularProgress, MenuItem, Stack,
  Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../../db';
import { EmptyRow, ErrorBanner } from '../../shared';

// Claims correspondence log (slice: correspondence depth).

interface CorrRow {
  id: string;
  direction: 'in' | 'out';
  channel: string;
  subject: string;
  body: string | null;
  reference: string | null;
  occurred_at: string;
}

export default function ClaimCorrespondence({ claimId }: { claimId: string }) {
  const [items, setItems] = useState<CorrRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({ direction: 'out', channel: 'email', subject: '', body: '', reference: '' });
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems(await rows<CorrRow>(
        table('ins_claim_correspondence').select('*').eq('claim_id', claimId)
          .order('occurred_at', { ascending: false })));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [claimId]);

  useEffect(() => { load(); }, [load]);

  const send = async () => {
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_log_claim_correspondence', {
        p_claim_id: claimId, p_direction: form.direction, p_channel: form.channel,
        p_subject: form.subject, p_body: form.body || null, p_reference: form.reference || null,
      });
      setForm({ direction: 'out', channel: 'email', subject: '', body: '', reference: '' });
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card sx={{ mt: 2 }}><CardContent>
      <Typography variant="subtitle1" gutterBottom>Correspondence</Typography>
      <ErrorBanner message={error} />
      {loading ? <CircularProgress size={20} /> : (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>When</TableCell><TableCell>Dir</TableCell><TableCell>Channel</TableCell>
              <TableCell>Subject</TableCell><TableCell>Reference</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {items.length === 0 && <EmptyRow colSpan={5} text="No correspondence logged." />}
            {items.map((c) => (
              <TableRow key={c.id}>
                <TableCell>{c.occurred_at.slice(0, 16).replace('T', ' ')}</TableCell>
                <TableCell><Chip size="small" label={c.direction === 'in' ? 'in' : 'out'}
                  color={c.direction === 'in' ? 'info' : 'default'} /></TableCell>
                <TableCell>{c.channel}</TableCell>
                <TableCell>{c.subject}{c.body ? <Typography variant="caption" display="block">{c.body}</Typography> : null}</TableCell>
                <TableCell>{c.reference ?? '—'}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
      <Stack direction="row" spacing={1} sx={{ mt: 2 }} flexWrap="wrap" useFlexGap>
        <TextField select size="small" label="Dir" value={form.direction} sx={{ minWidth: 80 }}
          onChange={(e) => setForm({ ...form, direction: e.target.value })}>
          <MenuItem value="out">Out</MenuItem><MenuItem value="in">In</MenuItem>
        </TextField>
        <TextField select size="small" label="Channel" value={form.channel} sx={{ minWidth: 100 }}
          onChange={(e) => setForm({ ...form, channel: e.target.value })}>
          <MenuItem value="email">Email</MenuItem><MenuItem value="letter">Letter</MenuItem>
          <MenuItem value="portal">Portal</MenuItem><MenuItem value="phone">Phone</MenuItem>
        </TextField>
        <TextField size="small" label="Subject" value={form.subject} sx={{ minWidth: 220 }}
          onChange={(e) => setForm({ ...form, subject: e.target.value })} />
        <TextField size="small" label="Reference" value={form.reference} sx={{ minWidth: 140 }}
          onChange={(e) => setForm({ ...form, reference: e.target.value })} />
        <TextField size="small" label="Body" value={form.body} sx={{ minWidth: 260 }}
          onChange={(e) => setForm({ ...form, body: e.target.value })} />
        <Button variant="outlined" size="small" disabled={busy || !form.subject.trim()} onClick={send}>Log</Button>
      </Stack>
    </CardContent></Card>
  );
}
