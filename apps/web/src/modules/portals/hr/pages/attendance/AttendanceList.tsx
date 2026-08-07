import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid, Dialog, DialogActions, DialogContent, DialogTitle } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Employee { id: string; first_name: string; last_name: string; }
interface Attendance { id: string; employee_id: string; attendance_date: string; check_in: string | null; check_out: string | null; status: string; notes: string | null; hr_employees?: { first_name: string; last_name: string } | null; }

export default function AttendanceList() {
  const { session } = useAuth();
  const [attendance, setAttendance] = useState<Attendance[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ employee_id: "", attendance_date: new Date().toISOString().slice(0, 10), check_in: "", check_out: "", status: "present", notes: "" });

  const fetchData = async () => {
    setLoading(true);
    const [attRes, empRes] = await Promise.all([
      supabase.from("hr_attendance").select("*, hr_employees(first_name, last_name)").order("attendance_date", { ascending: false }).limit(100),
      supabase.from("hr_employees").select("id, first_name, last_name").eq("is_active", true).order("first_name"),
    ]);
    if (attRes.data) setAttendance(attRes.data as Attendance[]);
    if (empRes.data) setEmployees(empRes.data as Employee[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.employee_id || !form.attendance_date) return;
    const { data: tenantData } = await supabase.from("hr_employees").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;
    const payload: any = {
      employee_id: form.employee_id,
      attendance_date: form.attendance_date,
      check_in: form.check_in ? new Date(`${form.attendance_date}T${form.check_in}`).toISOString() : null,
      check_out: form.check_out ? new Date(`${form.attendance_date}T${form.check_out}`).toISOString() : null,
      status: form.status,
      notes: form.notes.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    const { error } = await supabase.from("hr_attendance").insert(payload);
    if (error) alert(error.message);
    else { setOpen(false); setForm({ employee_id: "", attendance_date: new Date().toISOString().slice(0, 10), check_in: "", check_out: "", status: "present", notes: "" }); fetchData(); }
  };

  const getStatusColor = (s: string) => {
    if (s === 'present') return 'success';
    if (s === 'absent') return 'error';
    if (s === 'late') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Attendance</Typography><Typography variant="body2" color="text.secondary">{attendance.length} records. Daily check-in/out tracking.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Attendance</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Employee</TableCell><TableCell>Check In</TableCell><TableCell>Check Out</TableCell><TableCell>Status</TableCell><TableCell>Notes</TableCell></TableRow></TableHead><TableBody>{attendance.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No attendance yet. Create daily attendance records.</Typography></TableCell></TableRow> : attendance.map(a => <TableRow key={a.id} hover><TableCell>{new Date(a.attendance_date).toLocaleDateString()}</TableCell><TableCell><Typography fontWeight={600}>{a.hr_employees ? `${a.hr_employees.first_name} ${a.hr_employees.last_name}` : "-"}</Typography></TableCell><TableCell>{a.check_in ? new Date(a.check_in).toLocaleTimeString() : "-"}</TableCell><TableCell>{a.check_out ? new Date(a.check_out).toLocaleTimeString() : "-"}</TableCell><TableCell><Chip label={a.status} size="small" color={getStatusColor(a.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell><Typography variant="body2" color="text.secondary">{a.notes || "-"}</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Attendance</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Employee *" value={form.employee_id} onChange={e => setForm({ ...form, employee_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Employee --</MenuItem>{employees.map(emp => <MenuItem key={emp.id} value={emp.id}>{emp.first_name} {emp.last_name}</MenuItem>)}</TextField><TextField label="Date *" type="date" value={form.attendance_date} onChange={e => setForm({ ...form, attendance_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /><Grid container spacing={2}><Grid item xs={6}><TextField label="Check In" type="time" value={form.check_in} onChange={e => setForm({ ...form, check_in: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={6}><TextField label="Check Out" type="time" value={form.check_out} onChange={e => setForm({ ...form, check_out: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="present">Present</MenuItem><MenuItem value="absent">Absent</MenuItem><MenuItem value="late">Late</MenuItem><MenuItem value="on_leave">On Leave</MenuItem></TextField><TextField label="Notes" value={form.notes} onChange={e => setForm({ ...form, notes: e.target.value })} fullWidth multiline rows={2} /></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.employee_id || !form.attendance_date}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
