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

interface PriorityLevel {
  id: string;
  code: 'low' | 'medium' | 'high' | 'urgent';
  label: string;
  color: string;
  sort_order: number;
}

export default function PriorityLevelsAdmin() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [levels, setLevels] = useState<PriorityLevel[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [editLevel, setEditLevel] = useState<PriorityLevel | null>(null);
  const [editLabel, setEditLabel] = useState('');
  const [editColor, setEditColor] = useState('#757575');
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, levelsRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_priority_levels'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (levelsRes.error) setError(levelsRes.error.message);
    else {
      const rows = (levelsRes.data as PriorityLevel[]) ?? [];
      rows.sort((a, b) => a.sort_order - b.sort_order);
      setLevels(rows);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openEdit = (l: PriorityLevel) => {
    setEditLevel(l);
    setEditLabel(l.label);
    setEditColor(l.color);
  };

  const saveEdit = async () => {
    if (!editLevel) return;
    setSaving(true);
    setError(null);
    const { error } = await supabase.rpc('update_priority_level', {
      p_code: editLevel.code,
      p_label: editLabel || undefined,
      p_color: editColor || undefined,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditLevel(null);
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
        Priority Levels
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Display label and color for each ticket priority.
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
              <TableCell>Code</TableCell>
              <TableCell>Preview</TableCell>
              <TableCell>Label</TableCell>
              <TableCell>Color</TableCell>
              {isItSupport && <TableCell align="right">Action</TableCell>}
            </TableRow>
          </TableHead>
          <TableBody>
            {levels.map((l) => (
              <TableRow key={l.id} hover>
                <TableCell>{l.code}</TableCell>
                <TableCell>
                  <Chip size="small" label={l.label} sx={{ bgcolor: l.color, color: '#fff' }} />
                </TableCell>
                <TableCell>{l.label}</TableCell>
                <TableCell>{l.color}</TableCell>
                {isItSupport && (
                  <TableCell align="right">
                    <Button size="small" onClick={() => openEdit(l)}>
                      Edit
                    </Button>
                  </TableCell>
                )}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>

      <Dialog open={!!editLevel} onClose={() => setEditLevel(null)} fullWidth maxWidth="sm">
        {editLevel && (
          <>
            <DialogTitle>Edit priority — {editLevel.code}</DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              <TextField label="Label" value={editLabel} onChange={(e) => setEditLabel(e.target.value)} fullWidth autoFocus />
              <TextField
                label="Color"
                type="color"
                value={editColor}
                onChange={(e) => setEditColor(e.target.value)}
                sx={{ width: 120 }}
              />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setEditLevel(null)}>Cancel</Button>
              <Button variant="contained" onClick={saveEdit} disabled={saving || !editLabel.trim()}>
                {saving ? 'Saving…' : 'Save'}
              </Button>
            </DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
}