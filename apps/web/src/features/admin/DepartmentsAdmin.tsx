import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  MenuItem,
  Paper,
  Stack,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { Add as AddIcon, UploadFile as UploadFileIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';

interface Department {
  id: string;
  name: string;
  parent_department_id: string | null;
  is_active: boolean;
}

interface ParsedDeptRow {
  name: string;
  parentName: string | null;
  is_active: boolean;
}

const emptyForm = { name: '', parent_department_id: '', is_active: true };

// Splits a CSV line respecting quoted commas, e.g. "Engineering, Civil",...
function splitCsvLine(line: string): string[] {
  const cells: string[] = [];
  let current = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i++;
      } else inQuotes = !inQuotes;
    } else if (char === ',' && !inQuotes) {
      cells.push(current);
      current = '';
    } else current += char;
  }
  cells.push(current);
  return cells.map((c) => c.trim());
}

function parseDepartmentsCsv(text: string): ParsedDeptRow[] {
  const lines = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  if (lines.length === 0) return [];
  const looksLikeHeader = /^name$/i.test(splitCsvLine(lines[0])[0] || '');
  const dataLines = looksLikeHeader ? lines.slice(1) : lines;
  return dataLines
    .map((line) => splitCsvLine(line))
    .filter((cells) => (cells[0] || '').trim().length > 0)
    .map((cells) => ({
      name: cells[0].trim(),
      parentName: (cells[1] || '').trim() || null,
      is_active: (cells[2] || '').trim() === '' ? true : /^(true|1|yes|active)$/i.test(cells[2].trim()),
    }));
}

