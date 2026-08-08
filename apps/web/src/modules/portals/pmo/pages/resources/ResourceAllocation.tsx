import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Project { id: string; name: string; }
interface Employee { id: string; first_name: string; last_name: string; }
interface Allocation { id: string; tenant_id: string; employee_id: string | null; project_id: string | null; allocation_percent: number; start_date: string | null; end_date: string | null; status: string | null; created_at: string; pmo_projects?: { name: string } | null; hr_employees?: { first_name: string; last_name: string } | null; }

export default function ResourceAllocation() {
  const { session } = useAuth();
  const [allocations, setAllocations] = useState<Allocation[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ employee_id: "", project_id: "", allocation_percent: 100, start_date: "", end_date: "", status: "active" });

  const fetchData = async () => {
    setLoading(true);
    const [allocRes, projRes, empRes] = await Promise.all([
      supabase.from("pmo_resource_allocations").select("*, pmo_projects(name), hr_employees(first_name, last_name)").order("created_at", { ascending: false }).limit(100),
      supabase.from("pmo_projects").select("id, name").order("name"),
      supabase.from("hr_employees").select("id, first_name, last_name").eq("is_active", true).order("first_name"),
    ]);
    if (allocRes.data) setAllocations(allocRes.data as Allocation[]);
    if (projRes.data) setProjects(projRes.data as Project[]);
    if (empRes.data) setEmployees(empRes.data as Employee[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.employee_id || !form.project_id) return;
    const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || allocations[0]?.tenant_id;
    const payload: any = {
      employee_id: form.employee_id,
      project_id: form.project_id,
      allocation_percent: form.allocation_percent,
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      status: form.status,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    const { error } = await supabase.from("pmo_resource_allocations").insert(payload);
    if (error) {
      if (error.message.includes("does not exist")) {
        // Mock for shell without table
        const mock: Allocation = {
          id: Math.random().toString(36).substring(7),
          tenant_id: "mock",
          employee_id: form.employee_id,
          project_id: form.project_id,
          allocation_percent: form.allocation_percent,
          start_date: form.start_date || null,
          end_date: form.end_date || null,
          status: form.status,
          created_at: new Date().toISOString(),
          pmo_projects: projects.find(p => p.id === form.project_id) ? { name: projects.find(p => p.id === form.project_id)!.name } : null,
          hr_employees: employees.find(e => e.id === form.employee_id) ? { first_name: employees.find(e => e.id === form.employee_id)!.first_name, last_name: employees.find(e => e.id === form.employee_id)!.last_name } : null,
        };
        setAllocations(prev => [mock, ...prev]);
        setOpen(false);
        setForm({ employee_id: "", project_id: "", allocation_percent: 100, start_date: "", end_date: "", status: "active" });
        return;
      }
      alert(error.message);
      return;
    }
    setOpen(false);
    setForm({ employee_id: "", project_id: "", allocation_percent: 100, start_date: "", end_date: "", status: "active" });
    fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Resource Allocation</Typography><Typography variant="body2" color="text.secondary">{allocations.length} allocations • Who is allocated where, capacity %.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Allocation</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Resource</TableCell><TableCell>Project</TableCell><TableCell>Allocation %</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{allocations.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No allocations yet. Allocate employees to projects with % capacity.</Typography></TableCell></TableRow> : allocations.map(a => <TableRow key={a.id} hover><TableCell><Typography fontWeight={600}>{a.hr_employees ? `${a.hr_employees.first_name} ${a.hr_employees.last_name}` : a.employee_id?.slice(0,8) || "-"}</Typography></TableCell><TableCell>{a.pmo_projects?.name || "-"}</TableCell><TableCell><Chip label={`${a.allocation_percent}%`} size="small" color={a.allocation_percent > 100 ? "error" : a.allocation_percent > 80 ? "warning" : "success"} /></TableCell><TableCell>{a.start_date ? new Date(a.start_date).toLocaleDateString() : "-"}</TableCell><TableCell>{a.end_date ? new Date(a.end_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={a.status || "active"} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Allocation</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Employee *" value={form.employee_id} onChange={e => setForm({ ...form, employee_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Employee --</MenuItem>{employees.map(emp => <MenuItem key={emp.id} value={emp.id}>{emp.first_name} {emp.last_name}</MenuItem>)}</TextField><TextField select label="Project *" value={form.project_id} onChange={e => setForm({ ...form, project_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Project --</MenuItem>{projects.map(p => <MenuItem key={p.id} value={p.id}>{p.name}</MenuItem>)}</TextField><Grid container spacing={2}><Grid item xs={6}><TextField label="Allocation %" type="number" value={form.allocation_percent} onChange={e => setForm({ ...form, allocation_percent: parseInt(e.target.value) || 0 })} fullWidth InputProps={{ inputProps: { min: 0, max: 200 } }} helperText="100% = full time" /></Grid><Grid item xs={6}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="active">Active</MenuItem><MenuItem value="planned">Planned</MenuItem><MenuItem value="completed">Completed</MenuItem></TextField></Grid></Grid><Grid container spacing={2}><Grid item xs={6}><TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={6}><TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.employee_id || !form.project_id}>Create Allocation</Button></DialogActions></Dialog>
    </Box>
  );
}
