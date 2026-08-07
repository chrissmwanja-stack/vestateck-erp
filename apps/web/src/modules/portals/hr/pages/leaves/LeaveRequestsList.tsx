import { useEffect, useState } from "react";
import { useLocation } from "react-router-dom";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Employee { id: string; first_name: string; last_name: string; }
interface LeaveType { id: string; name: string; days_per_year: number; }
interface LeaveRequest {
  id: string;
  employee_id: string;
  leave_type_id: string;
  start_date: string;
  end_date: string;
  days: number;
  reason: string | null;
  status: string;
  created_at: string;
  hr_employees?: { first_name: string; last_name: string } | null;
  hr_leave_types?: { name: string } | null;
}

export default function LeaveRequestsList() {
  const { session } = useAuth();
  const location = useLocation();
  const isApprovalsRoute = location.pathname.endsWith("/approvals");
  const [leaves, setLeaves] = useState<LeaveRequest[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [leaveTypes, setLeaveTypes] = useState<LeaveType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ employee_id: "", leave_type_id: "", start_date: "", end_date: "", reason: "" });

  const fetchData = async () => {
    setLoading(true);
    const [leavesRes, empRes, typesRes] = await Promise.all([
      supabase.from("hr_leave_requests").select("*, hr_employees(first_name, last_name), hr_leave_types(name)").order("created_at", { ascending: false }),
      supabase.from("hr_employees").select("id, first_name, last_name").eq("is_active", true).order("first_name"),
      supabase.from("hr_leave_types").select("id, name, days_per_year").eq("is_active", true).order("name"),
    ]);
    if (leavesRes.data) setLeaves(leavesRes.data as LeaveRequest[]);
    if (empRes.data) setEmployees(empRes.data as Employee[]);
    if (typesRes.data) setLeaveTypes(typesRes.data as LeaveType[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const calculateDays = (start: string, end: string) => {
    if (!start || !end) return 0;
    const s = new Date(start).getTime();
    const e = new Date(end).getTime();
    const diff = Math.ceil((e - s) / (1000 * 60 * 60 * 24)) + 1;
    return diff > 0 ? diff : 0;
  };

  const handleSave = async () => {
    if (!form.employee_id || !form.leave_type_id || !form.start_date || !form.end_date) return;
    const days = calculateDays(form.start_date, form.end_date);

    const { data: appUser, error: appUserError } = await supabase
      .from("app_users")
      .select("tenant_id")
      .eq("id", session?.user?.id)
      .single();
    const tenant_id = appUser?.tenant_id;
    if (appUserError || !tenant_id) {
      alert("Could not determine your organization. Please refresh and try again.");
      return;
    }

    const payload: any = {
      employee_id: form.employee_id,
      leave_type_id: form.leave_type_id,
      start_date: form.start_date,
      end_date: form.end_date,
      days,
      reason: form.reason.trim() || null,
      status: "pending",
      tenant_id,
    };

    const { error } = await supabase.from("hr_leave_requests").insert(payload);
    if (error) { alert(error.message); return; }
    setOpen(false);
    setForm({ employee_id: "", leave_type_id: "", start_date: "", end_date: "", reason: "" });
    fetchData();
  };

  const handleDecision = async (id: string, status: 'approved' | 'rejected') => {
    if (!confirm(`Mark leave as ${status}?`)) return;
    const { error } = await supabase.from("hr_leave_requests").update({ status }).eq("id", id);
    if (!error) fetchData();
  };

  const getStatusColor = (s: string) => {
    if (s === 'approved') return 'success';
    if (s === 'rejected') return 'error';
    if (s === 'pending') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  // "Leave Approvals" in the sidebar links to /hr/leaves/approvals, which
  // renders this same list component (no separate approvals page exists).
  // Default the view to pending-only there so the nav item actually shows
  // what needs a decision, instead of the identical full list at
  // /hr/leaves. The New Leave Request action stays available either way --
  // an approver may also need to log one on someone's behalf.
  const visibleLeaves = isApprovalsRoute ? leaves.filter((l) => l.status === "pending") : leaves;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{isApprovalsRoute ? "Leave Approvals" : "Leave Requests"}</Typography>
          <Typography variant="body2" color="text.secondary">
            {isApprovalsRoute
              ? `${visibleLeaves.length} pending requests awaiting a decision.`
              : `${leaves.length} requests. Days auto-calculated from start to end date.`}
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Leave Request</Button>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Employee</TableCell>
                <TableCell>Leave Type</TableCell>
                <TableCell>Start</TableCell>
                <TableCell>End</TableCell>
                <TableCell>Days</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Reason</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {visibleLeaves.length === 0 ? (
                <TableRow><TableCell colSpan={8} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">{isApprovalsRoute ? "Nothing pending right now." : "No leave requests yet. Create first request — needs Employee + Leave Type lookup you built."}</Typography></TableCell></TableRow>
              ) : (
                visibleLeaves.map(l => (
                  <TableRow key={l.id} hover>
                    <TableCell><Typography fontWeight={600}>{l.hr_employees ? `${l.hr_employees.first_name} ${l.hr_employees.last_name}` : "-"}</Typography></TableCell>
                    <TableCell><Chip label={l.hr_leave_types?.name || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell>{new Date(l.start_date).toLocaleDateString()}</TableCell>
                    <TableCell>{new Date(l.end_date).toLocaleDateString()}</TableCell>
                    <TableCell><Chip label={`${l.days} days`} size="small" /></TableCell>
                    <TableCell><Chip label={l.status} size="small" color={getStatusColor(l.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell><Typography variant="body2" color="text.secondary" sx={{ maxWidth: 200, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{l.reason || "-"}</Typography></TableCell>
                    <TableCell align="right">
                      {l.status === "pending" && (
                        <>
                          <Button size="small" color="success" variant="contained" sx={{ mr: 0.5, minWidth: 0, px: 1 }} onClick={() => handleDecision(l.id, 'approved')}>Approve</Button>
                          <Button size="small" color="error" variant="outlined" sx={{ minWidth: 0, px: 1 }} onClick={() => handleDecision(l.id, 'rejected')}>Reject</Button>
                        </>
                      )}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>New Leave Request</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField select label="Employee *" value={form.employee_id} onChange={e => setForm({ ...form, employee_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Employee --</MenuItem>
            {employees.map(emp => <MenuItem key={emp.id} value={emp.id}>{emp.first_name} {emp.last_name}</MenuItem>)}
          </TextField>
          <TextField select label="Leave Type *" value={form.leave_type_id} onChange={e => setForm({ ...form, leave_type_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Type --</MenuItem>
            {leaveTypes.map(t => <MenuItem key={t.id} value={t.id}>{t.name} ({t.days_per_year} days/year)</MenuItem>)}
          </TextField>
          <Grid container spacing={2}>
            <Grid item xs={6}><TextField label="Start Date *" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /></Grid>
            <Grid item xs={6}><TextField label="End Date *" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /></Grid>
          </Grid>
          {form.start_date && form.end_date && <Typography variant="caption" color="text.secondary">Calculated days: {calculateDays(form.start_date, form.end_date)} days (inclusive)</Typography>}
          <TextField label="Reason" value={form.reason} onChange={e => setForm({ ...form, reason: e.target.value })} fullWidth multiline rows={3} placeholder="Reason for leave..." />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.employee_id || !form.leave_type_id || !form.start_date || !form.end_date}>Create Request</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}