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
  ToggleButton,
  ToggleButtonGroup,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';

interface Assignment {
  id: string;
  asset_id: string;
  asset_tag: string;
  asset_name: string;
  asset_type: 'hardware' | 'software';
  assigned_to: string;
  assigned_to_name: string;
  assigned_by: string | null;
  assigned_at: string;
  returned_at: string | null;
  notes: string | null;
}

interface AvailableAsset {
  id: string;
  asset_tag: string;
  name: string;
  type: 'hardware' | 'software';
  status: string;
}

interface AppUser {
  id: string;
  name: string;
  email: string;
}

export default function AssetAssignments() {
  const [filter, setFilter] = useState<'active' | 'all'>('active');
  const [assignments, setAssignments] = useState<Assignment[]>([]);
  const [availableAssets, setAvailableAssets] = useState<AvailableAsset[]>([]);
  const [users, setUsers] = useState<AppUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [assetId, setAssetId] = useState('');
  const [assignedTo, setAssignedTo] = useState('');
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);

  const [returnTarget, setReturnTarget] = useState<Assignment | null>(null);
  const [returnNotes, setReturnNotes] = useState('');

  const load = useCallback(async (activeOnly: boolean) => {
    setLoading(true);
    setError(null);
    const [assignmentsRes, assetsRes, usersRes] = await Promise.all([
      supabase.rpc('get_asset_assignments', { p_active_only: activeOnly }),
      supabase.rpc('get_assets', { p_type: undefined }),
      supabase.from('app_users').select('id, name, email').order('name'),
    ]);
    if (assignmentsRes.error) setError(assignmentsRes.error.message);
    else setAssignments((assignmentsRes.data as Assignment[]) ?? []);
    if (!assetsRes.error) {
      const inStock = ((assetsRes.data as AvailableAsset[]) ?? []).filter((a) => a.status === 'in_stock');
      setAvailableAssets(inStock);
    }
    if (!usersRes.error) setUsers((usersRes.data as AppUser[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load(filter === 'active');
  }, [load, filter]);

  const resetNewForm = () => {
    setAssetId('');
    setAssignedTo('');
    setNotes('');
  };

  const createAssignment = async () => {
    if (!assetId || !assignedTo) return;
    setSaving(true);
    const { error } = await supabase.rpc('assign_asset', {
      p_asset_id: assetId,
      p_assigned_to: assignedTo,
      p_notes: notes || undefined,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewOpen(false);
    resetNewForm();
    load(filter === 'active');
  };

  const confirmReturn = async () => {
    if (!returnTarget) return;
    setSaving(true);
    const { error } = await supabase.rpc('return_asset', {
      p_assignment_id: returnTarget.id,
      p_notes: returnNotes || undefined,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setReturnTarget(null);
    setReturnNotes('');
    load(filter === 'active');
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">Asset Assignments</Typography>
          <Typography variant="body2" color="text.secondary">
            Check out in-stock assets to employees, and return them when finished.
          </Typography>
        </Box>
        <Box sx={{ display: 'flex', gap: 2, alignItems: 'center' }}>
          <ToggleButtonGroup
            size="small"
            exclusive
            value={filter}
            onChange={(_, v) => v && setFilter(v)}
          >
            <ToggleButton value="active">Active</ToggleButton>
            <ToggleButton value="all">All</ToggleButton>
          </ToggleButtonGroup>
          <Button
            variant="contained"
            startIcon={<Add />}
            onClick={() => setNewOpen(true)}
            disabled={availableAssets.length === 0}
          >
            New assignment
          </Button>
        </Box>
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
      ) : assignments.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">
            {filter === 'active' ? 'No active assignments.' : 'No assignments yet.'}
          </Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Tag</TableCell>
                <TableCell>Asset</TableCell>
                <TableCell>Assigned to</TableCell>
                <TableCell>Assigned</TableCell>
                <TableCell>Returned</TableCell>
                <TableCell align="right">Action</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {assignments.map((a) => (
                <TableRow key={a.id} hover>
                  <TableCell>{a.asset_tag}</TableCell>
                  <TableCell>{a.asset_name}</TableCell>
                  <TableCell>{a.assigned_to_name}</TableCell>
                  <TableCell>{new Date(a.assigned_at).toLocaleDateString()}</TableCell>
                  <TableCell>
                    {a.returned_at ? (
                      <Chip size="small" label={new Date(a.returned_at).toLocaleDateString()} />
                    ) : (
                      <Chip size="small" label="With employee" color="info" />
                    )}
                  </TableCell>
                  <TableCell align="right">
                    {!a.returned_at && (
                      <Button size="small" onClick={() => setReturnTarget(a)}>
                        Return
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {/* New assignment */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New assignment</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField select label="Available asset" value={assetId} onChange={(e) => setAssetId(e.target.value)} fullWidth autoFocus>
            {availableAssets.map((a) => (
              <MenuItem key={a.id} value={a.id}>
                {a.asset_tag} — {a.name} ({a.type})
              </MenuItem>
            ))}
          </TextField>
          <TextField select label="Assign to" value={assignedTo} onChange={(e) => setAssignedTo(e.target.value)} fullWidth>
            {users.map((u) => (
              <MenuItem key={u.id} value={u.id}>
                {u.name} ({u.email})
              </MenuItem>
            ))}
          </TextField>
          <TextField label="Notes" value={notes} onChange={(e) => setNotes(e.target.value)} fullWidth multiline minRows={2} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createAssignment} disabled={saving || !assetId || !assignedTo}>
            {saving ? 'Assigning…' : 'Assign'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Return asset */}
      <Dialog open={!!returnTarget} onClose={() => setReturnTarget(null)} fullWidth maxWidth="sm">
        {returnTarget && (
          <>
            <DialogTitle>
              Return {returnTarget.asset_tag} — {returnTarget.asset_name}
            </DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              <Typography variant="body2" color="text.secondary">
                Currently with {returnTarget.assigned_to_name}. Returning marks the asset back in stock.
              </Typography>
              <TextField
                label="Return notes"
                value={returnNotes}
                onChange={(e) => setReturnNotes(e.target.value)}
                fullWidth
                multiline
                minRows={2}
              />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setReturnTarget(null)}>Cancel</Button>
              <Button variant="contained" onClick={confirmReturn} disabled={saving}>
                {saving ? 'Returning…' : 'Confirm return'}
              </Button>
            </DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
}