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
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

interface TicketRow {
  id: string;
  ticket_number: string;
  subject: string;
  description: string;
  category: string;
  priority: string;
  status: string;
  approval_status: string;
  requester_id: string;
  created_at: string;
}

type Decision = 'approved' | 'rejected';

const priorityColor: Record<string, 'default' | 'warning' | 'error' | 'info'> = {
  low: 'default',
  medium: 'info',
  high: 'warning',
  urgent: 'error',
};

// Tickets land here automatically when their category requires sign-off
// (currently: Access) -- see the set_ticket_number trigger. Any IT Support
// staff member can decide; there's no separate manager-approval concept.
export default function TicketApprovals() {
  const [tickets, setTickets] = useState<TicketRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [activeTicket, setActiveTicket] = useState<TicketRow | null>(null);
  const [decision, setDecision] = useState<Decision | null>(null);
  const [notes, setNotes] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase.rpc('get_pending_ticket_approvals');
    if (error) {
      setError(error.message);
    } else {
      setTickets((data as TicketRow[]) ?? []);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openDecision = (ticket: TicketRow, d: Decision) => {
    setActiveTicket(ticket);
    setDecision(d);
    setNotes('');
  };

  const closeDialog = () => {
    setActiveTicket(null);
    setDecision(null);
    setNotes('');
  };

  const submitDecision = async () => {
    if (!activeTicket || !decision) return;
    setSubmitting(true);
    const { error } = await supabase.rpc('record_ticket_approval', {
      p_ticket_id: activeTicket.id,
      p_decision: decision,
      p_notes: notes || undefined,
    });
    setSubmitting(false);
    if (error) {
      setError(error.message);
      return;
    }
    closeDialog();
    load();
  };

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Ticket Approvals
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Tickets that need sign-off before IT Support can act on them.
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
          <CircularProgress />
        </Box>
      ) : tickets.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">Nothing waiting on approval right now.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Ticket</TableCell>
                <TableCell>Subject</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Priority</TableCell>
                <TableCell>Submitted</TableCell>
                <TableCell align="right">Decision</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {tickets.map((t) => (
                <TableRow key={t.id} hover>
                  <TableCell>{t.ticket_number}</TableCell>
                  <TableCell>{t.subject}</TableCell>
                  <TableCell>{t.category}</TableCell>
                  <TableCell>
                    <Chip size="small" label={t.priority} color={priorityColor[t.priority] ?? 'default'} />
                  </TableCell>
                  <TableCell>{new Date(t.created_at).toLocaleString()}</TableCell>
                  <TableCell align="right">
                    <Button size="small" color="success" onClick={() => openDecision(t, 'approved')} sx={{ mr: 1 }}>
                      Approve
                    </Button>
                    <Button size="small" color="error" onClick={() => openDecision(t, 'rejected')}>
                      Reject
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Dialog open={!!activeTicket} onClose={closeDialog} fullWidth maxWidth="sm">
        <DialogTitle>
          {decision === 'approved' ? 'Approve' : 'Reject'} {activeTicket?.ticket_number}
        </DialogTitle>
        <DialogContent>
          <Typography variant="body2" sx={{ mb: 2 }}>
            {activeTicket?.subject}
          </Typography>
          <TextField
            label={decision === 'rejected' ? 'Reason for rejection' : 'Notes (optional)'}
            fullWidth
            multiline
            minRows={3}
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
          />
          {decision === 'rejected' && (
            <Alert severity="warning" sx={{ mt: 2 }}>
              Rejecting closes this ticket outright — the requester will need to file a new one.
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeDialog}>Cancel</Button>
          <Button
            variant="contained"
            color={decision === 'approved' ? 'success' : 'error'}
            onClick={submitDecision}
            disabled={submitting}
          >
            {submitting ? 'Submitting…' : decision === 'approved' ? 'Approve' : 'Reject'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}