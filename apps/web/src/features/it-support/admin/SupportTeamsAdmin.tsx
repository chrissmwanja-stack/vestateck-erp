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
  Switch,
  FormControlLabel,
} from '@mui/material';
import { Add, Close } from '@mui/icons-material';
import { supabase } from '../../../lib/supabaseClient';

interface SupportTeam {
  id: string;
  name: string;
  description: string | null;
  is_active: boolean;
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

export default function SupportTeamsAdmin() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [teams, setTeams] = useState<SupportTeam[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [selected, setSelected] = useState<SupportTeam | null>(null);
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

  const [editingMeta, setEditingMeta] = useState(false);
  const [editName, setEditName] = useState('');
  const [editDescription, setEditDescription] = useState('');
  const [editActive, setEditActive] = useState(true);
  const [savingMeta, setSavingMeta] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, teamsRes, usersRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_support_teams'),
      supabase.from('app_users').select('id, name, email').order('name'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (teamsRes.error) setError(teamsRes.error.message);
    else setTeams((teamsRes.data as SupportTeam[]) ?? []);
    if (!usersRes.error) setAllUsers((usersRes.data as AppUserOption[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const loadMembers = useCallback(async (teamId: string) => {
    setMembersLoading(true);
    const { data, error } = await supabase.rpc('get_support_team_members', { p_team_id: teamId });
    setMembersLoading(false);
    if (error) {
      setError(error.message);
      return;
    }
    setMembers((data as Member[]) ?? []);
  }, []);

  const openTeam = (t: SupportTeam) => {
    setSelected(t);
    setAddUserValue(null);
    setEditingMeta(false);
    loadMembers(t.id);
  };

  const startEditMeta = () => {
    if (!selected) return;
    setEditName(selected.name);
    setEditDescription(selected.description ?? '');
    setEditActive(selected.is_active);
    setEditingMeta(true);
  };

  const saveMeta = async () => {
    if (!selected) return;
    setSavingMeta(true);
    setError(null);
    const { error } = await supabase.rpc('update_support_team', {
      p_id: selected.id,
      p_name: editName,
      p_description: editDescription || undefined,
      p_is_active: editActive,
    });
    setSavingMeta(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditingMeta(false);
    setSelected({ ...selected, name: editName, description: editDescription || null, is_active: editActive });
    load();
  };

  const createTeam = async () => {
    if (!newName.trim()) return;
    setCreating(true);
    setError(null);
    const { error } = await supabase.rpc('create_support_team', {
      p_name: newName,
      p_description: newDescription || undefined,
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
    const { error } = await supabase.rpc('add_support_team_member', {
      p_team_id: selected.id,
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
    const { error } = await supabase.rpc('remove_support_team_member', {
      p_team_id: selected.id,
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
          <Typography variant="h5">Support Teams</Typography>
          <Typography variant="body2" color="text.secondary">
            Teams that tickets and problems can be assigned to.
          </Typography>
        </Box>
        {isItSupport && (
          <Button variant="contained" startIcon={<Add />} onClick={() => setNewOpen(true)}>
            New team
          </Button>
        )}
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {teams.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No support teams yet.</Typography>
        </Paper>
      ) : (
        <Paper>
          <List disablePadding>
            {teams.map((t, i) => (
              <Box key={t.id}>
                {i > 0 && <Divider />}
                <ListItemButton onClick={() => openTeam(t)} sx={{ py: 1.5 }}>
                  <ListItemText
                    primary={
                      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                        <Typography variant="subtitle1">{t.name}</Typography>
                        {!t.is_active && <Chip size="small" label="Inactive" />}
                        <Chip size="small" variant="outlined" label={`${t.member_count} member${t.member_count === 1 ? '' : 's'}`} />
                      </Box>
                    }
                    secondary={t.description ?? undefined}
                  />
                </ListItemButton>
              </Box>
            ))}
          </List>
        </Paper>
      )}

      {/* Team detail / membership */}
      <Dialog open={!!selected} onClose={() => setSelected(null)} fullWidth maxWidth="sm">
        {selected && (
          <>
            <DialogTitle sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              {selected.name}
              {isItSupport && !editingMeta && (
                <Button size="small" onClick={startEditMeta}>
                  Edit team
                </Button>
              )}
            </DialogTitle>
            <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
              {editingMeta ? (
                <>
                  <TextField label="Name" value={editName} onChange={(e) => setEditName(e.target.value)} fullWidth />
                  <TextField
                    label="Description"
                    value={editDescription}
                    onChange={(e) => setEditDescription(e.target.value)}
                    fullWidth
                    multiline
                    minRows={2}
                  />
                  <FormControlLabel
                    control={<Switch checked={editActive} onChange={(e) => setEditActive(e.target.checked)} />}
                    label="Active"
                  />
                  <Box sx={{ display: 'flex', gap: 1 }}>
                    <Button onClick={() => setEditingMeta(false)}>Cancel</Button>
                    <Button variant="contained" onClick={saveMeta} disabled={savingMeta || !editName.trim()}>
                      {savingMeta ? 'Saving…' : 'Save'}
                    </Button>
                  </Box>
                </>
              ) : (
                selected.description && (
                  <Typography variant="body2" color="text.secondary">
                    {selected.description}
                  </Typography>
                )
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

      {/* New team */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New support team</DialogTitle>
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
          <Button variant="contained" onClick={createTeam} disabled={creating || !newName.trim()}>
            {creating ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}