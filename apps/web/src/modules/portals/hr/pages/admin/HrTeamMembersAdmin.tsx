import { useEffect, useState, useCallback } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
  MenuItem,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  CircularProgress,
  Alert,
} from "@mui/material";
import { Add, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

// hr_team_members is a separate authorization tier from staff_roles/
// has_module_role('hr', ...) -- it specifically gates the payroll RPCs
// (create_payroll_run, generate_payroll_items, record_employee_compensation,
// update_payroll_item -- see is_hr_team_member() in the schema). This
// screen is the admin UI for that tier, backed by the
// grant_hr_team_member/revoke_hr_team_member RPCs added in
// 20260821090000_hr_team_and_payroll_approver_admin_rpcs.sql -- before
// that migration there was no write path at all for this table.

interface AppUser {
  id: string;
  name: string | null;
  email: string | null;
}

interface HrTeamMember {
  id: string;
  user_id: string;
  role: string;
  created_at: string;
  user: AppUser | null;
}

export default function HrTeamMembersAdmin() {
  const [isHrAdmin, setIsHrAdmin] = useState(false);
  const [members, setMembers] = useState<HrTeamMember[]>([]);
  const [candidates, setCandidates] = useState<AppUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [addOpen, setAddOpen] = useState(false);
  const [addUserId, setAddUserId] = useState("");
  const [addRole, setAddRole] = useState("member");
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [adminRes, membersRes, usersRes] = await Promise.all([
      supabase.rpc("has_module_role", { p_module: "hr", p_roles: ["admin"] }),
      supabase
        .from("hr_team_members")
        .select("id, user_id, role, created_at, user:app_users!hr_team_members_user_id_fkey(id, name, email)")
        .order("created_at"),
      supabase.from("app_users").select("id, name, email").order("name"),
    ]);
    setIsHrAdmin(Boolean(adminRes.data));
    if (membersRes.error) setError(membersRes.error.message);
    else setMembers((membersRes.data as unknown as HrTeamMember[]) ?? []);
    if (usersRes.data) setCandidates(usersRes.data as AppUser[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openAdd = () => {
    setAddUserId("");
    setAddRole("member");
    setAddOpen(true);
  };

  const submitAdd = async () => {
    if (!addUserId) return;
    setSaving(true);
    setError(null);
    const { error } = await supabase.rpc("grant_hr_team_member", {
      p_user_id: addUserId,
      p_role: addRole,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setAddOpen(false);
    load();
  };

  const remove = async (m: HrTeamMember) => {
    if (!confirm(`Remove ${m.user?.name ?? "this user"} from the HR team?`)) return;
    setError(null);
    const { error } = await supabase.rpc("revoke_hr_team_member", { p_user_id: m.user_id });
    if (error) {
      setError(error.message);
      return;
    }
    load();
  };

  const existingUserIds = new Set(members.map((m) => m.user_id));
  const availableCandidates = candidates.filter((u) => !existingUserIds.has(u.id));

  if (loading) {
    return (
      <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>
            HR Team
          </Typography>
          <Typography variant="body2" color="text.secondary">
            Users who can prepare payroll, generate items, and record employee compensation.
            Separate from the general HR module role.
          </Typography>
        </Box>
        {isHrAdmin && (
          <Button variant="contained" startIcon={<Add />} onClick={openAdd}>
            Add member
          </Button>
        )}
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Email</TableCell>
                <TableCell>Role</TableCell>
                {isHrAdmin && <TableCell align="right">Actions</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {members.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={isHrAdmin ? 4 : 3} sx={{ textAlign: "center", py: 4 }}>
                    <Typography color="text.secondary">No HR team members yet.</Typography>
                  </TableCell>
                </TableRow>
              ) : (
                members.map((m) => (
                  <TableRow key={m.id} hover>
                    <TableCell>{m.user?.name ?? "Unknown user"}</TableCell>
                    <TableCell>{m.user?.email ?? "-"}</TableCell>
                    <TableCell>{m.role}</TableCell>
                    {isHrAdmin && (
                      <TableCell align="right">
                        <IconButton size="small" onClick={() => remove(m)}>
                          <Delete fontSize="small" />
                        </IconButton>
                      </TableCell>
                    )}
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={addOpen} onClose={() => setAddOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Add HR team member</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField
            select
            label="User"
            value={addUserId}
            onChange={(e) => setAddUserId(e.target.value)}
            fullWidth
            autoFocus
          >
            {availableCandidates.length === 0 ? (
              <MenuItem disabled value="">
                No eligible users
              </MenuItem>
            ) : (
              availableCandidates.map((u) => (
                <MenuItem key={u.id} value={u.id}>
                  {u.name ?? u.email ?? u.id}
                </MenuItem>
              ))
            )}
          </TextField>
          <TextField label="Role" value={addRole} onChange={(e) => setAddRole(e.target.value)} fullWidth helperText="Free text, e.g. member, lead" />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAddOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={submitAdd} disabled={!addUserId || saving}>
            {saving ? "Adding…" : "Add"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}