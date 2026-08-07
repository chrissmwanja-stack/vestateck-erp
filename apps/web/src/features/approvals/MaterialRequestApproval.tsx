import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { CheckCircle as CheckIcon, Cancel as CancelIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

// Gate matches every other Purchasing & Logistics admin screen: am_i_finance()
// wraps has_po_access(), the same check the approve/reject RPCs enforce
// server-side. This just avoids showing an empty/broken screen to non-approvers.
function usePoAccess() {
  const [hasAccess, setHasAccess] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;
    supabase.rpc('am_i_finance').then(({ data, error }) => {
      if (cancelled) return;
      setHasAccess(error ? false : Boolean(data));
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return hasAccess;
}

interface PendingBatch {
  batch_id: string;
  requester_id: string;
  requester_name: string;
  requested_at: string;
  pending_item_count: number;
}

interface RequestItem {
  id: string;
  name: string;
  unit: string | null;
  description_tr: string | null;
  description_en: string | null;
  description_fr: string | null;
  old_material_code: string | null;
  material_types: { code: string; name: string } | null;
  material_groups: { code: string; name: string } | null;
  external_material_groups: { code: string; name: string } | null;
}

const ITEM_SELECT = `
  id, name, unit, description_tr, description_en, description_fr, old_material_code,
  material_types ( code, name ),
  material_groups ( code, name ),
  external_material_groups ( code, name )
`;

export default function MaterialRequestApproval() {
  const hasAccess = usePoAccess();

  const [batches, setBatches] = useState<PendingBatch[]>([]);
  const [batchesLoading, setBatchesLoading] = useState(true);
  const [selectedBatch, setSelectedBatch] = useState<PendingBatch | null>(null);

  const [items, setItems] = useState<RequestItem[]>([]);
  const [itemsLoading, setItemsLoading] = useState(false);

  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [rejectTarget, setRejectTarget] = useState<{ scope: 'item' | 'batch'; id: string } | null>(null);
  const [rejectMessage, setRejectMessage] = useState('');

  const loadBatches = useCallback(async () => {
    setBatchesLoading(true);
    setError(null);
    const { data, error: err } = await supabase.rpc('get_pending_material_request_batches');
    if (err) setError(err.message);
    else setBatches((data ?? []) as PendingBatch[]);
    setBatchesLoading(false);
  }, []);

  useEffect(() => {
    if (hasAccess) loadBatches();
  }, [hasAccess, loadBatches]);

  const openBatch = async (batch: PendingBatch) => {
    setSelectedBatch(batch);
    setItemsLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('material_request_items')
      .select(ITEM_SELECT)
      .eq('batch_id', batch.batch_id)
      .eq('status', 'pending')
      .order('created_at');
    if (err) setError(err.message);
    else setItems((data ?? []) as unknown as RequestItem[]);
    setItemsLoading(false);
  };

  const refreshAfterDecision = async () => {
    await loadBatches();
    if (selectedBatch) {
      const { data } = await supabase
        .from('material_request_items')
        .select(ITEM_SELECT)
        .eq('batch_id', selectedBatch.batch_id)
        .eq('status', 'pending')
        .order('created_at');
      const remaining = (data ?? []) as unknown as RequestItem[];
      setItems(remaining);
      if (remaining.length === 0) setSelectedBatch(null);
    }
  };

  const approveItem = async (itemId: string) => {
    setBusy(true);
    setError(null);
    const { error: err } = await supabase.rpc('approve_material_request_item', { p_item_id: itemId });
    setBusy(false);
    if (err) setError(err.message);
    else refreshAfterDecision();
  };

  const approveBatch = async (batchId: string) => {
    setBusy(true);
    setError(null);
    const { error: err } = await supabase.rpc('approve_all_material_request_items', { p_batch_id: batchId });
    setBusy(false);
    if (err) setError(err.message);
    else refreshAfterDecision();
  };

  const openReject = (scope: 'item' | 'batch', id: string) => {
    setRejectMessage('');
    setRejectTarget({ scope, id });
  };

  const confirmReject = async () => {
    if (!rejectTarget || !rejectMessage.trim()) return;
    setBusy(true);
    setError(null);
    const rpc = rejectTarget.scope === 'item' ? 'reject_material_request_item' : 'reject_all_material_request_items';
    const params =
      rejectTarget.scope === 'item'
        ? { p_item_id: rejectTarget.id, p_message: rejectMessage.trim() }
        : { p_batch_id: rejectTarget.id, p_message: rejectMessage.trim() };
    const { error: err } = await supabase.rpc(rpc, params);
    setBusy(false);
    setRejectTarget(null);
    if (err) setError(err.message);
    else refreshAfterDecision();
  };

  if (hasAccess === null) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress size={24} />
      </Box>
    );
  }

  if (!hasAccess) {
    return <Alert severity="warning">You don't have access to material request approvals.</Alert>;
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 1 }}>
        Material Request Approval
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Pending material catalog proposals, grouped by the batch they were submitted in.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
        <Paper variant="outlined" sx={{ width: { xs: '100%', md: 360 }, flexShrink: 0 }}>
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Requested By</TableCell>
                  <TableCell>Date</TableCell>
                  <TableCell align="right">Items</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {batchesLoading ? (
                  <TableRow>
                    <TableCell colSpan={3} align="center" sx={{ py: 3 }}>
                      <CircularProgress size={20} />
                    </TableCell>
                  </TableRow>
                ) : batches.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={3} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No pending requests.
                    </TableCell>
                  </TableRow>
                ) : (
                  batches.map((b) => (
                    <TableRow
                      key={b.batch_id}
                      hover
                      selected={selectedBatch?.batch_id === b.batch_id}
                      onClick={() => openBatch(b)}
                      sx={{ cursor: 'pointer' }}
                    >
                      <TableCell>{b.requester_name}</TableCell>
                      <TableCell>{new Date(b.requested_at).toLocaleDateString()}</TableCell>
                      <TableCell align="right">{b.pending_item_count}</TableCell>
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          </TableContainer>
        </Paper>

        <Paper variant="outlined" sx={{ flexGrow: 1, p: 2 }}>
          {!selectedBatch ? (
            <Typography color="text.secondary">Select a request on the left to review its items.</Typography>
          ) : (
            <>
              <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
                <Typography variant="subtitle1">
                  {selectedBatch.requester_name} · {new Date(selectedBatch.requested_at).toLocaleString()}
                </Typography>
                <Stack direction="row" spacing={1}>
                  <Button
                    size="small"
                    variant="contained"
                    color="success"
                    startIcon={<CheckIcon />}
                    disabled={busy || items.length === 0}
                    onClick={() => approveBatch(selectedBatch.batch_id)}
                  >
                    Approve All
                  </Button>
                  <Button
                    size="small"
                    variant="outlined"
                    color="error"
                    startIcon={<CancelIcon />}
                    disabled={busy || items.length === 0}
                    onClick={() => openReject('batch', selectedBatch.batch_id)}
                  >
                    Reject All
                  </Button>
                </Stack>
              </Stack>

              {itemsLoading ? (
                <Box display="flex" justifyContent="center" py={4}>
                  <CircularProgress size={24} />
                </Box>
              ) : (
                <TableContainer>
                  <Table size="small">
                    <TableHead>
                      <TableRow>
                        <TableCell>Material</TableCell>
                        <TableCell>Type</TableCell>
                        <TableCell>Goods Group</TableCell>
                        <TableCell>Ext. Group</TableCell>
                        <TableCell>Unit</TableCell>
                        <TableCell>Old No</TableCell>
                        <TableCell align="right">Actions</TableCell>
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {items.map((item) => (
                        <TableRow key={item.id} hover>
                          <TableCell>{item.name}</TableCell>
                          <TableCell>{item.material_types?.code ?? '—'}</TableCell>
                          <TableCell>{item.material_groups?.code ?? '—'}</TableCell>
                          <TableCell>{item.external_material_groups?.code ?? '—'}</TableCell>
                          <TableCell>{item.unit ?? '—'}</TableCell>
                          <TableCell>{item.old_material_code ?? '—'}</TableCell>
                          <TableCell align="right">
                            <Stack direction="row" spacing={1} justifyContent="flex-end">
                              <Button size="small" disabled={busy} onClick={() => approveItem(item.id)}>
                                Approve
                              </Button>
                              <Button size="small" color="error" disabled={busy} onClick={() => openReject('item', item.id)}>
                                Reject
                              </Button>
                            </Stack>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </TableContainer>
              )}
            </>
          )}
        </Paper>
      </Stack>

      <Dialog open={!!rejectTarget} onClose={() => setRejectTarget(null)} maxWidth="sm" fullWidth>
        <DialogTitle>{rejectTarget?.scope === 'batch' ? 'Reject all items' : 'Reject item'}</DialogTitle>
        <DialogContent>
          <TextField
            autoFocus
            fullWidth
            multiline
            minRows={3}
            label="Reason"
            sx={{ mt: 1 }}
            value={rejectMessage}
            onChange={(e) => setRejectMessage(e.target.value)}
            helperText="Required — shown to the requester."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setRejectTarget(null)} disabled={busy}>
            Cancel
          </Button>
          <Button variant="contained" color="error" onClick={confirmReject} disabled={busy || !rejectMessage.trim()}>
            Reject
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}