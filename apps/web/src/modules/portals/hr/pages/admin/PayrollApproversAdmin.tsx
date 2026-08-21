import { useEffect, useState, useCallback } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
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
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

// payroll_approvers gates approve_payroll_run/reject_payroll_run (see
// is_payroll_approver() in the schema) -- distinct from hr_team_members,
// which gates preparing/editing a run. Writes go through
// grant_payroll_approver/set_payroll_approver_active
// (20260821090000_hr_team_and_payroll_approver_admin_rpcs.sql).
// Deactivating (rather than deleting) preserves the audit trail, since
// is_active is what is_payroll_approver() actually checks.

interface AppUser {
  id: string;
  name: string | null;
  email: string | null;
}

interface PayrollApprover {
  id: string;
  user_id: string;
  role: string;
  is_active: boolean;
  created_at: string;
  user: AppUser | null;
}

export default function PayrollApproversAdmin() {
  const [isHrAdmin, setIsHrAdmin] = useState(false);
  const [approvers, setApprovers] = useState<PayrollApprover[]>([]);
  const [candidates, setCandidates] = useState<AppUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [addOpen, setAddOpen] = useState(false);
  const [addUserId, setAddUserId] = useState("");
  const [saving, setSaving] = useState(false);
  const [togglingId, setTogglingId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [adminRes, approversRes, usersRes] = await Promise.all([
      supabase.rpc("has_module_role", { p_module: "hr", p_roles: ["admin"] }),
      supabase
        .from("payroll_approvers")
        .select("id, user_id, role, is_active, created_at, user:app_users!payroll_approvers_user_id_fkey(id, name, email)")
        .order("created_at"),
      supabase.from("app_users").select("id, name, email").order("name"),
    ]);
    setIsHrAdmin(Boolean(adminRes.data));
    if (approversRes.error) setError(approversRes.error.message);
    else setApprovers((approversRes.data as unknown as PayrollApprover[]) ?? []);
    if (usersRes.data) setCandidates(usersRes.data as AppUser[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openAdd = () => {
    setAddUserId("");
    setAddOpen(true);
  };

  const submitAdd = async () => {
    if (!addUserId) return;
    setSaving(true);
    setError(null);
    const { error } = await supabase.rpc("grant_payroll_approver", { p_user_id: addUserId });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setAddOpen(false);
    load();
  };

  const toggleActive = async (a: PayrollApprover) => {
    setTogglingId(a.id);
    setError(null);
    const { error } = await supabase.rpc("set_payroll_approver_active", {
      p_user_id: a.user_id,
      p_is_active: !a.is_active,
    });
    setTogglingId(null);
    if (error) {
      setError(error.message);
      return;
    }
    load();
  };

  // Active approvers can't be re-added; a deactivated one shows up again
  // so re-adding via grant_payroll_approver (which reactivates) still works.
  const activeUserIds = new Set(approvers.filter((a) => a.is_active).map((a) => a.user_id));
  const availableCandidates = candidates.filter((u) => !activeUserIds.has(u.id));

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
            Payroll Approvers
          </Typography>
          <Typography variant="body2" color="text.secondary">
            Users who can approve or reject submitted payroll runs.
          </Typography>
        </Box>
        {isHrAdmin && (
          <Button variant="contained" startIcon={<Add />} onClick={openAdd}>
            Add approver
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
                <TableCell>Status</TableCell>
                {isHrAdmin && <TableCell align="right">Actions</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {approvers.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={isHrAdmin ? 4 : 3} sx={{ textAlign: "center", py: 4 }}>
                    <Typography color="text.secondary">No payroll approvers yet.</Typography>
                  </TableCell>
                </TableRow>
              ) : (
                approvers.map((a) => (
                  <TableRow key={a.id} hover>
                    <TableCell>{a.user?.name ?? "Unknown user"}</TableCell>
                    <TableCell>{a.user?.email ?? "-"}</TableCell>
                    <TableCell>
                      <Chip size="small" label={a.is_active ? "Active" : "Inactive"} color={a.is_active ? "success" : "default"} />
                    </TableCell>
                    {isHrAdmin && (
                      <TableCell align="right">
                        <Button size="small" onClick={() => toggleActive(a)} disabled={togglingId === a.id}>
                          {a.is_active ? "Deactivate" : "Reactivate"}
                        </Button>
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
        <DialogTitle>Add payroll approver</DialogTitle>
        <DialogContent sx={{ pt: 2 }}>
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