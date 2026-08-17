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
import { supabase } from '../../../lib/supabaseClient';

interface SlaPolicy {
  id: string;
  priority: 'low' | 'medium' | 'high' | 'urgent';
  target_hours: number;
  description: string | null;
  updated_at: string;
}

const priorityOrder = ['urgent', 'high', 'medium', 'low'];
const priorityColor: Record<string, 'default' | 'warning' | 'error' | 'info'> = {
  urgent: 'error',
  high: 'warning',
  medium: 'info',
  low: 'default',
};

export default function SlaPoliciesAdmin() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [policies, setPolicies] = useState<SlaPolicy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [editPolicy, setEditPolicy] = useState<SlaPolicy | null>(null);
  const [editHours, setEditHours] = useState('');
  const [editDescription, setEditDescription] = useState('');
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, policiesRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_sla_policies'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (policiesRes.error) setError(policiesRes.error.message);
    else {
      const rows = (policiesRes.data as SlaPolicy[]) ?? [];
      rows.sort((a, b) => priorityOrder.indexOf(a.priority) - priorityOrder.indexOf(b.priority));
      setPolicies(rows);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openEdit = (p: SlaPolicy) => {
    setEditPolicy(p);
    setEditHours(String(p.target_hours));
    setEditDescription(p.description ?? '');
  };

  const saveEdit = async () => {
    if (!editPolicy) return;
    const hours = Number(editHours);
    if (!hours || hours <= 0) return;
    setSaving(true);
    setError(null);
    const { error } = await supabase.rpc('upsert_sla_policy', {
      p_priority: editPolicy.priority,
      p_target_hours: hours,
      p_description: editDescription || undefined,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditPolicy(null);
    load();
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
        SLA Policies
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Target resolution time by ticket priority.
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Priority</TableCell>
              <TableCell>Target</TableCell>
              <TableCell>Description</TableCell>
              <TableCell>Last updated</TableCell>
              {isItSupport && <TableCell align="right">Action</TableCell>}
            </TableRow>
          </TableHead>
          <TableBody>
            {policies.map((p) => (
              <TableRow key={p.id} hover>
                <TableCell>
                  <Chip size="small" label={p.priority} color={priorityColor[p.priority]} />
                </TableCell>
                <TableCell>{p.target_hours}h</TableCell>
                <TableCell>{p.description ?? '—'}</TableCell>
                <TableCell>{new Date(p.updated_at).toLocaleDateString()}</TableCell>
                {isItSupport && (
                  <TableCell align="right">
                    <Button size="small" onClick={() => openEdit(p)}>
                      Edit
                    </Button>
                  </TableCell>
                )}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>

      <Dialog open={!!editPolicy} onClose={() => setEditPolicy(null)} fullWidth maxWidth="sm">
        {editPolicy && (
          <>
            <DialogTitle>Edit SLA — {editPolicy.priority}</DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              <TextField
                label="Target hours"
                type="number"
                value={editHours}
                onChange={(e) => setEditHours(e.target.value)}
                fullWidth
                autoFocus
              />
              <TextField
                label="Description"
                value={editDescription}
                onChange={(e) => setEditDescription(e.target.value)}
                fullWidth
                multiline
                minRows={2}
              />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setEditPolicy(null)}>Cancel</Button>
              <Button variant="contained" onClick={saveEdit} disabled={saving || !Number(editHours)}>
                {saving ? 'Saving…' : 'Save'}
              </Button>
            </DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
}