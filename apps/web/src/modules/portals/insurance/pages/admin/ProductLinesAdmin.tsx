import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle,
  FormControlLabel, MenuItem, Stack, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Tooltip,
} from '@mui/material';
import { Add } from '@mui/icons-material';
import { errorText, rows, table, write } from '../../db';
import { MOTOR_LINE_CODE, lineNeedsCertificate, looksLikeMotorLine } from '../../risks';
import type { ProductLine } from '../../types';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Lines of business the agency places (motor, fire, marine, medical, life ...).
// Policies reference these; deactivate rather than delete once they are in use.
// A line can require an issued certificate before its policies bind. That is a setting on the
// line, not a guess from its code: a line coded MOTOR always requires one, and any other line
// (for example a motor line the company coded MOT) needs the setting switched on.
const emptyForm = { code: '', name: '', class: 'general', requiresCertificate: false };
export default function ProductLinesAdmin() {
  const [lines, setLines] = useState<ProductLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [turningOff, setTurningOff] = useState<ProductLine | null>(null);

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

  const code = form.code.trim().toUpperCase();
  const formNeedsCertificate = form.requiresCertificate || code === MOTOR_LINE_CODE;

  const save = async () => {
    try {
      await write(table('ins_product_lines').insert({ code, name: form.name.trim(), class: form.class, requires_certificate: formNeedsCertificate }));
      setOpen(false);
      setForm(emptyForm);
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

  const setCertificate = async (p: ProductLine, value: boolean) => {
    try {
      await write(table('ins_product_lines').update({ requires_certificate: value }).eq('id', p.id));
      setTurningOff(null);
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
                <TableCell>Needs certificate</TableCell>
                <TableCell>Active</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {lines.length === 0 ? (
                <EmptyRow colSpan={5} text="No product lines yet. Add motor, fire, medical and so on before creating policies." />
              ) : (
                lines.map((p) => (
                  <TableRow key={p.id} hover>
                    <TableCell sx={{ fontFamily: 'monospace' }}>{p.code}</TableCell>
                    <TableCell sx={{ fontWeight: 600 }}>{p.name}</TableCell>
                    <TableCell sx={{ textTransform: 'capitalize' }}>{p.class}</TableCell>
                    <TableCell>
                      <Tooltip title={p.code === MOTOR_LINE_CODE ? 'A line coded MOTOR always needs a certificate.' : 'Policies on this line cannot be bound until an issued certificate is attached.'}>
                        <span>
                          <Switch
                            size="small"
                            checked={lineNeedsCertificate(p)}
                            disabled={p.code === MOTOR_LINE_CODE}
                            onChange={(e) => (e.target.checked ? setCertificate(p, true) : setTurningOff(p))}
                            inputProps={{ 'aria-label': `Needs certificate: ${p.name}` }}
                          />
                        </span>
                      </Tooltip>
                      {!lineNeedsCertificate(p) && looksLikeMotorLine(p.code, p.name) && (
                        <Chip size="small" color="warning" variant="outlined" label="Looks like motor: check" sx={{ ml: 1 }} />
                      )}
                    </TableCell>
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
            <TextField label="Code" required helperText="e.g. MOTOR, FIRE, MED" value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} />
            <TextField label="Name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <TextField select label="Class" value={form.class} onChange={(e) => setForm({ ...form, class: e.target.value })}>
              <MenuItem value="general">General (non-life)</MenuItem>
              <MenuItem value="life">Life</MenuItem>
              <MenuItem value="health">Health</MenuItem>
            </TextField>
            <FormControlLabel
              control={
                <Switch checked={formNeedsCertificate} disabled={code === MOTOR_LINE_CODE}
                  onChange={(e) => setForm({ ...form, requiresCertificate: e.target.checked })} />
              }
              label="Policies need an issued certificate before binding"
            />
            {code === MOTOR_LINE_CODE && <Alert severity="info">A line coded MOTOR always needs a certificate.</Alert>}
            {!formNeedsCertificate && looksLikeMotorLine(code, form.name) && (
              <Alert severity="warning">
                This looks like motor business. If each policy must carry a motor certificate, switch the setting on. Otherwise policies on this
                line will bind with no certificate and no error.
              </Alert>
            )}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => { setOpen(false); setForm(emptyForm); }}>Cancel</Button>
          <Button variant="contained" onClick={save} disabled={!form.code.trim() || !form.name.trim()}>Save</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={turningOff !== null} onClose={() => setTurningOff(null)} fullWidth maxWidth="xs">
        <DialogTitle>Turn off the certificate requirement?</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {turningOff?.name}: policies on this line will bind without a certificate, and its risks no longer need to be vehicles with a chassis number.
            Certificates already issued stay as they are.
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setTurningOff(null)}>Keep it on</Button>
          <Button color="error" variant="contained" onClick={() => turningOff && setCertificate(turningOff, false)}>Turn off</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
