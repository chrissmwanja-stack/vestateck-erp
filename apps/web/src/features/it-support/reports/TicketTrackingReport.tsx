import { useEffect, useState, useCallback, useMemo } from 'react';
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
  Alert,
  CircularProgress,
  MenuItem,
  TextField,
  Grid,
} from '@mui/material';
import { supabase } from '../../../lib/supabaseClient';

interface Ticket {
  id: string;
  ticket_number: string;
  requester_id: string;
  assignee_id: string | null;
  department_id: string;
  subject: string;
  category: string;
  priority: 'low' | 'medium' | 'high' | 'urgent';
  status: 'open' | 'in_progress' | 'resolved' | 'closed';
  created_at: string;
  resolved_at: string | null;
  closed_at: string | null;
}

interface AppUserOption {
  id: string;
  name: string;
}

interface Department {
  id: string;
  name: string;
}

const statusColor: Record<string, 'default' | 'info' | 'success' | 'warning'> = {
  open: 'warning',
  in_progress: 'info',
  resolved: 'success',
  closed: 'default',
};

const priorityColor: Record<string, 'default' | 'warning' | 'error' | 'info'> = {
  urgent: 'error',
  high: 'warning',
  medium: 'info',
  low: 'default',
};

function daysOpen(t: Ticket): number {
  const end = t.closed_at ?? t.resolved_at ?? new Date().toISOString();
  const ms = new Date(end).getTime() - new Date(t.created_at).getTime();
  return Math.max(0, Math.round((ms / (1000 * 60 * 60 * 24)) * 10) / 10);
}

export default function TicketTrackingReport() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [users, setUsers] = useState<Record<string, string>>({});
  const [departments, setDepartments] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [statusFilter, setStatusFilter] = useState('all');
  const [priorityFilter, setPriorityFilter] = useState('all');
  const [departmentFilter, setDepartmentFilter] = useState('all');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, ticketsRes, usersRes, deptRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_all_tickets'),
      supabase.from('app_users').select('id, name'),
      supabase.from('departments').select('id, name'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (ticketsRes.error) setError(ticketsRes.error.message);
    else setTickets((ticketsRes.data as Ticket[]) ?? []);
    if (!usersRes.error) {
      const map: Record<string, string> = {};
      (usersRes.data as AppUserOption[]).forEach((u) => (map[u.id] = u.name));
      setUsers(map);
    }
    if (!deptRes.error) {
      const map: Record<string, string> = {};
      (deptRes.data as Department[]).forEach((d) => (map[d.id] = d.name));
      setDepartments(map);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const filtered = useMemo(
    () =>
      tickets.filter(
        (t) =>
          (statusFilter === 'all' || t.status === statusFilter) &&
          (priorityFilter === 'all' || t.priority === priorityFilter) &&
          (departmentFilter === 'all' || t.department_id === departmentFilter)
      ),
    [tickets, statusFilter, priorityFilter, departmentFilter]
  );

  const summary = useMemo(() => {
    const counts = { open: 0, in_progress: 0, resolved: 0, closed: 0 };
    tickets.forEach((t) => {
      counts[t.status] += 1;
    });
    return counts;
  }, [tickets]);

  if (!isItSupport && !loading) {
    return (
      <Paper sx={{ p: 4, textAlign: 'center' }}>
        <Typography color="text.secondary">This report is only available to IT Support.</Typography>
      </Paper>
    );
  }

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
        Ticket Tracking Report
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        All IT support tickets across the organization.
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Grid container spacing={2} sx={{ mb: 2 }}>
        {(['open', 'in_progress', 'resolved', 'closed'] as const).map((s) => (
          <Grid item xs={6} sm={3} key={s}>
            <Paper sx={{ p: 2, textAlign: 'center' }}>
              <Typography variant="h5">{summary[s]}</Typography>
              <Typography variant="caption" color="text.secondary" sx={{ textTransform: 'capitalize' }}>
                {s.replace('_', ' ')}
              </Typography>
            </Paper>
          </Grid>
        ))}
      </Grid>

      <Box sx={{ display: 'flex', gap: 2, mb: 2, flexWrap: 'wrap' }}>
        <TextField select size="small" label="Status" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} sx={{ width: 160 }}>
          <MenuItem value="all">All</MenuItem>
          <MenuItem value="open">Open</MenuItem>
          <MenuItem value="in_progress">In progress</MenuItem>
          <MenuItem value="resolved">Resolved</MenuItem>
          <MenuItem value="closed">Closed</MenuItem>
        </TextField>
        <TextField select size="small" label="Priority" value={priorityFilter} onChange={(e) => setPriorityFilter(e.target.value)} sx={{ width: 160 }}>
          <MenuItem value="all">All</MenuItem>
          <MenuItem value="urgent">Urgent</MenuItem>
          <MenuItem value="high">High</MenuItem>
          <MenuItem value="medium">Medium</MenuItem>
          <MenuItem value="low">Low</MenuItem>
        </TextField>
        <TextField select size="small" label="Department" value={departmentFilter} onChange={(e) => setDepartmentFilter(e.target.value)} sx={{ width: 200 }}>
          <MenuItem value="all">All</MenuItem>
          {Object.entries(departments).map(([id, name]) => (
            <MenuItem key={id} value={id}>
              {name}
            </MenuItem>
          ))}
        </TextField>
      </Box>

      {filtered.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No tickets match these filters.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Ticket #</TableCell>
                <TableCell>Subject</TableCell>
                <TableCell>Requester</TableCell>
                <TableCell>Assignee</TableCell>
                <TableCell>Department</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Priority</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Created</TableCell>
                <TableCell align="right">Days open</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.map((t) => (
                <TableRow key={t.id} hover>
                  <TableCell>{t.ticket_number}</TableCell>
                  <TableCell>{t.subject}</TableCell>
                  <TableCell>{users[t.requester_id] ?? '—'}</TableCell>
                  <TableCell>{t.assignee_id ? users[t.assignee_id] ?? '—' : 'Unassigned'}</TableCell>
                  <TableCell>{departments[t.department_id] ?? '—'}</TableCell>
                  <TableCell>{t.category}</TableCell>
                  <TableCell>
                    <Chip size="small" label={t.priority} color={priorityColor[t.priority]} />
                  </TableCell>
                  <TableCell>
                    <Chip size="small" label={t.status.replace('_', ' ')} color={statusColor[t.status]} />
                  </TableCell>
                  <TableCell>{new Date(t.created_at).toLocaleDateString()}</TableCell>
                  <TableCell align="right">{daysOpen(t)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
}