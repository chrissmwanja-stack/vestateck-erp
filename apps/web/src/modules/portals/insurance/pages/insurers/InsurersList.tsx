import { useCallback, useEffect, useState } from 'react';
import {
  Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle,
  IconButton, Stack, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Tooltip, Typography,
} from '@mui/material';
import { Add, Edit } from '@mui/icons-material';
import { errorText, rows, table, write } from '../../db';
import { useInsuranceAccess } from '../../access';
import type { Insurer } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

const EMPTY = { code: '', name: '', contact_name: '', contact_email: '', contact_phone: '', default_commission_rate_pct: '0' };

// Insurer masters. Writes are admin/manager only (RLS); members see the list.
export default function InsurersList() {
  const { canManage } = useInsuranceAccess();
  const [insurers, setInsurers] = useState<Insurer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Insurer | 'new' | null>(null);
  const [form, setForm] = useState(EMPTY);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setInsurers(await rows<Insurer>(table('ins_insurers').select('*').order('name', { ascending: true })));
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

  const openNew = () => {
    setForm(EMPTY);
    setEditing('new');
  };
  const openEdit = (i: Insurer) => {
    setForm({
      code: i.code,
      name: i.name,
      contact_name: i.contact_name ?? '',
      contact_email: i.contact_email ?? '',
      contact_phone: i.contact_phone ?? '',
      default_commission_rate_pct: String(i.default_commission_rate_pct),
    });
    setEditing(i);
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    const payload = {
      code: form.code.trim().toUpperCase(),
      name: form.name.trim(),
      contact_name: form.contact_name || null,
      contact_email: form.contact_email || null,
      contact_phone: form.contact_phone || null,
      default_commission_rate_pct: Number(form.default_commission_rate_pct || 0),
    };
    try {
      if (editing === 'new') {
        await write(table('ins_insurers').insert(payload));
      } else if (editing) {
        await write(table('ins_insurers').update(payload).eq('id', editing.id));
      }
      setEditing(null);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  const toggleActive = async (i: Insurer) => {
    try {
      await write(table('ins_insurers').update({ is_active: !i.is_active }).eq('id', i.id));
      await load();
    } catch (e) {
      setError(errorText(e));
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  const commissionValid = Number(form.default_commission_rate_pct) >= 0 && Number(form.default_commission_rate_pct) < 100;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Insurers"
        subtitle="Insurance companies you place business with. Each gets a payable account when its first policy is bound."
        actions={canManage && <Button variant="contained" startIcon={<Add />} onClick={openNew}>New insurer</Button>}
      />
      <ErrorBanner message={error} />
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Code</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Contact</TableCell>
                <TableCell align="right">Default commission</TableCell>
                <TableCell>Status</TableCell>
                {canManage && <TableCell align="right">Edit</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {insurers.length === 0 ? (
                <EmptyRow colSpan={canManage ? 6 : 5} text="No insurers yet." />
              ) : (
                insurers.map((i) => (
                  <TableRow key={i.id} hover>
                    <TableCell><Typography fontFamily="monospace">{i.code}</Typography></TableCell>
                    <TableCell sx={{ fontWeight: 600 }}>{i.name}</TableCell>
                    <TableCell>{i.contact_name ?? '-'}{i.contact_email ? ` · ${i.contact_email}` : ''}</TableCell>
                    <TableCell align="right">{Number(i.default_commission_rate_pct).toFixed(2)}%</TableCell>
                    <TableCell>
                      {canManage ? (
                        <Switch size="small" checked={i.is_active} onChange={() => toggleActive(i)} inputProps={{ 'aria-label': `Active: ${i.name}` }} />
                      ) : (
                        <Chip size="small" label={i.is_active ? 'Active' : 'Inactive'} variant="outlined" />
                      )}
                    </TableCell>
                    {canManage && (
                      <TableCell align="right">
                        <Tooltip title="Edit">
                          <IconButton size="small" aria-label={`Edit ${i.name}`} onClick={() => openEdit(i)}>
                            <Edit fontSize="small" />
                          </IconButton>
                        </Tooltip>
                      </TableCell>
                    )}
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={editing !== null} onClose={() => setEditing(null)} fullWidth maxWidth="sm">
        <DialogTitle>{editing === 'new' ? 'New insurer' : 'Edit insurer'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Code" required helperText="2 to 12 letters, digits, _ or -" value={form.code}
              onChange={(e) => setForm({ ...form, code: e.target.value })} />
            <TextField label="Name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <TextField label="Contact name" value={form.contact_name} onChange={(e) => setForm({ ...form, contact_name: e.target.value })} />
            <TextField label="Contact email" value={form.contact_email} onChange={(e) => setForm({ ...form, contact_email: e.target.value })} />
            <TextField label="Contact phone" value={form.contact_phone} onChange={(e) => setForm({ ...form, contact_phone: e.target.value })} />
            <TextField label="Default commission (%)" type="number" value={form.default_commission_rate_pct}
              error={!commissionValid} helperText="Pre-fills new policies. The policy's own rate is what is used." inputProps={{ min: 0, max: 99.99, step: 0.01 }}
              onChange={(e) => setForm({ ...form, default_commission_rate_pct: e.target.value })} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditing(null)}>Cancel</Button>
          <Button variant="contained" onClick={save} disabled={saving || !form.code.trim() || !form.name.trim() || !commissionValid}>
            {saving ? 'Saving…' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
