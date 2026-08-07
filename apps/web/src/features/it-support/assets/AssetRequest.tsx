import { useEffect, useState, useCallback } from 'react';
import {
  Box,
  Typography,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Chip,
  Button,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  MenuItem,
  Alert,
  CircularProgress,
  Tabs,
  Tab,
} from '@mui/material';
import { supabase } from '../../../lib/supabaseClient';

type AssetType = 'hardware' | 'software';
type RequestStatus = 'pending' | 'approved' | 'rejected' | 'fulfilled';

interface MyRequest {
  id: string;
  asset_type: AssetType;
  item_description: string;
  justification: string | null;
  status: RequestStatus;
  decision_notes: string | null;
  decided_at: string | null;
  fulfilled_asset_tag: string | null;
  created_at: string;
}

interface QueueRequest extends MyRequest {
  requested_by: string;
  requester_name: string;
  decided_by: string | null;
}

interface AvailableAsset {
  id: string;
  asset_tag: string;
  name: string;
  type: AssetType;
  status: string;
}

const statusColor: Record<RequestStatus, 'default' | 'success' | 'error' | 'info'> = {
  pending: 'default',
  approved: 'info',
  rejected: 'error',
  fulfilled: 'success',
};

export default function AssetRequest() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [tab, setTab] = useState<'new' | 'mine' | 'queue'>('new');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // New request form
  const [assetType, setAssetType] = useState<AssetType>('hardware');
  const [itemDescription, setItemDescription] = useState('');
  const [justification, setJustification] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  // My requests
  const [myRequests, setMyRequests] = useState<MyRequest[]>([]);

  // IT support queue
  const [queue, setQueue] = useState<QueueRequest[]>([]);
  const [queueStatus, setQueueStatus] = useState<'pending' | 'all'>('pending');
  const [availableAssets, setAvailableAssets] = useState<AvailableAsset[]>([]);

  const [decisionTarget, setDecisionTarget] = useState<{ req: QueueRequest; decision: 'approved' | 'rejected' } | null>(null);
  const [decisionNotes, setDecisionNotes] = useState('');
  const [fulfillTarget, setFulfillTarget] = useState<QueueRequest | null>(null);
  const [fulfillAssetId, setFulfillAssetId] = useState('');
  const [fulfillNotes, setFulfillNotes] = useState('');
  const [acting, setActing] = useState(false);

  const loadMine = useCallback(async () => {
    const { data, error } = await supabase.rpc('get_my_asset_requests');
    if (error) setError(error.message);
    else setMyRequests((data as MyRequest[]) ?? []);
  }, []);

  const loadQueue = useCallback(async (status: 'pending' | 'all') => {
    const [queueRes, assetsRes] = await Promise.all([
      supabase.rpc('get_asset_requests', { p_status: status === 'all' ? null : status }),
      supabase.rpc('get_assets', { p_type: null }),
    ]);
    if (queueRes.error) setError(queueRes.error.message);
    else setQueue((queueRes.data as QueueRequest[]) ?? []);
    if (!assetsRes.error) {
      const inStock = ((assetsRes.data as AvailableAsset[]) ?? []).filter((a) => a.status === 'in_stock');
      setAvailableAssets(inStock);
    }
  }, []);

  const init = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data: itSupportFlag } = await supabase.rpc('is_it_support');
    setIsItSupport(Boolean(itSupportFlag));
    await loadMine();
    if (itSupportFlag) await loadQueue('pending');
    setLoading(false);
  }, [loadMine, loadQueue]);

  useEffect(() => {
    init();
  }, [init]);

  useEffect(() => {
    if (tab === 'queue' && isItSupport) loadQueue(queueStatus);
  }, [tab, queueStatus, isItSupport, loadQueue]);

  const submitRequest = async () => {
    if (!itemDescription.trim()) return;
    setSubmitting(true);
    setError(null);
    const { error } = await supabase.rpc('create_asset_request', {
      p_asset_type: assetType,
      p_item_description: itemDescription,
      p_justification: justification || null,
    });
    setSubmitting(false);
    if (error) {
      setError(error.message);
      return;
    }
    setItemDescription('');
    setJustification('');
    setSubmitted(true);
    loadMine();
  };

  const openDecision = (req: QueueRequest, decision: 'approved' | 'rejected') => {
    setDecisionTarget({ req, decision });
    setDecisionNotes('');
  };

  const confirmDecision = async () => {
    if (!decisionTarget) return;
    setActing(true);
    const { error } = await supabase.rpc('decide_asset_request', {
      p_request_id: decisionTarget.req.id,
      p_decision: decisionTarget.decision,
      p_notes: decisionNotes || null,
    });
    setActing(false);
    if (error) {
      setError(error.message);
      return;
    }
    setDecisionTarget(null);
    loadQueue(queueStatus);
  };

  const openFulfill = (req: QueueRequest) => {
    setFulfillTarget(req);
    setFulfillAssetId('');
    setFulfillNotes('');
  };

  const confirmFulfill = async () => {
    if (!fulfillTarget || !fulfillAssetId) return;
    setActing(true);
    const { error } = await supabase.rpc('fulfill_asset_request', {
      p_request_id: fulfillTarget.id,
      p_asset_id: fulfillAssetId,
      p_notes: fulfillNotes || null,
    });
    setActing(false);
    if (error) {
      setError(error.message);
      return;
    }
    setFulfillTarget(null);
    loadQueue(queueStatus);
  };

  const matchingAssets = fulfillTarget ? availableAssets.filter((a) => a.type === fulfillTarget.asset_type) : [];

  if (loading) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 0.5 }}>
        Asset Request
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Request hardware or software from IT. {isItSupport && 'IT Support can also review and fulfill requests here.'}
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Tabs value={tab} onChange={(_, v) => setTab(v)} sx={{ mb: 2, borderBottom: 1, borderColor: 'divider' }}>
        <Tab label="New request" value="new" />
        <Tab label="My requests" value="mine" />
        {isItSupport && <Tab label="Review queue" value="queue" />}
      </Tabs>

      {tab === 'new' && (
        <Paper sx={{ p: 3, maxWidth: 520 }}>
          {submitted && (
            <Alert severity="success" sx={{ mb: 2 }} onClose={() => setSubmitted(false)}>
              Request submitted. Track it under "My requests".
            </Alert>
          )}
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <TextField select label="Asset type" value={assetType} onChange={(e) => setAssetType(e.target.value as AssetType)} fullWidth>
              <MenuItem value="hardware">Hardware</MenuItem>
              <MenuItem value="software">Software</MenuItem>
            </TextField>
            <TextField
              label="What do you need?"
              placeholder="e.g. Laptop, Adobe Photoshop license…"
              value={itemDescription}
              onChange={(e) => setItemDescription(e.target.value)}
              fullWidth
            />
            <TextField
              label="Justification"
              value={justification}
              onChange={(e) => setJustification(e.target.value)}
              fullWidth
              multiline
              minRows={2}
            />
            <Button variant="contained" onClick={submitRequest} disabled={submitting || !itemDescription.trim()} sx={{ alignSelf: 'flex-start' }}>
              {submitting ? 'Submitting…' : 'Submit request'}
            </Button>
          </Box>
        </Paper>
      )}

      {tab === 'mine' &&
        (myRequests.length === 0 ? (
          <Paper sx={{ p: 4, textAlign: 'center' }}>
            <Typography color="text.secondary">You haven't submitted any asset requests yet.</Typography>
          </Paper>
        ) : (
          <TableContainer component={Paper}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Requested</TableCell>
                  <TableCell>Type</TableCell>
                  <TableCell>Item</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Notes</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {myRequests.map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell>{new Date(r.created_at).toLocaleDateString()}</TableCell>
                    <TableCell sx={{ textTransform: 'capitalize' }}>{r.asset_type}</TableCell>
                    <TableCell>{r.item_description}</TableCell>
                    <TableCell>
                      <Chip size="small" label={r.status} color={statusColor[r.status]} />
                    </TableCell>
                    <TableCell>
                      {r.status === 'fulfilled' && r.fulfilled_asset_tag
                        ? `Assigned: ${r.fulfilled_asset_tag}`
                        : r.decision_notes ?? '—'}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
        ))}

      {tab === 'queue' && isItSupport && (
        <Box>
          <Box sx={{ display: 'flex', gap: 1, mb: 2 }}>
            <Button size="small" variant={queueStatus === 'pending' ? 'contained' : 'outlined'} onClick={() => setQueueStatus('pending')}>
              Pending
            </Button>
            <Button size="small" variant={queueStatus === 'all' ? 'contained' : 'outlined'} onClick={() => setQueueStatus('all')}>
              All
            </Button>
          </Box>
          {queue.length === 0 ? (
            <Paper sx={{ p: 4, textAlign: 'center' }}>
              <Typography color="text.secondary">No {queueStatus === 'pending' ? 'pending' : ''} requests.</Typography>
            </Paper>
          ) : (
            <TableContainer component={Paper}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Requested</TableCell>
                    <TableCell>Requester</TableCell>
                    <TableCell>Type</TableCell>
                    <TableCell>Item</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell align="right">Action</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {queue.map((r) => (
                    <TableRow key={r.id} hover>
                      <TableCell>{new Date(r.created_at).toLocaleDateString()}</TableCell>
                      <TableCell>{r.requester_name}</TableCell>
                      <TableCell sx={{ textTransform: 'capitalize' }}>{r.asset_type}</TableCell>
                      <TableCell>{r.item_description}</TableCell>
                      <TableCell>
                        <Chip size="small" label={r.status} color={statusColor[r.status]} />
                      </TableCell>
                      <TableCell align="right">
                        {r.status === 'pending' && (
                          <>
                            <Button size="small" onClick={() => openDecision(r, 'approved')}>
                              Approve
                            </Button>
                            <Button size="small" color="error" onClick={() => openDecision(r, 'rejected')}>
                              Reject
                            </Button>
                          </>
                        )}
                        {r.status === 'approved' && (
                          <Button size="small" variant="contained" onClick={() => openFulfill(r)}>
                            Fulfill
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </TableContainer>
          )}
        </Box>
      )}

      {/* Approve / reject dialog */}
      <Dialog open={!!decisionTarget} onClose={() => setDecisionTarget(null)} fullWidth maxWidth="sm">
        {decisionTarget && (
          <>
            <DialogTitle>
              {decisionTarget.decision === 'approved' ? 'Approve' : 'Reject'} request — {decisionTarget.req.item_description}
            </DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              <Typography variant="body2" color="text.secondary">
                Requested by {decisionTarget.req.requester_name}.
              </Typography>
              <TextField label="Notes" value={decisionNotes} onChange={(e) => setDecisionNotes(e.target.value)} fullWidth multiline minRows={2} />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setDecisionTarget(null)}>Cancel</Button>
              <Button
                variant="contained"
                color={decisionTarget.decision === 'rejected' ? 'error' : 'primary'}
                onClick={confirmDecision}
                disabled={acting}
              >
                {acting ? 'Saving…' : decisionTarget.decision === 'approved' ? 'Approve' : 'Reject'}
              </Button>
            </DialogActions>
          </>
        )}
      </Dialog>

      {/* Fulfill dialog */}
      <Dialog open={!!fulfillTarget} onClose={() => setFulfillTarget(null)} fullWidth maxWidth="sm">
        {fulfillTarget && (
          <>
            <DialogTitle>Fulfill — {fulfillTarget.item_description}</DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              {matchingAssets.length === 0 ? (
                <Alert severity="warning">
                  No in-stock {fulfillTarget.asset_type} assets available. Add one in{' '}
                  {fulfillTarget.asset_type === 'hardware' ? 'Hardware Inventory' : 'Software Inventory'} first.
                </Alert>
              ) : (
                <TextField select label="Assign asset" value={fulfillAssetId} onChange={(e) => setFulfillAssetId(e.target.value)} fullWidth>
                  {matchingAssets.map((a) => (
                    <MenuItem key={a.id} value={a.id}>
                      {a.asset_tag} — {a.name}
                    </MenuItem>
                  ))}
                </TextField>
              )}
              <TextField label="Notes" value={fulfillNotes} onChange={(e) => setFulfillNotes(e.target.value)} fullWidth multiline minRows={2} />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setFulfillTarget(null)}>Cancel</Button>
              <Button variant="contained" onClick={confirmFulfill} disabled={acting || !fulfillAssetId}>
                {acting ? 'Fulfilling…' : 'Fulfill'}
              </Button>
            </DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
}