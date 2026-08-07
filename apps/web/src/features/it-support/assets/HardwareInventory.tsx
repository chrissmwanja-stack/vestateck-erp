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
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';

interface Asset {
  id: string;
  asset_tag: string;
  type: 'hardware' | 'software';
  name: string;
  category: string | null;
  serial_number: string | null;
  vendor: string | null;
  purchase_cost: number | null;
  status: 'in_stock' | 'assigned' | 'maintenance' | 'retired';
  notes: string | null;
}

const statusColor: Record<Asset['status'], 'success' | 'info' | 'warning' | 'default'> = {
  in_stock: 'success',
  assigned: 'info',
  maintenance: 'warning',
  retired: 'default',
};

export default function HardwareInventory() {
  const [assets, setAssets] = useState<Asset[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [name, setName] = useState('');
  const [category, setCategory] = useState('');
  const [serialNumber, setSerialNumber] = useState('');
  const [vendor, setVendor] = useState('');
  const [purchaseCost, setPurchaseCost] = useState('');
  const [saving, setSaving] = useState(false);

  const [editAsset, setEditAsset] = useState<Asset | null>(null);
  const [editStatus, setEditStatus] = useState<'in_stock' | 'maintenance' | 'retired'>('in_stock');
  const [editNotes, setEditNotes] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error } = await supabase.rpc('get_assets', { p_type: 'hardware' });
    if (error) setError(error.message);
    else setAssets((data as Asset[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const resetNewForm = () => {
    setName('');
    setCategory('');
    setSerialNumber('');
    setVendor('');
    setPurchaseCost('');
  };

  const createAsset = async () => {
    if (!name.trim()) return;
    setSaving(true);
    const { error } = await supabase.rpc('create_asset', {
      p_type: 'hardware',
      p_name: name,
      p_category: category || null,
      p_serial_number: serialNumber || null,
      p_vendor: vendor || null,
      p_purchase_cost: purchaseCost ? Number(purchaseCost) : null,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewOpen(false);
    resetNewForm();
    load();
  };

  const openEdit = (asset: Asset) => {
    setEditAsset(asset);
    setEditStatus(asset.status === 'assigned' ? 'in_stock' : asset.status);
    setEditNotes(asset.notes ?? '');
  };

  const saveEdit = async () => {
    if (!editAsset) return;
    setSaving(true);
    const { error } = await supabase.rpc('update_asset', {
      p_asset_id: editAsset.id,
      p_status: editAsset.status === 'assigned' ? null : editStatus,
      p_notes: editNotes || null,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditAsset(null);
    load();
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">Hardware Inventory</Typography>
          <Typography variant="body2" color="text.secondary">
            Laptops, monitors, and other physical equipment. Use Asset Assignments to check items out.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setNewOpen(true)}>
          New asset
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
      ) : assets.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No hardware assets yet.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Tag</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Serial</TableCell>
                <TableCell>Vendor</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {assets.map((a) => (
                <TableRow key={a.id} hover sx={{ cursor: 'pointer' }} onClick={() => openEdit(a)}>
                  <TableCell>{a.asset_tag}</TableCell>
                  <TableCell>{a.name}</TableCell>
                  <TableCell>{a.category ?? '—'}</TableCell>
                  <TableCell>{a.serial_number ?? '—'}</TableCell>
                  <TableCell>{a.vendor ?? '—'}</TableCell>
                  <TableCell>
                    <Chip size="small" label={a.status.replace('_', ' ')} color={statusColor[a.status]} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {/* New asset */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New hardware asset</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Name" value={name} onChange={(e) => setName(e.target.value)} fullWidth autoFocus />
          <TextField
            label="Category"
            placeholder="Laptop, Monitor, Printer…"
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            fullWidth
          />
          <TextField label="Serial number" value={serialNumber} onChange={(e) => setSerialNumber(e.target.value)} fullWidth />
          <TextField label="Vendor" value={vendor} onChange={(e) => setVendor(e.target.value)} fullWidth />
          <TextField
            label="Purchase cost"
            type="number"
            value={purchaseCost}
            onChange={(e) => setPurchaseCost(e.target.value)}
            fullWidth
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createAsset} disabled={saving || !name.trim()}>
            {saving ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Edit asset */}
      <Dialog open={!!editAsset} onClose={() => setEditAsset(null)} fullWidth maxWidth="sm">
        {editAsset && (
          <>
            <DialogTitle>
              {editAsset.asset_tag} — {editAsset.name}
            </DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              {editAsset.status === 'assigned' ? (
                <Alert severity="info">
                  Currently assigned. Return it from Asset Assignments before changing status.
                </Alert>
              ) : (
                <TextField
                  select
                  label="Status"
                  value={editStatus}
                  onChange={(e) => setEditStatus(e.target.value as typeof editStatus)}
                  fullWidth
                >
                  {(['in_stock', 'maintenance', 'retired'] as const).map((s) => (
                    <MenuItem key={s} value={s}>
                      {s.replace('_', ' ')}
                    </MenuItem>
                  ))}
                </TextField>
              )}
              <TextField
                label="Notes"
                value={editNotes}
                onChange={(e) => setEditNotes(e.target.value)}
                fullWidth
                multiline
                minRows={2}
              />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setEditAsset(null)}>Cancel</Button>
              <Button variant="contained" onClick={saveEdit} disabled={saving}>
                {saving ? 'Saving…' : 'Save'}
              </Button>
            </DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
}