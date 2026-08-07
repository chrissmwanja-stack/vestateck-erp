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
import { Add } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';

interface TicketCategory {
  id: string;
  code: string;
  name: string;
  is_active: boolean;
  created_at: string;
}

export default function TicketCategoriesAdmin() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [categories, setCategories] = useState<TicketCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [newCode, setNewCode] = useState('');
  const [newName, setNewName] = useState('');
  const [creating, setCreating] = useState(false);

  const [editCat, setEditCat] = useState<TicketCategory | null>(null);
  const [editName, setEditName] = useState('');
  const [savingId, setSavingId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, catsRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_ticket_categories'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (catsRes.error) setError(catsRes.error.message);
    else setCategories((catsRes.data as TicketCategory[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const createCategory = async () => {
    if (!newCode.trim() || !newName.trim()) return;
    setCreating(true);
    setError(null);
    const { error } = await supabase.rpc('create_ticket_category', {
      p_code: newCode,
      p_name: newName,
    });
    setCreating(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewOpen(false);
    setNewCode('');
    setNewName('');
    load();
  };

  const openEdit = (c: TicketCategory) => {
    setEditCat(c);
    setEditName(c.name);
  };

  const saveEdit = async () => {
    if (!editCat) return;
    setSavingId(editCat.id);
    setError(null);
    const { error } = await supabase.rpc('update_ticket_category', {
      p_id: editCat.id,
      p_name: editName,
    });
    setSavingId(null);
    if (error) {
      setError(error.message);
      return;
    }
    setEditCat(null);
    load();
  };

  const toggleActive = async (c: TicketCategory) => {
    setSavingId(c.id);
    setError(null);
    const { error } = await supabase.rpc('update_ticket_category', {
      p_id: c.id,
      p_is_active: !c.is_active,
    });
    setSavingId(null);
    if (error) {
      setError(error.message);
      return;
    }
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
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">Ticket Categories</Typography>
          <Typography variant="body2" color="text.secondary">
            Categories used when logging IT support tickets.
          </Typography>
        </Box>
        {isItSupport && (
          <Button variant="contained" startIcon={<Add />} onClick={() => setNewOpen(true)}>
            New category
          </Button>
        )}
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {categories.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No categories yet.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Code</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Status</TableCell>
                {isItSupport && <TableCell align="right">Action</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {categories.map((c) => (
                <TableRow key={c.id} hover>
                  <TableCell>{c.code}</TableCell>
                  <TableCell>{c.name}</TableCell>
                  <TableCell>
                    <Chip size="small" label={c.is_active ? 'Active' : 'Inactive'} color={c.is_active ? 'success' : 'default'} />
                  </TableCell>
                  {isItSupport && (
                    <TableCell align="right">
                      <Button size="small" onClick={() => openEdit(c)} disabled={savingId === c.id}>
                        Rename
                      </Button>
                      <Button size="small" onClick={() => toggleActive(c)} disabled={savingId === c.id}>
                        {c.is_active ? 'Deactivate' : 'Activate'}
                      </Button>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {/* New category */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New ticket category</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Code" value={newCode} onChange={(e) => setNewCode(e.target.value)} fullWidth autoFocus />
          <TextField label="Name" value={newName} onChange={(e) => setNewName(e.target.value)} fullWidth />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createCategory} disabled={creating || !newCode.trim() || !newName.trim()}>
            {creating ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Edit category */}
      <Dialog open={!!editCat} onClose={() => setEditCat(null)} fullWidth maxWidth="sm">
        <DialogTitle>Rename category</DialogTitle>
        <DialogContent sx={{ mt: 1 }}>
          <TextField label="Name" value={editName} onChange={(e) => setEditName(e.target.value)} fullWidth autoFocus />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditCat(null)}>Cancel</Button>
          <Button variant="contained" onClick={saveEdit} disabled={!editName.trim() || savingId === editCat?.id}>
            Save
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}