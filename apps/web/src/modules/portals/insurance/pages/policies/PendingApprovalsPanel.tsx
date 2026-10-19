import { useCallback, useEffect, useRef, useState } from 'react';
import { Alert, Box, Button, Chip, CircularProgress, Stack, Table, TableBody, TableCell, TableHead, TableRow, Typography } from '@mui/material';
import { errorText, rpc } from '../../db';
import { formatMoney } from '../../logic';
import {
  PENDING_LIMIT, PENDING_TYPE_LABEL, orderForReviewer, pendingCounts, pendingKindLabel, waitingLabel, type PendingApproval,
} from '../../pendingApprovals';

/** Finance's worklist of cash and cancellation items waiting for a decision. Opening one selects its policy. */
export default function PendingApprovalsPanel({ onOpen }: { onOpen: (policyId: string) => void }) {
  const [items, setItems] = useState<PendingApproval[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const generation = useRef(0);

  const load = useCallback(async () => {
    const current = ++generation.current;
    try {
      const data = await rpc<PendingApproval[]>('ins_finance_pending_approvals');
      if (current !== generation.current) return;
      setItems(data ?? []);
      setError(null);
    } catch (e) {
      if (current === generation.current) setError(errorText(e));
    }
  }, []);
  useEffect(() => {
    void load();
    return () => { generation.current++; };
  }, [load]);

  const ordered = items ? orderForReviewer(items) : [];
  const counts = pendingCounts(items ?? []);

  return (
    <Box sx={{ mb: 3 }} aria-label="Pending approvals">
      <Stack direction="row" spacing={2} alignItems="center" sx={{ mb: 1 }}>
        <Typography variant="h6">Waiting for Finance</Typography>
        {items && <Chip size="small" color={counts.forYou ? 'primary' : 'default'} label={`${counts.forYou} for you to decide`} />}
        {items && counts.yours > 0 && <Chip size="small" variant="outlined" label={`${counts.yours} you submitted`} />}
        <Button onClick={() => void load()}>Refresh</Button>
      </Stack>
      {error && <Alert severity="error" sx={{ mb: 1 }}>{error}</Alert>}
      {!items && !error && <CircularProgress size={20} />}
      {items && items.length === 0 && <Alert severity="success">Nothing is waiting for Finance.</Alert>}
      {items && items.length >= PENDING_LIMIT && (
        <Alert severity="info" sx={{ mb: 1 }}>Showing the {PENDING_LIMIT} that have waited longest. Decide some, then refresh to see the rest.</Alert>
      )}
      {items && items.length > 0 && (
        <Box sx={{ overflowX: 'auto' }}>
          <Table size="small" aria-label="Items waiting for Finance">
            <TableHead>
              <TableRow>
                <TableCell>Item</TableCell><TableCell>Policy</TableCell><TableCell>Client</TableCell><TableCell>Insurer</TableCell>
                <TableCell align="right">Amount</TableCell><TableCell>Submitted</TableCell><TableCell />
              </TableRow>
            </TableHead>
            <TableBody>
              {ordered.map((i) => (
                <TableRow key={`${i.item_type}-${i.item_id}`}>
                  <TableCell>
                    <Typography variant="body2" sx={{ fontWeight: 600 }}>{pendingKindLabel(i)}</Typography>
                    <Typography variant="caption" color="text.secondary">{PENDING_TYPE_LABEL[i.item_type]}</Typography>
                  </TableCell>
                  <TableCell sx={{ fontFamily: 'monospace' }}>{i.policy_no}</TableCell>
                  <TableCell>{i.client_name}</TableCell>
                  <TableCell>{i.insurer_name}</TableCell>
                  <TableCell align="right">{i.amount === null ? '-' : formatMoney(Number(i.amount), i.currency)}</TableCell>
                  <TableCell>
                    {i.submitted_by_name}
                    <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>{waitingLabel(i.submitted_at)}</Typography>
                  </TableCell>
                  <TableCell>
                    {i.is_mine && <Chip size="small" variant="outlined" label="You submitted it" sx={{ mr: 1 }} />}
                    <Button size="small" variant={i.is_mine ? 'text' : 'contained'} onClick={() => onOpen(i.policy_id)}>
                      {i.is_mine ? 'Open' : 'Review'}
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Box>
      )}
    </Box>
  );
}
