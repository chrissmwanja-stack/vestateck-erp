import { useEffect, useState, useMemo } from "react";
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  MenuItem,
  Grid,
  IconButton,
  Tooltip,
  Alert,
} from "@mui/material";
import { Add, Edit, Delete, Warning } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Project { id: string; name: string }
interface Employee { id: string; first_name: string; last_name: string }
interface Allocation {
  id: string;
  tenant_id: string;
  employee_id: string | null;
  project_id: string | null;
  allocation_percent: number;
  start_date: string | null;
  end_date: string | null;
  status: string | null;
  created_at: string;
  pmo_projects?: { name: string } | null;
  hr_employees?: { first_name: string; last_name: string } | null;
}

const emptyForm = { employee_id: "", project_id: "", allocation_percent: 100, start_date: "", end_date: "", status: "active" };

export default function ResourceAllocation() {
  const { session } = useAuth();
  const [allocations, setAllocations] = useState<Allocation[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Allocation | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const [allocRes, projRes, empRes] = await Promise.all([
      supabase.from("pmo_resource_allocations").select("*, pmo_projects(name), hr_employees(first_name, last_name)").order("created_at", { ascending: false }).limit(200),
      supabase.from("pmo_projects").select("id, name").order("name"),
      supabase.from("hr_employees").select("id, first_name, last_name").eq("is_active", true).order("first_name"),
    ]);
    if (allocRes.data) {
      const norm = (allocRes.data as any[]).map((a: any) => ({
        ...a,
        pmo_projects: Array.isArray(a.pmo_projects) ? a.pmo_projects[0] ?? null : a.pmo_projects ?? null,
        hr_employees: Array.isArray(a.hr_employees) ? a.hr_employees[0] ?? null : a.hr_employees ?? null,
      }));
      setAllocations(norm as Allocation[]);
    }
    if (projRes.data) setProjects(projRes.data as Project[]);
    if (empRes.data) setEmployees(empRes.data as Employee[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  // per-employee total active allocation for warning in dialog
  const employeeLoad = useMemo(() => {
    const map: Record<string, number> = {};
    for (const a of allocations) {
      if (!a.employee_id || (a.status !== "active" && a.status !== "planned")) continue;
      // when editing, exclude the row being edited so we show "other" load
      if (editing && a.id === editing.id) continue;
      map[a.employee_id] = (map[a.employee_id] || 0) + (a.allocation_percent || 0);
    }
    return map;
  }, [allocations, editing]);

  const currentEmployeeOtherLoad = form.employee_id ? employeeLoad[form.employee_id] || 0 : 0;
  const wouldBeTotal = currentEmployeeOtherLoad + (Number(form.allocation_percent) || 0);
  const overallocated = wouldBeTotal > 100;

  const openCreate = () => {
    setEditing(null);
    setForm(emptyForm);
    setError(null);
    setOpen(true);
  };

  const openEdit = (row: Allocation) => {
    setEditing(row);
    setForm({
      employee_id: row.employee_id || "",
      project_id: row.project_id || "",
      allocation_percent: row.allocation_percent,
      start_date: row.start_date || "",
      end_date: row.end_date || "",
      status: row.status || "active",
    });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.employee_id) { setError("Select an employee."); return; }
    if (!form.project_id) { setError("Select a project."); return; }
    const pct = Number(form.allocation_percent);
    if (Number.isNaN(pct) || pct < 0 || pct > 200) { setError("Allocation % must be 0-200."); return; }
    if (form.start_date && form.end_date && form.start_date > form.end_date) { setError("Start date cannot be after end date."); return; }
    setSaving(true);
    const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || allocations[0]?.tenant_id;

    const payload: any = {
      employee_id: form.employee_id,
      project_id: form.project_id,
      allocation_percent: pct,
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      status: form.status,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    let res;
    if (editing) {
      res = await supabase.from("pmo_resource_allocations").update(payload).eq("id", editing.id);
    } else {
      res = await supabase.from("pmo_resource_allocations").insert(payload);
    }
    setSaving(false);
    if (res.error) {
      setError(res.error.message);
      return;
    }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this allocation? This cannot be undone.")) return;
    const { error: err } = await supabase.from("pmo_resource_allocations").delete().eq("id", id);
    if (err) {
      alert(err.message);
      return;
    }
    fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Resource Allocation</Typography>
          <Typography variant="body2" color="text.secondary">{allocations.length} allocations • Who is allocated where, capacity %. Click edit to adjust.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Allocation</Button>
      </Box>

      <Card><CardContent sx={{ p: 0 }}>
        <Table>
          <TableHead><TableRow><TableCell>Resource</TableCell><TableCell>Project</TableCell><TableCell>Allocation %</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell>Status</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead>
          <TableBody>
            {allocations.length === 0 ? (
              <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No allocations yet. Allocate employees to projects with % capacity.</Typography></TableCell></TableRow>
            ) : (
              allocations.map(a => (
                <TableRow key={a.id} hover>
                  <TableCell><Typography fontWeight={600}>{a.hr_employees ? `${a.hr_employees.first_name} ${a.hr_employees.last_name}` : a.employee_id?.slice(0,8) || "-"}</Typography></TableCell>
                  <TableCell>{a.pmo_projects?.name || "-"}</TableCell>
                  <TableCell>
                    <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                      <Chip label={`${a.allocation_percent}%`} size="small" color={a.allocation_percent > 100 ? "error" : a.allocation_percent > 80 ? "warning" : "success"} />
                      {a.allocation_percent > 100 && <Tooltip title="Over 100% in this single allocation"><Warning fontSize="small" color="error" /></Tooltip>}
                    </Box>
                  </TableCell>
                  <TableCell>{a.start_date ? new Date(a.start_date).toLocaleDateString() : "-"}</TableCell>
                  <TableCell>{a.end_date ? new Date(a.end_date).toLocaleDateString() : "-"}</TableCell>
                  <TableCell><Chip label={a.status || "active"} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell>
                  <TableCell align="right">
                    <Tooltip title="Edit"><IconButton aria-label="Edit allocation" size="small" onClick={() => openEdit(a)}><Edit fontSize="small" /></IconButton></Tooltip>
                    <Tooltip title="Delete"><IconButton aria-label="Delete allocation" size="small" onClick={() => handleDelete(a.id)}><Delete fontSize="small" /></IconButton></Tooltip>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Allocation" : "New Allocation"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField select label="Employee *" value={form.employee_id} onChange={e => setForm({ ...form, employee_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Employee --</MenuItem>
            {employees.map(emp => <MenuItem key={emp.id} value={emp.id}>{emp.first_name} {emp.last_name}</MenuItem>)}
          </TextField>
          <TextField select label="Project *" value={form.project_id} onChange={e => setForm({ ...form, project_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Project --</MenuItem>
            {projects.map(p => <MenuItem key={p.id} value={p.id}>{p.name}</MenuItem>)}
          </TextField>
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField label="Allocation %" type="number" value={form.allocation_percent} onChange={e => setForm({ ...form, allocation_percent: parseInt(e.target.value) || 0 })} fullWidth InputProps={{ inputProps: { min: 0, max: 200 } }} helperText={`Other active: ${currentEmployeeOtherLoad}% → total ${wouldBeTotal}%`} error={overallocated} />
              {overallocated && <Alert severity="warning" sx={{ mt: 1, py: 0 }}><Typography variant="caption">This employee would be at {wouldBeTotal}% (&gt;100% = overallocated). Will show as overallocated in Resource Utilization report.</Typography></Alert>}
            </Grid>
            <Grid item xs={6}>
              <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth>
                <MenuItem value="active">Active</MenuItem>
                <MenuItem value="planned">Planned</MenuItem>
                <MenuItem value="completed">Completed</MenuItem>
              </TextField>
            </Grid>
          </Grid>
          <Grid container spacing={2}>
            <Grid item xs={6}><TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
            <Grid item xs={6}><TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.employee_id || !form.project_id || saving}>{saving ? "Saving..." : editing ? "Update" : "Create Allocation"}</Button>
        </DialogActions>
      </Dialog>

      <Alert severity="info" sx={{ mt: 2 }}>
        <Typography variant="caption">Tip: Keep total per employee ≤100% for full-time. Check <strong>Resource Utilization</strong> report to see rolled-up load per resource and overallocated warnings.</Typography>
      </Alert>
    </Box>
  );
}
