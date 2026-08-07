import { useCallback, useEffect, useState, FormEvent } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Card,
  CardContent,
  CircularProgress,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { PersonAdd as PersonAddIcon, Delete as DeleteIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface AssigneeRow {
  id: string;
  user_id: string;
  user_name: string;
  assigned_by_name: string;
  created_at: string;
}

interface UserOption {
  id: string;
  label: string;
}

export default function MaterialReceiptAdmin() {
  const [rows, setRows] = useState<AssigneeRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [userOptions, setUserOptions] = useState<UserOption[]>([]);
  const [loadingUsers, setLoadingUsers] = useState(false);
  const [selectedUser, setSelectedUser] = useState<UserOption | null>(null);
  const [assigning, setAssigning] = useState(false);
  const [assignError, setAssignError] = useState<string | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  const loadAssignees = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const { data, error: rpcError } = await supabase.rpc('list_receipt_assignees');
      if (rpcError) throw rpcError;
      setRows((data ?? []) as AssigneeRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load material receipt assignees');
    } finally {
      setLoading(false);
    }
  }, []);

  const loadUsers = useCallback(async () => {
    setLoadingUsers(true);
    try {
      const { data, error: userError } = await supabase
        .from('app_users')
        .select('id, name, email')
        .order('name');
      if (userError) throw userError;
      setUserOptions((data ?? []).map((u) => ({ id: u.id, label: u.email ? `${u.name} — ${u.email}` : u.name })));
    } catch (e) {
      setAssignError(e instanceof Error ? e.message : 'Failed to load users');
    } finally {
      setLoadingUsers(false);
    }
  }, []);

  useEffect(() => {
    loadAssignees();
    loadUsers();
  }, [loadAssignees, loadUsers]);

  async function handleAssign(e: FormEvent) {
    e.preventDefault();
    if (!selectedUser) {
      setAssignError('Pick a user to grant access to.');
      return;
    }
    setAssignError(null);
    setAssigning(true);
    const { error: rpcError } = await supabase.rpc('assign_receipt_access', { p_user_id: selectedUser.id });
    setAssigning(false);

    if (rpcError) {
      setAssignError(rpcError.message ?? 'Could not grant access. Try again.');
      return;
    }

    setSelectedUser(null);
    loadAssignees();
  }

  async function handleRevoke(userId: string) {
    setRevokingId(userId);
    const { error: rpcError } = await supabase.rpc('revoke_receipt_access', { p_user_id: userId });
    setRevokingId(null);

    if (rpcError) {
      setError(rpcError.message ?? 'Could not revoke access. Try again.');
      return;
    }
    loadAssignees();
  }

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Material Receipt Access</Typography>
      </Stack>

      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Users listed here can record goods received against closed requests (Material Quantity screen). Access is
        tenant-scoped and managed by Finance.
      </Typography>

      {/* Grant access */}
      <Card sx={{ mb: 3 }} variant="outlined">
        <CardContent>
          <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
            Grant access
          </Typography>
          <Box component="form" onSubmit={handleAssign}>
            <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} alignItems={{ sm: 'center' }}>
              <Autocomplete
                sx={{ flex: 1, minWidth: 260 }}
                options={userOptions}
                loading={loadingUsers}
                value={selectedUser}
                onChange={(_, option) => setSelectedUser(option)}
                isOptionEqualToValue={(option, value) => option.id === value.id}
                renderInput={(params) => (
                  <TextField
                    {...params}
                    label="User"
                    size="small"
                    InputProps={{
                      ...params.InputProps,
                      endAdornment: (
                        <>
                          {loadingUsers ? <CircularProgress color="inherit" size={16} /> : null}
                          {params.InputProps.endAdornment}
                        </>
                      ),
                    }}
                  />
                )}
              />
              <Button type="submit" variant="contained" startIcon={<PersonAddIcon />} disabled={assigning}>
                {assigning ? 'Granting…' : 'Grant access'}
              </Button>
            </Stack>
            {assignError && (
              <Alert severity="error" sx={{ mt: 2 }}>
                {assignError}
              </Alert>
            )}
          </Box>
        </CardContent>
      </Card>

      {/* Current assignees */}
      <Paper sx={{ p: 2 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
          Current assignees
        </Typography>
        {error && <Alert severity="error">{error}</Alert>}
        {loading ? (
          <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>User</TableCell>
                  <TableCell>Assigned by</TableCell>
                  <TableCell>Assigned on</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.user_name}</TableCell>
                    <TableCell>{row.assigned_by_name}</TableCell>
                    <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      <Button
                        size="small"
                        color="error"
                        startIcon={<DeleteIcon />}
                        disabled={revokingId === row.user_id}
                        onClick={() => handleRevoke(row.user_id)}
                      >
                        {revokingId === row.user_id ? 'Revoking…' : 'Revoke'}
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No one has material receipt access yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>
    </Box>
  );
}