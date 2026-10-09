import { useCallback, useEffect, useState } from 'react';
import {
  Box, Button, Card, CardContent, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, MenuItem,
  Stack, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { errorText, rows, table, write } from '../../db';
import type { ProductLine } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Lines of business the agency places (motor, fire, marine, medical, life ...).
// Policies reference these; deactivate rather than delete once they are in use.
export default function ProductLinesAdmin() {
  const [lines, setLines] = useState<ProductLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ code: '', name: '', class: 'general' });

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setLines(await rows<ProductLine>(table('ins_product_lines').select('*').order('name', { ascending: true })));
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
    try {
      await write(table('ins_product_lines').insert({ code: form.code.trim().toUpperCase(), name: form.name.trim(), class: form.class }));
      setOpen(false);
      setForm({ code: '', name: '', class: 'general' });
      await load();
    } catch (e) {
      setError(errorText(e));
    }
  };

  const toggle = async (p: ProductLine) => {
    try {
      await write(table('ins_product_lines').update({ is_active: !p.is_active }).eq('id', p.id));
      await load();
    } catch (e) {
      setError(errorText(e));
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <PageHeader
        title="Product lines"
        subtitle="Classes of insurance the agency places."
        actions={<Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New product line</Button>}
      />
      <ErrorBanner message={error} />
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Code</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Class</TableCell>
                <TableCell>Active</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {lines.length === 0 ? (
                <EmptyRow colSpan={4} text="No product lines yet. Add motor, fire, medical and so on before creating policies." />
              ) : (
                lines.map((p) => (
                  <TableRow key={p.id} hover>
                    <TableCell sx={{ fontFamily: 'monospace' }}>{p.code}</TableCell>
                    <TableCell sx={{ fontWeight: 600 }}>{p.name}</TableCell>
                    <TableCell sx={{ textTransform: 'capitalize' }}>{p.class}</TableCell>
                    <TableCell>
                      <Switch size="small" checked={p.is_active} onChange={() => toggle(p)} inputProps={{ 'aria-label': `Active: ${p.name}` }} />
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} fullWidth maxWidth="xs">
        <DialogTitle>New product line</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Code" required helperText="e.g. MOT, FIRE, MED" value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} />
            <TextField label="Name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <TextField select label="Class" value={form.class} onChange={(e) => setForm({ ...form, class: e.target.value })}>
              <MenuItem value="general">General (non-life)</MenuItem>
              <MenuItem value="life">Life</MenuItem>
              <MenuItem value="health">Health</MenuItem>
            </TextField>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={save} disabled={!form.code.trim() || !form.name.trim()}>Save</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
