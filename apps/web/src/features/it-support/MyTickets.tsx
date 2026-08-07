import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
} from "@mui/material";
import { Link as RouterLink } from "react-router-dom";
import { supabase } from "../../lib/supabaseClient";

// My Tickets -- tickets the signed-in user has filed themselves.
// Backed by get_my_tickets(), which scopes to requester_id = auth.uid().

interface Ticket {
  id: string;
  ticket_number: string;
  subject: string;
  category: string;
  priority: string;
  status: string;
  resolution_notes: string | null;
  created_at: string;
  resolved_at: string | null;
  closed_at: string | null;
}

const STATUS_COLOR: Record<string, "default" | "warning" | "info" | "success"> = {
  open: "warning",
  in_progress: "info",
  resolved: "success",
  closed: "default",
};

const PRIORITY_COLOR: Record<string, "default" | "warning" | "error"> = {
  low: "default",
  medium: "default",
  high: "warning",
  urgent: "error",
};

export default function MyTickets() {
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: rpcError } = await supabase.rpc("get_my_tickets");
    if (rpcError) setError(rpcError.message);
    else setTickets((data ?? []) as Ticket[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (error) {
    return (
      <Alert severity="error" sx={{ maxWidth: 640, mx: "auto" }}>
        {error}
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1000, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>
        My tickets
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Tickets you've filed with IT Support.
      </Typography>

      {tickets.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">You haven't filed any tickets yet.</Typography>
          <Button component={RouterLink} to="/it-support/tickets/new" variant="outlined" sx={{ mt: 2 }}>
            New ticket
          </Button>
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Ticket</TableCell>
                <TableCell>Subject</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Priority</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Filed</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {tickets.map((t) => (
                <TableRow key={t.id} hover>
                  <TableCell>
                    <Typography variant="body2" fontWeight={600}>
                      {t.ticket_number}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    <Typography variant="body2">{t.subject}</Typography>
                    {t.status === "resolved" && t.resolution_notes && (
                      <Typography variant="caption" color="text.secondary">
                        {t.resolution_notes}
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell>{t.category}</TableCell>
                  <TableCell>
                    <Chip size="small" label={t.priority} color={PRIORITY_COLOR[t.priority]} variant="outlined" />
                  </TableCell>
                  <TableCell>
                    <Chip size="small" label={t.status.replace("_", " ")} color={STATUS_COLOR[t.status]} />
                  </TableCell>
                  <TableCell>{new Date(t.created_at).toLocaleDateString()}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
}