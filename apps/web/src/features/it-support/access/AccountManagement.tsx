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
  InputAdornment,
  Switch,
  FormControlLabel,
} from '@mui/material';
import { Search } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';

interface Department {
  id: string;
  name: string;
}

interface AppUser {
  id: string;
  name: string;
  email: string;
  role_title: string | null;
  is_platform_admin: boolean;
  department_id: string | null;
  department_name: string | null;
}

export default function AccountManagement() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [isPlatformAdmin, setIsPlatformAdmin] = useState(false);
  const [users, setUsers] = useState<AppUser[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');

  const [editUser, setEditUser] = useState<AppUser | null>(null);
  const [editDepartmentId, setEditDepartmentId] = useState('');
  const [editRoleTitle, setEditRoleTitle] = useState('');
  const [editIsPlatformAdmin, setEditIsPlatformAdmin] = useState(false);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, adminRes, usersRes, deptRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('is_platform_admin'),
      supabase
        .from('app_users')
        .select('id, name, email, role_title, is_platform_admin, department_id, departments(name)')
        .order('name'),
      supabase.from('departments').select('id, name').eq('is_active', true).order('name'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    setIsPlatformAdmin(Boolean(adminRes.data));
    if (usersRes.error) {
      setError(usersRes.error.message);
    } else {
      const rows = (usersRes.data as any[]).map((u) => ({
        id: u.id,
        name: u.name,
        email: u.email,
        role_title: u.role_title,
        is_platform_admin: u.is_platform_admin,
        department_id: u.department_id,
        department_name: u.departments?.name ?? null,
      }));
      setUsers(rows);
    }
    if (deptRes.error) setError((prev) => prev ?? deptRes.error.message);
    else setDepartments((deptRes.data as Department[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openEdit = (u: AppUser) => {
    setEditUser(u);
    setEditDepartmentId(u.department_id ?? '');
    setEditRoleTitle(u.role_title ?? '');
    setEditIsPlatformAdmin(u.is_platform_admin);
  };

  const saveEdit = async () => {
    if (!editUser) return;
    setSaving(true);
    setError(null);
    const { error } = await supabase.rpc('update_app_user', {
      p_user_id: editUser.id,
      p_department_id: editDepartmentId || null,
      p_role_title: editRoleTitle || null,
      // Only pass a platform-admin change if the caller is actually allowed to make one;
      // the RPC rejects a non-null value from a non-platform-admin caller outright.
      p_is_platform_admin: isPlatformAdmin ? editIsPlatformAdmin : null,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditUser(null);
    load();
  };

  const filtered = users.filter(
    (u) =>
      !search ||
      u.name.toLowerCase().includes(search.toLowerCase()) ||
      u.email.toLowerCase().includes(search.toLowerCase()) ||
      (u.department_name ?? '').toLowerCase().includes(search.toLowerCase())
  );

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
        Account Management
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        {isItSupport
          ? 'View and manage user accounts, departments, and roles.'
          : 'View user accounts. Only IT Support can make changes.'}
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <TextField
        size="small"
        placeholder="Search by name, email, or department…"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        sx={{ mb: 2, width: 340 }}
        InputProps={{
          startAdornment: (
            <InputAdornment position="start">
              <Search fontSize="small" />
            </InputAdornment>
          ),
        }}
      />

      {filtered.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No accounts found.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Email</TableCell>
                <TableCell>Department</TableCell>
                <TableCell>Role title</TableCell>
                <TableCell>Platform admin</TableCell>
                {isItSupport && <TableCell align="right">Action</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.map((u) => (
                <TableRow key={u.id} hover>
                  <TableCell>{u.name}</TableCell>
                  <TableCell>{u.email}</TableCell>
                  <TableCell>{u.department_name ?? '—'}</TableCell>
                  <TableCell>{u.role_title ?? '—'}</TableCell>
                  <TableCell>
                    {u.is_platform_admin ? <Chip size="small" color="primary" label="Admin" /> : '—'}
                  </TableCell>
                  {isItSupport && (
                    <TableCell align="right">
                      <Button size="small" onClick={() => openEdit(u)}>
                        Edit
                      </Button>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Dialog open={!!editUser} onClose={() => setEditUser(null)} fullWidth maxWidth="sm">
        {editUser && (
          <>
            <DialogTitle>Edit account — {editUser.name}</DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              <TextField
                select
                label="Department"
                value={editDepartmentId}
                onChange={(e) => setEditDepartmentId(e.target.value)}
                fullWidth
              >
                <MenuItem value="">
                  <em>Unassigned</em>
                </MenuItem>
                {departments.map((d) => (
                  <MenuItem key={d.id} value={d.id}>
                    {d.name}
                  </MenuItem>
                ))}
              </TextField>
              <TextField
                label="Role title"
                value={editRoleTitle}
                onChange={(e) => setEditRoleTitle(e.target.value)}
                fullWidth
              />
              <FormControlLabel
                control={
                  <Switch
                    checked={editIsPlatformAdmin}
                    onChange={(e) => setEditIsPlatformAdmin(e.target.checked)}
                    disabled={!isPlatformAdmin}
                  />
                }
                label={
                  isPlatformAdmin
                    ? 'Platform admin'
                    : 'Platform admin (only a platform admin can change this)'
                }
              />
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setEditUser(null)}>Cancel</Button>
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