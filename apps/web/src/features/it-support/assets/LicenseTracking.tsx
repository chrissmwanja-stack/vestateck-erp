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
  LinearProgress,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';

interface License {
  id: string;
  asset_id: string;
  asset_tag: string;
  asset_name: string;
  license_key: string | null;
  seats_total: number;
  seats_used: number;
  vendor: string | null;
  expiry_date: string | null;
  notes: string | null;
}

interface SoftwareAsset {
  id: string;
  asset_tag: string;
  name: string;
}

function seatColor(used: number, total: number): 'success' | 'warning' | 'error' {
  if (total <= 0) return 'success';
  const ratio = used / total;
  if (ratio >= 1) return 'error';
  if (ratio >= 0.8) return 'warning';
  return 'success';
}

function isExpiringSoon(expiry: string | null): boolean {
  if (!expiry) return false;
  const days = (new Date(expiry).getTime() - Date.now()) / (1000 * 60 * 60 * 24);
  return days >= 0 && days <= 30;
}

function isExpired(expiry: string | null): boolean {
  if (!expiry) return false;
  return new Date(expiry).getTime() < Date.now();
}

export default function LicenseTracking() {
  const [licenses, setLicenses] = useState<License[]>([]);
  const [softwareAssets, setSoftwareAssets] = useState<SoftwareAsset[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [assetId, setAssetId] = useState('');
  const [licenseKey, setLicenseKey] = useState('');
  const [seatsTotal, setSeatsTotal] = useState('1');
  const [vendor, setVendor] = useState('');
  const [expiryDate, setExpiryDate] = useState('');
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);

  const [editLicense, setEditLicense] = useState<License | null>(null);
  const [editSeatsTotal, setEditSeatsTotal] = useState('');
  const [editVendor, setEditVendor] = useState('');
  const [editExpiryDate, setEditExpiryDate] = useState('');
  const [editNotes, setEditNotes] = useState('');
  const [editLicenseKey, setEditLicenseKey] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [licensesRes, assetsRes] = await Promise.all([
      supabase.rpc('get_licenses'),
      supabase.rpc('get_assets', { p_type: 'software' }),
    ]);
    if (licensesRes.error) setError(licensesRes.error.message);
    else setLicenses((licensesRes.data as License[]) ?? []);
    if (!assetsRes.error) setSoftwareAssets((assetsRes.data as SoftwareAsset[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const resetNewForm = () => {
    setAssetId('');
    setLicenseKey('');
    setSeatsTotal('1');
    setVendor('');
    setExpiryDate('');
    setNotes('');
  };

  const createLicense = async () => {
    if (!assetId) return;
    setSaving(true);
    const { error } = await supabase.rpc('create_license', {
      p_asset_id: assetId,
      p_seats_total: Number(seatsTotal) || 1,
      p_license_key: licenseKey || null,
      p_vendor: vendor || null,
      p_expiry_date: expiryDate || null,
      p_notes: notes || null,
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

  const openEdit = (license: License) => {
    setEditLicense(license);
    setEditSeatsTotal(String(license.seats_total));
    setEditVendor(license.vendor ?? '');
    setEditExpiryDate(license.expiry_date ?? '');
    setEditNotes(license.notes ?? '');
    setEditLicenseKey(license.license_key ?? '');
  };

  const saveEdit = async () => {
    if (!editLicense) return;
    setSaving(true);
    const { error } = await supabase.rpc('update_license', {
      p_license_id: editLicense.id,
      p_license_key: editLicenseKey || null,
      p_seats_total: Number(editSeatsTotal) || undefined,
      p_vendor: editVendor || null,
      p_expiry_date: editExpiryDate || null,
      p_notes: editNotes || null,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditLicense(null);
    load();
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">License Tracking</Typography>
          <Typography variant="body2" color="text.secondary">
            Seat counts and license keys for software assets. Add software in Software Inventory first.
          </Typography>
        </Box>
        <Button
          variant="contained"
          startIcon={<Add />}
          onClick={() => setNewOpen(true)}
          disabled={softwareAssets.length === 0}
        >
          New license
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
      ) : licenses.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">
            {softwareAssets.length === 0
              ? 'No software assets yet. Add one in Software Inventory before creating a license.'
              : 'No licenses tracked yet.'}
          </Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Tag</TableCell>
                <TableCell>Software</TableCell>
                <TableCell>Vendor</TableCell>
                <TableCell>Seats</TableCell>
                <TableCell>Expiry</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {licenses.map((l) => (
                <TableRow key={l.id} hover sx={{ cursor: 'pointer' }} onClick={() => openEdit(l)}>
                  <TableCell>{l.asset_tag}</TableCell>
                  <TableCell>{l.asset_name}</TableCell>
                  <TableCell>{l.vendor ?? '—'}</TableCell>
                  <TableCell sx={{ minWidth: 140 }}>
                    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                      <Typography variant="body2">
                        {l.seats_used}/{l.seats_total}
                      </Typography>
                      <Box sx={{ flex: 1 }}>
                        <LinearProgress
                          variant="determinate"
                          value={Math.min(100, (l.seats_used / Math.max(l.seats_total, 1)) * 100)}
                          color={seatColor(l.seats_used, l.seats_total)}
                          sx={{ height: 6, borderRadius: 1 }}
                        />
                      </Box>
                    </Box>
                  </TableCell>
                  <TableCell>
                    {l.expiry_date ? (
                      <Chip
                        size="small"
                        label={l.expiry_date}
                        color={isExpired(l.expiry_date) ? 'error' : isExpiringSoon(l.expiry_date) ? 'warning' : 'default'}
                      />
                    ) : (
                      '—'
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {/* New license */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New license</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField select label="Software asset" value={assetId} onChange={(e) => setAssetId(e.target.value)} fullWidth autoFocus>
            {softwareAssets.map((a) => (
              <MenuItem key={a.id} value={a.id}>
                {a.asset_tag} — {a.name}
              </MenuItem>
            ))}
          </TextField>
          <TextField label="License key" value={licenseKey} onChange={(e) => setLicenseKey(e.target.value)} fullWidth />
          <TextField
            label="Seats"
            type="number"
            value={seatsTotal}
            onChange={(e) => setSeatsTotal(e.target.value)}
            fullWidth
            inputProps={{ min: 1 }}
          />
          <TextField label="Vendor" value={vendor} onChange={(e) => setVendor(e.target.value)} fullWidth />
          <TextField
            label="Expiry date"
            type="date"
            value={expiryDate}
            onChange={(e) => setExpiryDate(e.target.value)}
            fullWidth
            InputLabelProps={{ shrink: true }}
          />
          <TextField label="Notes" value={notes} onChange={(e) => setNotes(e.target.value)} fullWidth multiline minRows={2} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createLicense} disabled={saving || !assetId}>
            {saving ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Edit license */}
      <Dialog open={!!editLicense} onClose={() => setEditLicense(null)} fullWidth maxWidth="sm">
        {editLicense && (
          <>
            <DialogTitle>
              {editLicense.asset_tag} — {editLicense.asset_name}
            </DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              <Alert severity="info">
                {editLicense.seats_used} of {editLicense.seats_total} seats currently in use.
              </Alert>
              <TextField label="License key" value={editLicenseKey} onChange={(e) => setEditLicenseKey(e.target.value)} fullWidth />
              <TextField
                label="Seats"
                type="number"
                value={editSeatsTotal}
                onChange={(e) => setEditSeatsTotal(e.target.value)}
                fullWidth
                inputProps={{ min: editLicense.seats_used }}
                helperText={editLicense.seats_used > 0 ? `Cannot go below ${editLicense.seats_used} seats in use` : undefined}
              />
              <TextField label="Vendor" value={editVendor} onChange={(e) => setEditVendor(e.target.value)} fullWidth />
              <TextField
                label="Expiry date"
                type="date"
                value={editExpiryDate}
                onChange={(e) => setEditExpiryDate(e.target.value)}
                fullWidth
                InputLabelProps={{ shrink: true }}
              />
              <TextField label="Notes" value={editNotes} onChange={(e) => setEditNotes(e.target.value)} fullWidth multiline minRows={2} />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setEditLicense(null)}>Cancel</Button>
              <Button
                variant="contained"
                onClick={saveEdit}
                disabled={saving || Number(editSeatsTotal) < editLicense.seats_used}
              >
                {saving ? 'Saving…' : 'Save'}
              </Button>
            </DialogActions>
          </>
        )}
      </Dialog>
    </Box>
  );
}