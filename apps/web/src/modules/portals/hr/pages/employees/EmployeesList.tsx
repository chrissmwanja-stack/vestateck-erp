import { useEffect, useState } from "react";
import { useLocation } from "react-router-dom";
import {
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  MenuItem,
  Grid,
} from "@mui/material";
import { Add, Edit, Delete, Badge } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Position { id: string; title: string; }
interface Department { id: string; name: string; }
interface Employee {
  id: string;
  tenant_id: string;
  employee_no: string;
  first_name: string;
  last_name: string;
  email: string;
  phone: string | null;
  department_id: string | null;
  position_id: string | null;
  employment_status: string;
  is_active: boolean;
  created_at: string;
  departments?: { name: string } | null;
  hr_positions?: { title: string } | null;
}

export default function EmployeesList() {
  const { session } = useAuth();
  const location = useLocation();
  const isNewRoute = location.pathname.endsWith("/new");
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [positions, setPositions] = useState<Position[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Employee | null>(null);
  const [form, setForm] = useState({
    first_name: "",
    last_name: "",
    email: "",
    phone: "",
    department_id: "",
    position_id: "",
    employment_status: "active",
    hire_date: "",
    is_active: true,
  });

  const fetchData = async () => {
    setLoading(true);
    const [empRes, posRes, deptRes] = await Promise.all([
      supabase.from("hr_employees").select("*, departments(name), hr_positions(title)").order("created_at", { ascending: false }),
      supabase.from("hr_positions").select("id, title").eq("is_active", true).order("title"),
      supabase.from("departments").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (empRes.error) console.error("Failed to load employees:", empRes.error.message);
    if (empRes.data) setEmployees(empRes.data as Employee[]);
    if (posRes.data) setPositions(posRes.data as Position[]);
    if (deptRes.data) setDepartments(deptRes.data as Department[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  // "New Employee" in the sidebar links to /hr/employees/new, which
  // renders this same list component (no separate create page exists --
  // creation is dialog-based). Auto-open that dialog on arrival so the
  // nav item actually lands the user in create mode, instead of just
  // showing the same list as /hr/employees.
  useEffect(() => {
    if (isNewRoute && !loading) {
      handleOpenNew();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNewRoute, loading]);

  const handleOpenNew = () => {
    setEditing(null);
    setForm({ first_name: "", last_name: "", email: "", phone: "", department_id: "", position_id: "", employment_status: "active", hire_date: "", is_active: true });
    setOpen(true);
  };

  const handleOpenEdit = (e: Employee) => {
    setEditing(e);
    setForm({
      first_name: e.first_name,
      last_name: e.last_name,
      email: e.email,
      phone: e.phone || "",
      department_id: e.department_id || "",
      position_id: e.position_id || "",
      employment_status: e.employment_status,
      hire_date: "",
      is_active: e.is_active,
    });
    setOpen(true);
  };

  const handleSave = async () => {
    if (!form.first_name.trim() || !form.last_name.trim() || !form.email.trim()) return;

    const { data: appUser, error: appUserError } = await supabase
      .from("app_users")
      .select("tenant_id")
      .eq("id", session?.user?.id)
      .single();
    const tenant_id = appUser?.tenant_id;
    if (!editing && (appUserError || !tenant_id)) {
      alert("Could not determine your organization. Please refresh and try again.");
      return;
    }

    const payload: any = {
      first_name: form.first_name.trim(),
      last_name: form.last_name.trim(),
      email: form.email.trim(),
      phone: form.phone.trim() || null,
      department_id: form.department_id || null,
      position_id: form.position_id || null,
      employment_status: form.employment_status,
      hire_date: form.hire_date || null,
      is_active: form.is_active,
    };
    if (!editing && tenant_id) payload.tenant_id = tenant_id;

    if (editing) {
      const { error } = await supabase.from("hr_employees").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const { error } = await supabase.from("hr_employees").insert(payload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete employee? Leave requests and attendance linked will be deleted via cascade.")) return;
    const { error } = await supabase.from("hr_employees").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`); else fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Employees</Typography>
          <Typography variant="body2" color="text.secondary">{employees.length} employees. Employee No auto HR-EMP-2026-0001. Positions lookup from Admin → Positions.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Employee</Button>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Employee No</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Email</TableCell>
                <TableCell>Department</TableCell>
                <TableCell>Position</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Active</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {employees.length === 0 ? (
                <TableRow><TableCell colSpan={8} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No employees yet. Create first employee — needs Position lookup you just built.</Typography></TableCell></TableRow>
              ) : (
                employees.map(e => (
                  <TableRow key={e.id} hover>
                    <TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{e.employee_no}</Typography></TableCell>
                    <TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Badge fontSize="small" color="action" /><Typography fontWeight={600}>{e.first_name} {e.last_name}</Typography></Box></TableCell>
                    <TableCell><Typography variant="body2">{e.email}</Typography><Typography variant="caption" color="text.secondary">{e.phone || ""}</Typography></TableCell>
                    <TableCell>{e.departments?.name || "-"}</TableCell>
                    <TableCell><Chip label={e.hr_positions?.title || "-"} size="small" variant="outlined" /></TableCell>
                    <TableCell><Chip label={e.employment_status} size="small" color={e.employment_status === 'active' ? 'success' : e.employment_status === 'on_leave' ? 'warning' : 'default'} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell><Chip label={e.is_active ? "Active" : "Inactive"} size="small" color={e.is_active ? "success" : "default"} /></TableCell>
                    <TableCell align="right">
                      <IconButton size="small" onClick={() => handleOpenEdit(e)}><Edit fontSize="small" /></IconButton>
                      <IconButton size="small" onClick={() => handleDelete(e.id)}><Delete fontSize="small" /></IconButton>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Employee" : "New Employee"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <Grid container spacing={2}>
            <Grid item xs={6}><TextField label="First Name *" value={form.first_name} onChange={e => setForm({ ...form, first_name: e.target.value })} fullWidth autoFocus /></Grid>
            <Grid item xs={6}><TextField label="Last Name *" value={form.last_name} onChange={e => setForm({ ...form, last_name: e.target.value })} fullWidth /></Grid>
          </Grid>
          <TextField label="Email *" type="email" value={form.email} onChange={e => setForm({ ...form, email: e.target.value })} fullWidth />
          <TextField label="Phone" value={form.phone} onChange={e => setForm({ ...form, phone: e.target.value })} fullWidth />
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField select label="Department" value={form.department_id} onChange={e => setForm({ ...form, department_id: e.target.value })} fullWidth>
                <MenuItem value="">-- None --</MenuItem>
                {departments.map(d => <MenuItem key={d.id} value={d.id}>{d.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={6}>
              <TextField select label="Position" value={form.position_id} onChange={e => setForm({ ...form, position_id: e.target.value })} fullWidth helperText={`${positions.length} positions from Admin`}>
                <MenuItem value="">-- None --</MenuItem>
                {positions.map(p => <MenuItem key={p.id} value={p.id}>{p.title}</MenuItem>)}
              </TextField>
            </Grid>
          </Grid>
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField select label="Employment Status" value={form.employment_status} onChange={e => setForm({ ...form, employment_status: e.target.value })} fullWidth>
                <MenuItem value="active">Active</MenuItem>
                <MenuItem value="on_leave">On Leave</MenuItem>
                <MenuItem value="terminated">Terminated</MenuItem>
                <MenuItem value="resigned">Resigned</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={6}><TextField label="Hire Date" type="date" value={form.hire_date} onChange={e => setForm({ ...form, hire_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.first_name.trim() || !form.last_name.trim() || !form.email.trim()}>{editing ? "Update" : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}