// departments_select_tenant is open to every tenant member (any requester
// needs to see the list to pick their department) -- insert/update/delete
// are open to Finance team members OR any module admin (see
// broaden_departments_write_to_any_module_admin migration), so this screen
// shows the read-only table to everyone and only hides the New/Edit actions
// from users who are neither.
function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;
    Promise.all([
      supabase.rpc('am_i_finance'),
      supabase.rpc('is_any_module_admin'),
    ]).then(([financeResult, moduleAdminResult]) => {
      if (cancelled) return;
      const canWrite =
        (!financeResult.error && Boolean(financeResult.data)) ||
        (!moduleAdminResult.error && Boolean(moduleAdminResult.data));
      setIsFinance(canWrite);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return isFinance;
}

export default function DepartmentsAdmin() {
  const isFinance = useFinanceAccess();
  const { session } = useAuth();
  const [rows, setRows] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<Department | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const [importOpen, setImportOpen] = useState(false);
  const [importText, setImportText] = useState('');
  const [importing, setImporting] = useState(false);
  const [importResult, setImportResult] = useState<{ created: number; skipped: string[]; unresolved: string[] } | null>(null);
  const [importError, setImportError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('departments')
      .select('id, name, parent_department_id, is_active')
      .order('name');
    if (err) setError(err.message);
    else setRows((data ?? []) as Department[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const nameById = useMemo(() => new Map(rows.map((r) => [r.id, r.name])), [rows]);

  const openNew = () => {
    setEditTarget(null);
    setForm(emptyForm);
    setSaveError(null);
    setDialogOpen(true);
  };

  const openEdit = (row: Department) => {
    setEditTarget(row);
    setForm({ name: row.name, parent_department_id: row.parent_department_id ?? '', is_active: row.is_active });
    setSaveError(null);
    setDialogOpen(true);
  };

  const close = () => {
    if (!saving) setDialogOpen(false);
  };

  const save = async () => {
    setSaveError(null);
    if (!form.name.trim()) {
      setSaveError('Name is required.');
      return;
    }
    if (editTarget && form.parent_department_id === editTarget.id) {
      setSaveError('A department cannot be its own parent.');
      return;
    }
    setSaving(true);
    const payload = {
      name: form.name.trim(),
      parent_department_id: form.parent_department_id || null,
      is_active: form.is_active,
    };
    let err;
    if (editTarget) {
      ({ error: err } = await supabase.from('departments').update(payload).eq('id', editTarget.id));
    } else {
      // tenant_id is `uuid NOT NULL` with no column default. A BEFORE
      // INSERT trigger exists, but Postgres coerces insert values to
      // their column type before any row-level trigger runs -- resolve
      // the real tenant_id client-side instead of sending a placeholder.
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setSaving(false);
        setSaveError(tenantResult.error);
        return;
      }
      ({ error: err } = await supabase.from('departments').insert({ ...payload, tenant_id: tenantResult.tenantId }));
    }
    setSaving(false);
    if (err) {
      setSaveError(err.message);
      return;
    }
    setDialogOpen(false);
    load();
  };

  const openImport = () => {
    setImportText('');
    setImportResult(null);
    setImportError(null);
    setImportOpen(true);
  };

  const handleFilePick = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => setImportText(String(reader.result || ''));
    reader.readAsText(file);
  };

  // Multi-pass import: repeatedly inserts whichever pending rows have a
  // resolvable parent (already in the DB, already inserted this run, or no
  // parent at all), so the CSV doesn't need parents listed before children
  // in a strict order -- any order works as long as the hierarchy is
  // eventually resolvable. Rows whose parent name never resolves (typo, or
  // a genuine cycle) are reported back instead of silently dropped.
  const handleImport = async () => {
    setImportError(null);
    const parsed = parseDepartmentsCsv(importText);
    if (parsed.length === 0) {
      setImportError('No rows found. Expected columns: name, parent_department, is_active.');
      return;
    }

    setImporting(true);
    // Resolve once, outside the loop -- every inserted row in this
    // import shares the same tenant_id (the importer's own tenant).
    const tenantResult = await resolveTenantId(session);
    if (!tenantResult.ok) {
      setImporting(false);
      setImportError(tenantResult.error);
      return;
    }
    const nameToId = new Map<string, string>(rows.map((r) => [r.name.trim().toLowerCase(), r.id]));
    const skipped: string[] = [];
    const created: string[] = [];

    let pending = parsed.filter((row) => {
      const key = row.name.toLowerCase();
      if (nameToId.has(key)) {
        skipped.push(`${row.name} (already exists)`);
        return false;
      }
      return true;
    });

    let progress = true;
    while (pending.length > 0 && progress) {
      progress = false;
      const resolvable = pending.filter((row) => !row.parentName || nameToId.has(row.parentName.trim().toLowerCase()));
      if (resolvable.length === 0) break;

      // tenant_id is `uuid NOT NULL` with no column default -- resolved
      // once above, reused for every row in this import.
      const insertPayload = resolvable.map((row) => ({
        name: row.name,
        parent_department_id: row.parentName ? nameToId.get(row.parentName.trim().toLowerCase()) ?? null : null,
        is_active: row.is_active,
        tenant_id: tenantResult.tenantId,
      }));

      const { data, error: err } = await supabase.from('departments').insert(insertPayload).select('id, name');
      if (err) {
        setImporting(false);
        setImportError(err.message);
        return;
      }
      for (const inserted of data ?? []) {
        nameToId.set(inserted.name.trim().toLowerCase(), inserted.id);
        created.push(inserted.name);
      }
      const resolvedNames = new Set(resolvable.map((row) => row.name));
      pending = pending.filter((row) => !resolvedNames.has(row.name));
      progress = true;
    }

    const unresolved = pending.map((row) => `${row.name} (parent "${row.parentName}" not found)`);

    setImporting(false);
    setImportResult({ created: created.length, skipped, unresolved });
    load();
  };

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Departments</Typography>
        {isFinance && (
          <Stack direction="row" spacing={1}>
            <Button variant="outlined" startIcon={<UploadFileIcon />} onClick={openImport}>
              Bulk Import
            </Button>
            <Button variant="contained" startIcon={<AddIcon />} onClick={openNew}>
              New Department
            </Button>
          </Stack>
        )}
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Departments used for request routing and approvals. Everyone in the tenant can see this list; Finance
        and module admins can add or edit.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Paper variant="outlined">
        {loading ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Name</TableCell>
                  <TableCell>Parent Department</TableCell>
                  <TableCell>Status</TableCell>
                  {isFinance && <TableCell align="right">Actions</TableCell>}
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.name}</TableCell>
                    <TableCell>
                      {row.parent_department_id ? nameById.get(row.parent_department_id) ?? '—' : '—'}
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                    </TableCell>
                    {isFinance && (
                      <TableCell align="right">
                        <Button size="small" onClick={() => openEdit(row)}>
                          Edit
                        </Button>
                      </TableCell>
                    )}
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={isFinance ? 4 : 3} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No departments yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>{editTarget ? 'Edit Department' : 'New Department'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Name" fullWidth value={form.name} onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))} />
            <TextField
              select
              label="Parent Department"
              fullWidth
              value={form.parent_department_id}
              onChange={(e) => setForm((v) => ({ ...v, parent_department_id: e.target.value }))}
            >
              <MenuItem value="">None (top-level)</MenuItem>
              {rows
                .filter((r) => !editTarget || r.id !== editTarget.id)
                .map((r) => (
                  <MenuItem key={r.id} value={r.id}>
                    {r.name}
                  </MenuItem>
                ))}
            </TextField>
            <FormControlLabel
              control={<Switch checked={form.is_active} onChange={(e) => setForm((v) => ({ ...v, is_active: e.target.checked }))} />}
              label="Active"
            />
            {saveError && <Alert severity="error">{saveError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={close} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={save} variant="contained" disabled={saving}>
            {saving ? 'Saving…' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={importOpen} onClose={() => setImportOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Bulk Import Departments</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, pt: 2 }}>
          <Typography variant="body2" color="text.secondary">
            CSV with columns <code>name, parent_department, is_active</code> (header row optional; parent_department
            and is_active are optional, is_active defaults to true). Parent departments can appear in any order in
            the file — rows are inserted in passes as their parent becomes resolvable.
          </Typography>
          <Button component="label" variant="outlined" startIcon={<UploadFileIcon />} sx={{ alignSelf: 'flex-start' }}>
            Choose CSV file
            <input type="file" accept=".csv,text/csv" hidden onChange={handleFilePick} />
          </Button>
          <TextField
            label="Or paste CSV here"
            value={importText}
            onChange={(e) => setImportText(e.target.value)}
            fullWidth
            multiline
            rows={8}
            placeholder={'name,parent_department,is_active\nOperations,,true\nEngineering,Operations,true\nFinance,,true'}
          />
          {importError && <Alert severity="error">{importError}</Alert>}
          {importResult && (
            <Alert severity={importResult.skipped.length > 0 || importResult.unresolved.length > 0 ? 'warning' : 'success'}>
              Created {importResult.created} department{importResult.created === 1 ? '' : 's'}.
              {importResult.skipped.length > 0 && <> Skipped {importResult.skipped.length}: {importResult.skipped.join(', ')}.</>}
              {importResult.unresolved.length > 0 && (
                <> Could not resolve {importResult.unresolved.length}: {importResult.unresolved.join(', ')}.</>
              )}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setImportOpen(false)}>Close</Button>
          <Button variant="contained" onClick={handleImport} disabled={importing || !importText.trim()}>
            {importing ? 'Importing…' : 'Import'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}