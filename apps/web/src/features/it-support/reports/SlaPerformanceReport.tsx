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
  LinearProgress,
  Grid,
} from '@mui/material';
import { supabase } from '../../../lib/supabaseClient';

interface Ticket {
  id: string;
  ticket_number: string;
  subject: string;
  priority: 'low' | 'medium' | 'high' | 'urgent';
  status: 'open' | 'in_progress' | 'resolved' | 'closed';
  created_at: string;
  resolved_at: string | null;
  closed_at: string | null;
}

interface SlaPolicy {
  priority: 'low' | 'medium' | 'high' | 'urgent';
  target_hours: number;
}

const priorityOrder = ['urgent', 'high', 'medium', 'low'] as const;
const priorityColor: Record<string, 'default' | 'warning' | 'error' | 'info'> = {
  urgent: 'error',
  high: 'warning',
  medium: 'info',
  low: 'default',
};

function resolutionHours(t: Ticket): number | null {
  const end = t.resolved_at ?? t.closed_at;
  if (!end) return null;
  return (new Date(end).getTime() - new Date(t.created_at).getTime()) / (1000 * 60 * 60);
}

export default function SlaPerformanceReport() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [policies, setPolicies] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, ticketsRes, policiesRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_all_tickets'),
      supabase.rpc('get_sla_policies'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (ticketsRes.error) setError(ticketsRes.error.message);
    else setTickets((ticketsRes.data as Ticket[]) ?? []);
    if (policiesRes.error) setError((prev) => prev ?? policiesRes.error.message);
    else {
      const map: Record<string, number> = {};
      (policiesRes.data as SlaPolicy[]).forEach((p) => (map[p.priority] = p.target_hours));
      setPolicies(map);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const resolved = useMemo(
    () => tickets.filter((t) => t.status === 'resolved' || t.status === 'closed'),
    [tickets]
  );

  const byPriority = useMemo(() => {
    return priorityOrder.map((priority) => {
      const target = policies[priority];
      const rows = resolved
        .filter((t) => t.priority === priority)
        .map((t) => ({ ticket: t, hours: resolutionHours(t) }))
        .filter((r) => r.hours !== null) as { ticket: Ticket; hours: number }[];
      const met = target ? rows.filter((r) => r.hours <= target).length : 0;
      const avgHours = rows.length ? rows.reduce((sum, r) => sum + r.hours, 0) / rows.length : 0;
      return {
        priority,
        target,
        total: rows.length,
        met,
        breached: rows.length - met,
        compliancePct: rows.length ? Math.round((met / rows.length) * 100) : null,
        avgHours: Math.round(avgHours * 10) / 10,
        rows,
      };
    });
  }, [resolved, policies]);

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
        SLA Performance
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Compliance against target resolution times, based on resolved and closed tickets.
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Grid container spacing={2} sx={{ mb: 3 }}>
        {byPriority.map((p) => (
          <Grid item xs={12} sm={6} md={3} key={p.priority}>
            <Paper sx={{ p: 2 }}>
              <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                <Chip size="small" label={p.priority} color={priorityColor[p.priority]} />
                <Typography variant="caption" color="text.secondary">
                  target {p.target ?? '—'}h
                </Typography>
              </Box>
              {p.total === 0 ? (
                <Typography variant="body2" color="text.secondary">
                  No resolved tickets
                </Typography>
              ) : (
                <>
                  <Typography variant="h5">{p.compliancePct}%</Typography>
                  <Typography variant="caption" color="text.secondary">
                    {p.met}/{p.total} within target · avg {p.avgHours}h
                  </Typography>
                  <LinearProgress
                    variant="determinate"
                    value={p.compliancePct ?? 0}
                    color={p.compliancePct !== null && p.compliancePct < 80 ? 'error' : 'success'}
                    sx={{ mt: 1, height: 6, borderRadius: 3 }}
                  />
                </>
              )}
            </Paper>
          </Grid>
        ))}
      </Grid>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Ticket #</TableCell>
              <TableCell>Subject</TableCell>
              <TableCell>Priority</TableCell>
              <TableCell align="right">Resolution time</TableCell>
              <TableCell align="right">Target</TableCell>
              <TableCell>Result</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {byPriority.flatMap((p) =>
              p.rows.map(({ ticket, hours }) => (
                <TableRow key={ticket.id} hover>
                  <TableCell>{ticket.ticket_number}</TableCell>
                  <TableCell>{ticket.subject}</TableCell>
                  <TableCell>
                    <Chip size="small" label={ticket.priority} color={priorityColor[ticket.priority]} />
                  </TableCell>
                  <TableCell align="right">{Math.round(hours * 10) / 10}h</TableCell>
                  <TableCell align="right">{p.target ?? '—'}h</TableCell>
                  <TableCell>
                    {p.target ? (
                      <Chip
                        size="small"
                        label={hours <= p.target ? 'Met' : 'Breached'}
                        color={hours <= p.target ? 'success' : 'error'}
                      />
                    ) : (
                      '—'
                    )}
                  </TableCell>
                </TableRow>
              ))
            )}
            {resolved.length === 0 && (
              <TableRow>
                <TableCell colSpan={6} align="center">
                  <Typography color="text.secondary" sx={{ py: 2 }}>
                    No resolved or closed tickets yet.
                  </Typography>
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
    </Box>
  );
}