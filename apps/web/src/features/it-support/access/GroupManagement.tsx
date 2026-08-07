import { useEffect, useState, useCallback } from 'react';
import {
  Box,
  Typography,
  Paper,
  List,
  ListItemButton,
  ListItemText,
  Chip,
  Button,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  Alert,
  CircularProgress,
  Divider,
  IconButton,
  Autocomplete,
} from '@mui/material';
import { Add, Close } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';

interface Group {
  id: string;
  name: string;
  description: string | null;
  member_count: number;
  created_at: string;
}

interface Member {
  user_id: string;
  name: string;
  email: string;
  added_at: string;
}

interface AppUserOption {
  id: string;
  name: string;
  email: string;
}

export default function GroupManagement() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [groups, setGroups] = useState<Group[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [selected, setSelected] = useState<Group | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [membersLoading, setMembersLoading] = useState(false);

  const [allUsers, setAllUsers] = useState<AppUserOption[]>([]);
  const [addUserValue, setAddUserValue] = useState<AppUserOption | null>(null);
  const [adding, setAdding] = useState(false);
  const [removingId, setRemovingId] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [newName, setNewName] = useState('');
  const [newDescription, setNewDescription] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, groupsRes, usersRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_groups'),
      supabase.from('app_users').select('id, name, email').order('name'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (groupsRes.error) setError(groupsRes.error.message);
    else setGroups((groupsRes.data as Group[]) ?? []);
    if (!usersRes.error) setAllUsers((usersRes.data as AppUserOption[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const loadMembers = useCallback(async (groupId: string) => {
    setMembersLoading(true);
    const { data, error } = await supabase.rpc('get_group_members', { p_group_id: groupId });
    setMembersLoading(false);
    if (error) {
      setError(error.message);
      return;
    }
    setMembers((data as Member[]) ?? []);
  }, []);

  const openGroup = (g: Group) => {
    setSelected(g);
    setAddUserValue(null);
    loadMembers(g.id);
  };

  const createGroup = async () => {
    if (!newName.trim()) return;
    setCreating(true);
    setError(null);
    const { error } = await supabase.rpc('create_group', {
      p_name: newName,
      p_description: newDescription || null,
    });
    setCreating(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewOpen(false);
    setNewName('');
    setNewDescription('');
    load();
  };

  const addMember = async () => {
    if (!selected || !addUserValue) return;
    setAdding(true);
    setError(null);
    const { error } = await supabase.rpc('add_group_member', {
      p_group_id: selected.id,
      p_user_id: addUserValue.id,
    });
    setAdding(false);
    if (error) {
      setError(error.message);
      return;
    }
    setAddUserValue(null);
    loadMembers(selected.id);
    load();
  };

  const removeMember = async (userId: string) => {
    if (!selected) return;
    setRemovingId(userId);
    setError(null);
    const { error } = await supabase.rpc('remove_group_member', {
      p_group_id: selected.id,
      p_user_id: userId,
    });
    setRemovingId(null);
    if (error) {
      setError(error.message);
      return;
    }
    loadMembers(selected.id);
    load();
  };

  const memberIds = new Set(members.map((m) => m.user_id));
  const availableUsers = allUsers.filter((u) => !memberIds.has(u.id));

  if (loading) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">Group Management</Typography>
          <Typography variant="body2" color="text.secondary">
            {isItSupport
              ? 'Create groups and manage their membership.'
              : 'View groups. Only IT Support can make changes.'}
          </Typography>
        </Box>
        {isItSupport && (
          <Button variant="contained" startIcon={<Add />} onClick={() => setNewOpen(true)}>
            New group
          </Button>
        )}
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {groups.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No groups yet.</Typography>
        </Paper>
      ) : (
        <Paper>
          <List disablePadding>
            {groups.map((g, i) => (
              <Box key={g.id}>
                {i > 0 && <Divider />}
                <ListItemButton onClick={() => openGroup(g)} sx={{ py: 1.5 }}>
                  <ListItemText
                    primary={
                      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                        <Typography variant="subtitle1">{g.name}</Typography>
                        <Chip size="small" variant="outlined" label={`${g.member_count} member${g.member_count === 1 ? '' : 's'}`} />
                      </Box>
                    }
                    secondary={g.description ?? undefined}
                  />
                </ListItemButton>
              </Box>
            ))}
          </List>
        </Paper>
      )}

      {/* Group detail / membership */}
      <Dialog open={!!selected} onClose={() => setSelected(null)} fullWidth maxWidth="sm">
        {selected && (
          <>
            <DialogTitle>{selected.name}</DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              {selected.description && (
                <Typography variant="body2" color="text.secondary">
                  {selected.description}
                </Typography>
              )}

              {isItSupport && (
                <Box sx={{ display: 'flex', gap: 1, alignItems: 'center' }}>
                  <Autocomplete
                    size="small"
                    sx={{ flex: 1 }}
                    options={availableUsers}
                    getOptionLabel={(u) => `${u.name} (${u.email})`}
                    value={addUserValue}
                    onChange={(_, v) => setAddUserValue(v)}
                    renderInput={(params) => <TextField {...params} label="Add member" />}
                  />
                  <Button variant="contained" onClick={addMember} disabled={!addUserValue || adding}>
                    {adding ? 'Adding…' : 'Add'}
                  </Button>
                </Box>
              )}

              {membersLoading ? (
                <Box sx={{ display: 'flex', justifyContent: 'center', py: 2 }}>
                  <CircularProgress size={24} />
                </Box>
              ) : members.length === 0 ? (
                <Typography variant="body2" color="text.secondary">
                  No members yet.
                </Typography>
              ) : (
                <List dense disablePadding>
                  {members.map((m) => (
                    <ListItemButton key={m.user_id} disableRipple sx={{ cursor: 'default' }}>
                      <ListItemText primary={m.name} secondary={m.email} />
                      {isItSupport && (
                        <IconButton
                          size="small"
                          edge="end"
                          onClick={() => removeMember(m.user_id)}
                          disabled={removingId === m.user_id}
                        >
                          <Close fontSize="small" />
                        </IconButton>
                      )}
                    </ListItemButton>
                  ))}
                </List>
              )}
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setSelected(null)}>Close</Button>
            </DialogActions>
          </>
        )}
      </Dialog>

      {/* New group */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New group</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Name" value={newName} onChange={(e) => setNewName(e.target.value)} fullWidth autoFocus />
          <TextField
            label="Description"
            value={newDescription}
            onChange={(e) => setNewDescription(e.target.value)}
            fullWidth
            multiline
            minRows={2}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createGroup} disabled={creating || !newName.trim()}>
            {creating ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}