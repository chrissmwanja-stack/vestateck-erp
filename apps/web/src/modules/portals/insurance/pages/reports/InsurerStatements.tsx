import { useCallback, useEffect, useState } from 'react';
import {
  Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions,
  DialogContent, DialogTitle, MenuItem, Stack, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useInsuranceAccess } from '../../access';
import { errorText, rows, rpc, table } from '../../db';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Insurer statement reconciliation (slice S1): record insurer statements,
// then reconcile line-by-line against our premium/commission/claims records.

interface StatementRow {
  id: string;
  statement_ref: string;
  period_from: string;
  period_to: string;
  status: 'received' | 'reconciled' | 'disputed';
  notes: string | null;
  insurer_id: string;
  ins_insurers?: { name: string } | null;
}

interface InsurerRow { id: string; name: string; }

interface ReconRow {
  line_id: string; policy_id: string; policy_no: string; field: string;
  insurer_amount: number; our_amount: number; match: boolean;
}

export default function InsurerStatements() {
  const navigate = useNavigate();
  const { canManage } = useInsuranceAccess();
  const [stmts, setStmts] = useState<StatementRow[]>([]);
  const [insurers, setInsurers] = useState<InsurerRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState({ insurer_id: '', ref: '', from: '', to: '', lines: '' });
  const [reconId, setReconId] = useState<string | null>(null);
  const [recon, setRecon] = useState<ReconRow[]>([]);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [s, ins] = await Promise.all([
        rows<StatementRow>(
          table('ins_insurer_statements')
            .select('*, ins_insurers(name)')
            .order('created_at', { ascending: false })),
        rows<InsurerRow>(table('ins_insurers').select('id, name').order('name')),
      ]);
      setStmts(s);
      setInsurers(ins);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      const lines = JSON.parse(form.lines);
      await rpc('ins_record_insurer_statement', {
        p_insurer_id: form.insurer_id, p_statement_ref: form.ref,
        p_period_from: form.from, p_period_to: form.to, p_lines: lines,
      });
      setOpen(false);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const showRecon = async (id: string) => {
    setReconId(id);
    setError(null);
    try {
      setRecon(await rpc<ReconRow[]>('ins_insurer_statement_reconciliation', { p_statement_id: id }));
    } catch (e) {
      setError(errorText(e));
    }
  };

  const decide = async (id: string, status: 'reconciled' | 'disputed') => {
    setError(null);
    try {
      await rpc('ins_decide_insurer_statement', { p_statement_id: id, p_status: status });
      await load();
    } catch (e) {
      setError(errorText(e));
    }
  };

  return (
    <Box>
      <PageHeader
        title="Insurer statements"
        subtitle="Record insurer statements and reconcile them against our premium, commission and claims records."
        actions={
          canManage && (
            <Button variant="contained" onClick={() => setOpen(true)}>Record statement</Button>
          )
        }
      />
      <ErrorBanner message={error} />
      {loading ? <CircularProgress /> : (
        <Card><CardContent>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Ref</TableCell><TableCell>Insurer</TableCell>
                <TableCell>Period</TableCell><TableCell>Status</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {stmts.length === 0 && <EmptyRow colSpan={5} text="No statements recorded yet." />}
              {stmts.map((s) => (
                <TableRow key={s.id}>
                  <TableCell>{s.statement_ref}</TableCell>
                  <TableCell>{s.ins_insurers?.name ?? '—'}</TableCell>
                  <TableCell>{s.period_from} → {s.period_to}</TableCell>
                  <TableCell>
                    <Chip size="small" label={s.status}
                      color={s.status === 'reconciled' ? 'success' : s.status === 'disputed' ? 'error' : 'default'} />
                  </TableCell>
                  <TableCell align="right">
                    <Stack direction="row" spacing={1} justifyContent="flex-end">
                      <Button size="small" onClick={() => showRecon(s.id)}>Reconcile</Button>
                      {canManage && s.status === 'received' && (
                        <>
                          <Button size="small" color="success" onClick={() => decide(s.id, 'reconciled')}>Mark reconciled</Button>
                          <Button size="small" color="error" onClick={() => decide(s.id, 'disputed')}>Dispute</Button>
                        </>
                      )}
                    </Stack>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent></Card>
      )}

      {reconId && (
        <Card sx={{ mt: 2 }}><CardContent>
          <Typography variant="subtitle1" gutterBottom>Reconciliation</Typography>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Policy</TableCell><TableCell>Field</TableCell>
                <TableCell align="right">Insurer</TableCell><TableCell align="right">Our records</TableCell>
                <TableCell>Result</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {recon.length === 0 && <EmptyRow colSpan={5} text="No lines." />}
              {recon.map((r) => (
                <TableRow key={r.line_id + r.field}>
                  <TableCell>
                    <Button size="small" onClick={() => navigate(`/insurance/policies/${r.policy_id}`)}>{r.policy_no}</Button>
                  </TableCell>
                  <TableCell>{r.field}</TableCell>
                  <TableCell align="right">{r.insurer_amount.toLocaleString()}</TableCell>
                  <TableCell align="right">{r.our_amount.toLocaleString()}</TableCell>
                  <TableCell>
                    <Chip size="small" label={r.match ? 'match' : 'MISMATCH'} color={r.match ? 'success' : 'error'} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent></Card>
      )}

      <Dialog open={open} onClose={() => setOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>Record insurer statement</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="Insurer" value={form.insurer_id} fullWidth
              onChange={(e) => setForm({ ...form, insurer_id: e.target.value })}>
              {insurers.map((i) => <MenuItem key={i.id} value={i.id}>{i.name}</MenuItem>)}
            </TextField>
            <TextField label="Statement ref (insurer's own)" value={form.ref} fullWidth
              onChange={(e) => setForm({ ...form, ref: e.target.value })} />
            <Stack direction="row" spacing={2}>
              <TextField label="Period from" type="date" InputLabelProps={{ shrink: true }} value={form.from} fullWidth
                onChange={(e) => setForm({ ...form, from: e.target.value })} />
              <TextField label="Period to" type="date" InputLabelProps={{ shrink: true }} value={form.to} fullWidth
                onChange={(e) => setForm({ ...form, to: e.target.value })} />
            </Stack>
            <TextField label='Lines (JSON array: [{"policy_id":"…","premium":0,"commission":0,"claims_paid":0}])'
              value={form.lines} fullWidth multiline minRows={4}
              onChange={(e) => setForm({ ...form, lines: e.target.value })} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" disabled={busy || !form.insurer_id || !form.ref || !form.from || !form.to || !form.lines}
            onClick={save}>
            {busy ? 'Saving…' : 'Save statement'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
