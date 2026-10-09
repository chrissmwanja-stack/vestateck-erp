import { useCallback, useEffect, useState } from 'react';
import {
  Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle,
  MenuItem, Table, TableBody, TableCell, TableHead, TableRow, TextField, Stack,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { errorText, rows, rpc, table } from '../../db';
import type { InsClient } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

const EMPTY = { name: '', client_type: 'corporate', tax_id: '', email: '', phone: '', risk_rating: 'medium' };

export default function ClientsList() {
  const [clients, setClients] = useState<InsClient[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState(EMPTY);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setClients(
        await rows<InsClient>(
          // bd_clients is the client master (shared with BD). Insurance adds the profile on top.
          table('ins_clients').select('id, client_id, client_type, tax_id, risk_rating, kyc_status, bd_clients(name, email, phone)').order('created_at', { ascending: false }),
        ),
      );
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      await rpc('ins_register_client', {
        p_name: form.name,
        p_client_type: form.client_type,
        p_tax_id: form.tax_id || null,
        p_email: form.email || null,
        p_phone: form.phone || null,
        p_risk_rating: form.risk_rating,
      });
      setOpen(false);
      setForm(EMPTY);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Clients"
        subtitle={`${clients.length} clients. Shared with the client master in Business Development.`}
        actions={<Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New client</Button>}
      />
      <ErrorBanner message={error} />
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Tax ID</TableCell>
                <TableCell>Contact</TableCell>
                <TableCell>Risk</TableCell>
                <TableCell>KYC</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {clients.length === 0 ? (
                <EmptyRow colSpan={6} text="No clients yet." />
              ) : (
                clients.map((c) => (
                  <TableRow key={c.id} hover>
                    <TableCell sx={{ fontWeight: 600 }}>{c.bd_clients?.name ?? '-'}</TableCell>
                    <TableCell sx={{ textTransform: 'capitalize' }}>{c.client_type}</TableCell>
                    <TableCell>{c.tax_id ?? '-'}</TableCell>
                    <TableCell>{c.bd_clients?.email ?? c.bd_clients?.phone ?? '-'}</TableCell>
                    <TableCell sx={{ textTransform: 'capitalize' }}>{c.risk_rating}</TableCell>
                    <TableCell><Chip size="small" label={c.kyc_status} variant="outlined" /></TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New client</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Client name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <TextField select label="Type" value={form.client_type} onChange={(e) => setForm({ ...form, client_type: e.target.value })}>
              <MenuItem value="corporate">Corporate</MenuItem>
              <MenuItem value="individual">Individual</MenuItem>
            </TextField>
            <TextField label="Tax ID (TIN)" value={form.tax_id} onChange={(e) => setForm({ ...form, tax_id: e.target.value })} />
            <TextField label="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
            <TextField label="Phone" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
            <TextField select label="Risk rating" value={form.risk_rating} onChange={(e) => setForm({ ...form, risk_rating: e.target.value })}>
              <MenuItem value="low">Low</MenuItem>
              <MenuItem value="medium">Medium</MenuItem>
              <MenuItem value="high">High</MenuItem>
            </TextField>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={save} disabled={saving || !form.name.trim()}>
            {saving ? 'Saving…' : 'Save client'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
