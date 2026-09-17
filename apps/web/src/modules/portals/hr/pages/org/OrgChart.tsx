import { useEffect, useState } from "react";
import { Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, MenuItem, TextField, Tooltip, Typography } from "@mui/material";
import { AccountTree, Add, Edit, PersonAdd, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Department { id: string; name: string; parent_department_id: string | null; tenant_id?: string; }
interface Employee { id: string; first_name: string; last_name: string; department_id: string | null; hr_positions?: { title: string } | null; }

export default function OrgChart() {
  const [depts, setDepts] = useState<Department[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  // dept dialog
  const [deptOpen, setDeptOpen] = useState(false);
  const [deptEditing, setDeptEditing] = useState<Department | null>(null);
  const [deptForm, setDeptForm] = useState({ name: "", parent_department_id: "" });
  const [deptSaving, setDeptSaving] = useState(false);
  const [deptError, setDeptError] = useState<string | null>(null);

  // assign dialog
  const [assignOpen, setAssignOpen] = useState(false);
  const [assignDeptId, setAssignDeptId] = useState<string>("");
  const [assignEmpId, setAssignEmpId] = useState<string>("");
  const [assignSaving, setAssignSaving] = useState(false);
  const [assignError, setAssignError] = useState<string | null>(null);

  const fetch = async () => {
    setLoading(true);
    setLoadError(null);
    const [deptRes, empRes] = await Promise.all([
      supabase.from("departments").select("id, name, parent_department_id, tenant_id").eq("is_active", true).order("name"),
      supabase.from("hr_employees").select("id, first_name, last_name, department_id, hr_positions(title)").eq("is_active", true).limit(200),
    ]);
    if (deptRes.error || empRes.error) {
      setLoadError(deptRes.error?.message ?? empRes.error?.message ?? "Could not load org chart data.");
      setLoading(false);
      return;
    }
    if (deptRes.data) setDepts(deptRes.data as Department[]);
    if (empRes.data) {
      const normalized = (empRes.data as any[]).map((e) => ({
        id: e.id, first_name: e.first_name, last_name: e.last_name, department_id: e.department_id,
        hr_positions: Array.isArray(e.hr_positions) ? e.hr_positions[0] ?? null : e.hr_positions ?? null,
      }));
      setEmployees(normalized as Employee[]);
    }
    setLoading(false);
  };

  useEffect(() => { fetch(); }, []);

  const openCreateDept = (parentId: string | null = null) => {
    setDeptEditing(null);
    setDeptForm({ name: "", parent_department_id: parentId || "" });
    setDeptError(null);
    setDeptOpen(true);
  };
  const openEditDept = (d: Department) => {
    setDeptEditing(d);
    setDeptForm({ name: d.name, parent_department_id: d.parent_department_id || "" });
    setDeptError(null);
    setDeptOpen(true);
  };
  const handleDeptSave = async () => {
    if (!deptForm.name.trim()) { setDeptError("Name is required."); return; }
    if (deptEditing && deptForm.parent_department_id === deptEditing.id) { setDeptError("A department cannot be its own parent."); return; }
    setDeptSaving(true);
    setDeptError(null);
    const tenant_id = depts[0]?.tenant_id || (await supabase.from("departments").select("tenant_id").limit(1).single().then(r => (r.data as any)?.tenant_id)) || undefined;
    const payload: any = { name: deptForm.name.trim(), parent_department_id: deptForm.parent_department_id || null, is_active: true };
    if (tenant_id) payload.tenant_id = tenant_id;
    let res;
    if (deptEditing) res = await supabase.from("departments").update(payload).eq("id", deptEditing.id);
    else res = await supabase.from("departments").insert(payload);
    setDeptSaving(false);
    if (res.error) { setDeptError(res.error.message); return; }
    setDeptOpen(false);
    fetch();
  };
  const handleDeptDelete = async (d: Department) => {
    const hasChildren = depts.some(x => x.parent_department_id === d.id);
    const hasEmployees = employees.some(e => e.department_id === d.id);
    if (hasChildren) { alert("Cannot delete: this department has child departments. Move or delete them first."); return; }
    if (hasEmployees) { alert("Cannot delete: employees are still assigned to this department. Reassign them first."); return; }
    if (!window.confirm(`Delete department "${d.name}"?`)) return;
    const { error } = await supabase.from("departments").delete().eq("id", d.id);
    if (error) alert(error.message);
    else fetch();
  };

  const openAssign = (deptId: string) => {
    setAssignDeptId(deptId);
    setAssignEmpId("");
    setAssignError(null);
    setAssignOpen(true);
  };
  const handleAssign = async () => {
    if (!assignEmpId) { setAssignError("Select an employee."); return; }
    setAssignSaving(true);
    setAssignError(null);
    const { error } = await supabase.from("hr_employees").update({ department_id: assignDeptId || null }).eq("id", assignEmpId);
    setAssignSaving(false);
    if (error) { setAssignError(error.message); return; }
    setAssignOpen(false);
    fetch();
  };
  const handleUnassign = async (empId: string) => {
    if (!window.confirm("Remove employee from department?")) return;
    const { error } = await supabase.from("hr_employees").update({ department_id: null }).eq("id", empId);
    if (error) alert(error.message);
    else fetch();
  };

  const renderDept = (dept: Department, level: number = 0) => {
    const children = depts.filter(d => d.parent_department_id === dept.id);
    const deptEmployees = employees.filter(e => e.department_id === dept.id);
    return (
      <Box key={dept.id} sx={{ ml: level * 3, mb: 2, borderLeft: level > 0 ? "2px solid #e0e0e0" : "none", pl: level > 0 ? 2 : 0 }}>
        <Card variant="outlined" sx={{ mb: 1, bgcolor: level === 0 ? "primary.light" : "white" }}>
          <CardContent sx={{ p: 1.5, display: "flex", justifyContent: "space-between", alignItems: "center", gap: 1 }}>
            <Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 0 }}>
              <AccountTree fontSize="small" />
              <Typography variant="subtitle2" fontWeight={700} noWrap>{dept.name}</Typography>
              <Chip label={`${deptEmployees.length} employees`} size="small" />
            </Box>
            <Box sx={{ display: "flex", gap: 0.5, flexShrink: 0 }}>
              <Tooltip title="Add child department"><IconButton size="small" aria-label="Add child" onClick={() => openCreateDept(dept.id)}><Add fontSize="small" /></IconButton></Tooltip>
              <Tooltip title="Assign employee"><IconButton size="small" aria-label="Assign employee" onClick={() => openAssign(dept.id)}><PersonAdd fontSize="small" /></IconButton></Tooltip>
              <Tooltip title="Edit department"><IconButton size="small" aria-label="Edit department" onClick={() => openEditDept(dept)}><Edit fontSize="small" /></IconButton></Tooltip>
              <Tooltip title="Delete department"><IconButton size="small" aria-label="Delete department" onClick={() => handleDeptDelete(dept)}><Delete fontSize="small" /></IconButton></Tooltip>
            </Box>
          </CardContent>
        </Card>
        {deptEmployees.length > 0 && (
          <Box sx={{ display: "flex", gap: 1, flexWrap: "wrap", mb: 1, ml: 2 }}>
            {deptEmployees.map(emp => (
              <Chip
                key={emp.id}
                label={`${emp.first_name} ${emp.last_name}${emp.hr_positions?.title ? ` - ${emp.hr_positions.title}` : ""}`}
                size="small"
                variant="outlined"
                onDelete={() => handleUnassign(emp.id)}
                deleteIcon={<Tooltip title="Remove from department"><Delete fontSize="small" /></Tooltip>}
              />
            ))}
          </Box>
        )}
        {children.map(child => renderDept(child, level + 1))}
      </Box>
    );
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;
  if (loadError) return <Box sx={{ p: 3 }}><Alert severity="error">{loadError}</Alert></Box>;

  const topLevel = depts.filter(d => !d.parent_department_id);
  const unassigned = employees.filter(e => !e.department_id);

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>Organization Chart</Typography>
          <Typography variant="body2" color="text.secondary">Hierarchical view of departments and employees. Click + to add child departments, assign employees, or edit/delete.</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          <Button variant="outlined" startIcon={<Add />} onClick={() => openCreateDept(null)}>New Top Department</Button>
          <Button variant="outlined" startIcon={<PersonAdd />} onClick={() => openAssign(topLevel[0]?.id || "")} disabled={unassigned.length === 0}>Assign Unassigned</Button>
        </Box>
      </Box>

      {topLevel.length === 0 ? (
        <Card><CardContent><Typography color="text.secondary">No departments yet. Create your first top-level department.</Typography><Button sx={{ mt: 1 }} variant="contained" startIcon={<Add />} onClick={() => openCreateDept(null)}>Create Department</Button></CardContent></Card>
      ) : (
        <Box>{topLevel.map(dept => renderDept(dept, 0))}</Box>
      )}

      {unassigned.length > 0 && (
        <Box sx={{ mt: 3 }}>
          <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
            <Typography variant="subtitle2">Unassigned Employees (no department) — {unassigned.length}</Typography>
            <Button size="small" variant="outlined" onClick={() => { setAssignDeptId(""); setAssignEmpId(unassigned[0].id); setAssignOpen(true); }}>Assign...</Button>
          </Box>
          <Box sx={{ display: "flex", gap: 1, flexWrap: "wrap" }}>
            {unassigned.map(emp => (
              <Chip key={emp.id} label={`${emp.first_name} ${emp.last_name}${emp.hr_positions?.title ? ` — ${emp.hr_positions.title}` : ""}`} size="small" onClick={() => { setAssignDeptId(""); setAssignEmpId(emp.id); setAssignOpen(true); }} />
            ))}
          </Box>
        </Box>
      )}

      {/* Create/Edit Department Dialog */}
      <Dialog open={deptOpen} onClose={() => !deptSaving && setDeptOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{deptEditing ? "Edit Department" : "New Department"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {deptError && <Alert severity="error">{deptError}</Alert>}
          <TextField label="Name *" value={deptForm.name} onChange={e => setDeptForm({ ...deptForm, name: e.target.value })} fullWidth autoFocus required placeholder="e.g. Engineering, Operations" />
          <TextField select label="Parent Department" value={deptForm.parent_department_id} onChange={e => setDeptForm({ ...deptForm, parent_department_id: e.target.value })} fullWidth helperText="Leave empty for top-level">
            <MenuItem value="">— Top level (no parent) —</MenuItem>
            {depts.filter(d => !deptEditing || d.id !== deptEditing.id).map(d => <MenuItem key={d.id} value={d.id}>{d.name}</MenuItem>)}
          </TextField>
        </DialogContent>
        <DialogActions><Button onClick={() => setDeptOpen(false)} disabled={deptSaving}>Cancel</Button><Button variant="contained" onClick={handleDeptSave} disabled={deptSaving}>{deptSaving ? "Saving..." : deptEditing ? "Update" : "Create"}</Button></DialogActions>
      </Dialog>

      {/* Assign Employee Dialog */}
      <Dialog open={assignOpen} onClose={() => !assignSaving && setAssignOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Assign Employee to Department</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {assignError && <Alert severity="error">{assignError}</Alert>}
          <TextField select label="Department *" value={assignDeptId} onChange={e => setAssignDeptId(e.target.value)} fullWidth required>
            <MenuItem value="">— Unassigned (remove) —</MenuItem>
            {depts.map(d => <MenuItem key={d.id} value={d.id}>{d.name}</MenuItem>)}
          </TextField>
          <TextField select label="Employee *" value={assignEmpId} onChange={e => setAssignEmpId(e.target.value)} fullWidth required>
            <MenuItem value="">— Select Employee —</MenuItem>
            {employees.map(emp => <MenuItem key={emp.id} value={emp.id}>{emp.first_name} {emp.last_name}{emp.hr_positions?.title ? ` — ${emp.hr_positions.title}` : ""} {emp.department_id ? ` (now: ${depts.find(d=>d.id===emp.department_id)?.name||'?'})` : " (unassigned)"}</MenuItem>)}
          </TextField>
          <Typography variant="caption" color="text.secondary">This updates <code>hr_employees.department_id</code> directly. The employee chip will move immediately after save.</Typography>
        </DialogContent>
        <DialogActions><Button onClick={() => setAssignOpen(false)} disabled={assignSaving}>Cancel</Button><Button variant="contained" onClick={handleAssign} disabled={assignSaving || !assignEmpId || !assignDeptId}>Assign</Button></DialogActions>
      </Dialog>
    </Box>
  );
}
