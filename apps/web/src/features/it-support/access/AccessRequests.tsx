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
  Alert,
  CircularProgress,
  Tabs,
  Tab,
} from '@mui/material';
import { supabase } from '../../../lib/supabaseClient';

type RequestStatus = 'pending' | 'approved' | 'rejected';

interface MyRequest {
  id: string;
  resource: string;
  access_level: string | null;
  justification: string | null;
  status: RequestStatus;
  decision_notes: string | null;
  decided_at: string | null;
  created_at: string;
}

interface QueueRequest extends MyRequest {
  requested_by: string;
  requester_name: string;
}

const statusColor: Record<RequestStatus, 'default' | 'success' | 'error'> = {
  pending: 'default',
  approved: 'success',
  rejected: 'error',
};

export default function AccessRequests() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [tab, setTab] = useState<'new' | 'mine' | 'queue'>('new');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [resource, setResource] = useState('');
  const [accessLevel, setAccessLevel] = useState('');
  const [justification, setJustification] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  const [myRequests, setMyRequests] = useState<MyRequest[]>([]);
  const [queue, setQueue] = useState<QueueRequest[]>([]);
  const [queueStatus, setQueueStatus] = useState<'pending' | 'all'>('pending');

  const [decisionTarget, setDecisionTarget] = useState<{ req: QueueRequest; decision: 'approved' | 'rejected' } | null>(null);
  const [decisionNotes, setDecisionNotes] = useState('');
  const [acting, setActing] = useState(false);

  const loadMine = useCallback(async () => {
    const { data, error } = await supabase.rpc('get_my_access_requests');
    if (error) setError(error.message);
    else setMyRequests((data as MyRequest[]) ?? []);
  }, []);

  const loadQueue = useCallback(async (status: 'pending' | 'all') => {
    const { data, error } = await supabase.rpc('get_access_requests', { p_status: status === 'all' ? undefined : status });
    if (error) setError(error.message);
    else setQueue((data as QueueRequest[]) ?? []);
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
    if (!resource.trim()) return;
    setSubmitting(true);
    setError(null);
    const { error } = await supabase.rpc('create_access_request', {
      p_resource: resource,
      p_access_level: accessLevel || undefined,
      p_justification: justification || undefined,
    });
    setSubmitting(false);
    if (error) {
      setError(error.message);
      return;
    }
    setResource('');
    setAccessLevel('');
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
    const { error } = await supabase.rpc('decide_access_request', {
      p_request_id: decisionTarget.req.id,
      p_decision: decisionTarget.decision,
      p_notes: decisionNotes || undefined,
    });
    setActing(false);
    if (error) {
      setError(error.message);
      return;
    }
    setDecisionTarget(null);
    loadQueue(queueStatus);
  };

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
        Access Requests
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Request access to a system or resource. {isItSupport && 'IT Support can review requests here.'}
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
            <TextField
              label="System / resource"
              placeholder="e.g. Shared drive, ERP finance module…"
              value={resource}
              onChange={(e) => setResource(e.target.value)}
              fullWidth
            />
            <TextField
              label="Access level"
              placeholder="e.g. Read, Write, Admin"
              value={accessLevel}
              onChange={(e) => setAccessLevel(e.target.value)}
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
            <Button variant="contained" onClick={submitRequest} disabled={submitting || !resource.trim()} sx={{ alignSelf: 'flex-start' }}>
              {submitting ? 'Submitting…' : 'Submit request'}
            </Button>
          </Box>
        </Paper>
      )}

      {tab === 'mine' &&
        (myRequests.length === 0 ? (
          <Paper sx={{ p: 4, textAlign: 'center' }}>
            <Typography color="text.secondary">You haven't submitted any access requests yet.</Typography>
          </Paper>
        ) : (
          <TableContainer component={Paper}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Requested</TableCell>
                  <TableCell>Resource</TableCell>
                  <TableCell>Level</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Notes</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {myRequests.map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell>{new Date(r.created_at).toLocaleDateString()}</TableCell>
                    <TableCell>{r.resource}</TableCell>
                    <TableCell>{r.access_level ?? '—'}</TableCell>
                    <TableCell>
                      <Chip size="small" label={r.status} color={statusColor[r.status]} />
                    </TableCell>
                    <TableCell>{r.decision_notes ?? '—'}</TableCell>
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
                    <TableCell>Resource</TableCell>
                    <TableCell>Level</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell align="right">Action</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {queue.map((r) => (
                    <TableRow key={r.id} hover>
                      <TableCell>{new Date(r.created_at).toLocaleDateString()}</TableCell>
                      <TableCell>{r.requester_name}</TableCell>
                      <TableCell>{r.resource}</TableCell>
                      <TableCell>{r.access_level ?? '—'}</TableCell>
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
              {decisionTarget.decision === 'approved' ? 'Approve' : 'Reject'} request — {decisionTarget.req.resource}
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
    </Box>
  );
}