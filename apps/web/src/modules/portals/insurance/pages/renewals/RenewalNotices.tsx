import { useCallback, useEffect, useState } from 'react';
import {
  Box, Button, Card, CardContent, Chip, CircularProgress, MenuItem, Stack, Table,
  TableBody, TableCell, TableHead, TableRow, TextField,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useInsuranceAccess } from '../../access';
import { errorText, rows, rpc, table } from '../../db';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Renewal notices (slice B1): bulk-generate draft notices for policies in
// the 120-day renewal window, then mark them sent per row (manager tier).
// The server RPCs are the enforcement point; the table is read-only here.

interface NoticeRow {
  id: string;
  notice_no: string;
  status: 'draft' | 'sent';
  channel: string;
  sent_at: string | null;
  policy_id: string;
  created_at: string;
}

interface NoticePolicyRow {
  id: string;
  policy_no: string;
  expiry_date: string;
  currency: string;
  gross_premium: number;
  ins_clients?: { bd_clients?: { name: string } | null } | null;
}

export default function RenewalNotices() {
  const navigate = useNavigate();
  const { canManage } = useInsuranceAccess();
  const [notices, setNotices] = useState<NoticeRow[]>([]);
  const [policies, setPolicies] = useState<Map<string, NoticePolicyRow>>(new Map());
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [channel, setChannel] = useState('email');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const n = await rows<NoticeRow>(
        table('ins_renewal_notices').select('*').order('created_at', { ascending: false }),
      );
      setNotices(n);
      const ids = Array.from(new Set(n.map((x) => x.policy_id)));
      const map = new Map<string, NoticePolicyRow>();
      if (ids.length) {
        const ps = await rows<NoticePolicyRow>(
          table('ins_policies')
            .select('id, policy_no, expiry_date, currency, gross_premium, ins_clients(bd_clients(name))')
            .in('id', ids),
        );
        for (const p of ps) map.set(p.id, p);
      }
      setPolicies(map);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const generate = async () => {
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_generate_renewal_notices', {});
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const markSent = async (n: NoticeRow) => {
    setBusyId(n.id);
    setError(null);
    try {
      await rpc('ins_mark_renewal_notice_sent', { p_notice_id: n.id, p_channel: channel });
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusyId(null);
    }
  };

  return (
    <Box>
      <PageHeader
        title="Renewal notices"
        subtitle="Generate draft notices for policies in the 120-day renewal window, then mark them sent."
        actions={
          <Button variant="contained" onClick={generate} disabled={busy}>
            {busy ? 'Generating…' : 'Generate notices'}
          </Button>
        }
      />
      <ErrorBanner message={error} />
      {loading ? (
        <CircularProgress />
      ) : (
        <Card><CardContent>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Notice</TableCell>
                <TableCell>Policy</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Expiry</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Channel</TableCell>
                <TableCell>Sent at</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {notices.length === 0 && <EmptyRow colSpan={8} text="No notices yet — generate them for the renewal window." />}
              {notices.map((n) => {
                const p = policies.get(n.policy_id);
                return (
                  <TableRow key={n.id}>
                    <TableCell>{n.notice_no}</TableCell>
                    <TableCell>
                      {p ? (
                        <Button size="small" onClick={() => navigate(`/insurance/policies/${p.id}`)}>{p.policy_no}</Button>
                      ) : '—'}
                    </TableCell>
                    <TableCell>{p?.ins_clients?.bd_clients?.name ?? '—'}</TableCell>
                    <TableCell>{p?.expiry_date ?? '—'}</TableCell>
                    <TableCell>
                      <Chip size="small" label={n.status} color={n.status === 'sent' ? 'success' : 'default'} />
                    </TableCell>
                    <TableCell>{n.channel}</TableCell>
                    <TableCell>{n.sent_at ? n.sent_at.slice(0, 10) : '—'}</TableCell>
                    <TableCell align="right">
                      {n.status === 'draft' && canManage && (
                        <Stack direction="row" spacing={1} justifyContent="flex-end">
                          <TextField select size="small" label="Channel" value={channel}
                            sx={{ minWidth: 110 }}
                            onChange={(e) => setChannel(e.target.value)}>
                            <MenuItem value="email">Email</MenuItem>
                            <MenuItem value="portal">Portal</MenuItem>
                            <MenuItem value="print">Print</MenuItem>
                          </TextField>
                          <Button size="small" variant="outlined" disabled={busyId === n.id}
                            onClick={() => markSent(n)}>
                            Mark sent
                          </Button>
                        </Stack>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </CardContent></Card>
      )}
    </Box>
  );
}
