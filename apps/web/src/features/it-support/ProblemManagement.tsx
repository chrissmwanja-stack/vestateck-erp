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
  List,
  ListItem,
  ListItemText,
  IconButton,
  Autocomplete,
} from '@mui/material';
import { Close, Add } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

type ProblemStatus = 'open' | 'investigating' | 'resolved' | 'closed';
type Priority = 'low' | 'medium' | 'high' | 'urgent';

interface Problem {
  id: string;
  problem_number: string;
  title: string;
  description: string | null;
  root_cause: string | null;
  status: ProblemStatus;
  category: string | null;
  priority: Priority;
  assigned_to: string | null;
  created_at: string;
}

interface TicketRow {
  id: string;
  ticket_number: string;
  subject: string;
  status: string;
}

const statusColor: Record<ProblemStatus, 'default' | 'warning' | 'success' | 'info'> = {
  open: 'info',
  investigating: 'warning',
  resolved: 'success',
  closed: 'default',
};

// Groups recurring it_tickets under a shared root-cause record. IT
// Support only -- gated by is_it_support() on every RPC. Linking is
// many-to-many via problem_tickets rather than a ticket belonging to
// one problem, since the same underlying issue can surface differently.
export default function ProblemManagement() {
  const [problems, setProblems] = useState<Problem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [newTitle, setNewTitle] = useState('');
  const [newDescription, setNewDescription] = useState('');
  const [newCategory, setNewCategory] = useState('');
  const [newPriority, setNewPriority] = useState<Priority>('medium');
  const [creating, setCreating] = useState(false);

  const [detail, setDetail] = useState<Problem | null>(null);
  const [linkedTickets, setLinkedTickets] = useState<TicketRow[]>([]);
  const [allTickets, setAllTickets] = useState<TicketRow[]>([]);
  const [ticketToLink, setTicketToLink] = useState<TicketRow | null>(null);
  const [rootCauseDraft, setRootCauseDraft] = useState('');
  const [savingDetail, setSavingDetail] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase.rpc('get_problems');
    if (error) setError(error.message);
    else setProblems((data as Problem[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const createProblem = async () => {
    if (!newTitle.trim()) return;
    setCreating(true);
    const { error } = await supabase.rpc('create_problem', {
      p_title: newTitle,
      p_description: newDescription || undefined,
      p_category: newCategory || undefined,
      p_priority: newPriority,
    });
    setCreating(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewOpen(false);
    setNewTitle('');
    setNewDescription('');
    setNewCategory('');
    setNewPriority('medium');
    load();
  };

  const openDetail = async (problem: Problem) => {
    setDetail(problem);
    setRootCauseDraft(problem.root_cause ?? '');
    const [{ data: linked }, { data: all }] = await Promise.all([
      supabase.rpc('get_problem_tickets', { p_problem_id: problem.id }),
      supabase.rpc('get_all_tickets'),
    ]);
    setLinkedTickets((linked as TicketRow[]) ?? []);
    setAllTickets((all as TicketRow[]) ?? []);
  };

  const closeDetail = () => {
    setDetail(null);
    setLinkedTickets([]);
    setAllTickets([]);
    setTicketToLink(null);
  };

  const saveDetail = async (status?: ProblemStatus) => {
    if (!detail) return;
    setSavingDetail(true);
    const { error } = await supabase.rpc('update_problem', {
      p_problem_id: detail.id,
      p_status: status ?? undefined,
      p_root_cause: rootCauseDraft || undefined,
    });
    setSavingDetail(false);
    if (error) {
      setError(error.message);
      return;
    }
    closeDetail();
    load();
  };

  const linkTicket = async () => {
    if (!detail || !ticketToLink) return;
    const { error } = await supabase.rpc('link_ticket_to_problem', {
      p_problem_id: detail.id,
      p_ticket_id: ticketToLink.id,
    });
    if (error) {
      setError(error.message);
      return;
    }
    setTicketToLink(null);
    const { data: linked } = await supabase.rpc('get_problem_tickets', { p_problem_id: detail.id });
    setLinkedTickets((linked as TicketRow[]) ?? []);
  };

  const unlinkTicket = async (ticketId: string) => {
    if (!detail) return;
    const { error } = await supabase.rpc('unlink_ticket_from_problem', {
      p_problem_id: detail.id,
      p_ticket_id: ticketId,
    });
    if (error) {
      setError(error.message);
      return;
    }
    setLinkedTickets((prev) => prev.filter((t) => t.id !== ticketId));
  };

  const linkableTickets = allTickets.filter((t) => !linkedTickets.some((l) => l.id === t.id));

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">Problem Management</Typography>
          <Typography variant="body2" color="text.secondary">
            Group recurring tickets into a problem and track its root cause through to resolution.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setNewOpen(true)}>
          New problem
        </Button>
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
          <CircularProgress />
        </Box>
      ) : problems.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No problems logged yet.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Problem</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Priority</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Logged</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {problems.map((p) => (
                <TableRow key={p.id} hover sx={{ cursor: 'pointer' }} onClick={() => openDetail(p)}>
                  <TableCell>{p.problem_number}</TableCell>
                  <TableCell>{p.title}</TableCell>
                  <TableCell>{p.category ?? '—'}</TableCell>
                  <TableCell>{p.priority}</TableCell>
                  <TableCell>
                    <Chip size="small" label={p.status} color={statusColor[p.status]} />
                  </TableCell>
                  <TableCell>{new Date(p.created_at).toLocaleDateString()}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {/* New problem */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New problem</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Title" value={newTitle} onChange={(e) => setNewTitle(e.target.value)} fullWidth autoFocus />
          <TextField
            label="Description"
            value={newDescription}
            onChange={(e) => setNewDescription(e.target.value)}
            fullWidth
            multiline
            minRows={2}
          />
          <TextField label="Category" value={newCategory} onChange={(e) => setNewCategory(e.target.value)} fullWidth />
          <TextField
            select
            label="Priority"
            value={newPriority}
            onChange={(e) => setNewPriority(e.target.value as Priority)}
            fullWidth
          >
            {(['low', 'medium', 'high', 'urgent'] as Priority[]).map((p) => (
              <MenuItem key={p} value={p}>
                {p}
              </MenuItem>
            ))}
          </TextField>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createProblem} disabled={creating || !newTitle.trim()}>
            {creating ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Detail / edit */}
      <Dialog open={!!detail} onClose={closeDetail} fullWidth maxWidth="md">
        {detail && (
          <>
            <DialogTitle>
              {detail.problem_number} — {detail.title}
            </DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              <TextField
                label="Root cause"
                value={rootCauseDraft}
                onChange={(e) => setRootCauseDraft(e.target.value)}
                fullWidth
                multiline
                minRows={3}
              />

              <Box>
                <Typography variant="subtitle2" sx={{ mb: 1 }}>
                  Linked tickets
                </Typography>
                {linkedTickets.length === 0 ? (
                  <Typography variant="body2" color="text.secondary">
                    No tickets linked yet.
                  </Typography>
                ) : (
                  <List dense>
                    {linkedTickets.map((t) => (
                      <ListItem
                        key={t.id}
                        secondaryAction={
                          <IconButton size="small" onClick={() => unlinkTicket(t.id)}>
                            <Close fontSize="small" />
                          </IconButton>
                        }
                      >
                        <ListItemText primary={`${t.ticket_number} — ${t.subject}`} secondary={t.status} />
                      </ListItem>
                    ))}
                  </List>
                )}
                <Box sx={{ display: 'flex', gap: 1, mt: 1 }}>
                  <Autocomplete
                    size="small"
                    sx={{ flex: 1 }}
                    options={linkableTickets}
                    getOptionLabel={(t) => `${t.ticket_number} — ${t.subject}`}
                    value={ticketToLink}
                    onChange={(_, value) => setTicketToLink(value)}
                    renderInput={(params) => <TextField {...params} label="Link a ticket" />}
                  />
                  <Button onClick={linkTicket} disabled={!ticketToLink}>
                    Link
                  </Button>
                </Box>
              </Box>
            </DialogContent>
            <DialogActions sx={{ justifyContent: 'space-between', px: 3 }}>
              <Box sx={{ display: 'flex', gap: 1 }}>
                {(['investigating', 'resolved', 'closed'] as ProblemStatus[])
                  .filter((s) => s !== detail.status)
                  .map((s) => (
                    <Button key={s} size="small" onClick={() => saveDetail(s)} disabled={savingDetail}>
                      Mark {s}
                    </Button>
                  ))}
              </Box>
              <Box>
                <Button onClick={closeDetail}>Close</Button>
                <Button variant="contained" onClick={() => saveDetail()} disabled={savingDetail}>
                  {savingDetail ? 'Saving…' : 'Save'}
                </Button>
              </Box>
            </DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
}