import { useEffect, useState } from "react";
import { Alert, Box, Card, CardContent, Chip, CircularProgress, Typography } from "@mui/material";
import { AccountTree } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Department { id: string; name: string; parent_department_id: string | null; }
interface Employee { id: string; first_name: string; last_name: string; department_id: string | null; hr_positions?: { title: string } | null; }

export default function OrgChart() {
  const [depts, setDepts] = useState<Department[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      setLoadError(null);
      const [deptRes, empRes] = await Promise.all([
        // NOTE: was "hr_departments", which does not exist -- departments
        // live in the shared `departments` table (same issue as
        // EmployeesList.tsx before its fix this session).
        // NOTE: the hierarchy column is `parent_department_id`, not
        // `parent_id` -- fixed after a 400 from PostgREST.
        supabase.from("departments").select("id, name, parent_department_id").eq("is_active", true).order("name"),
        supabase
          .from("hr_employees")
          .select("id, first_name, last_name, department_id, hr_positions(title)")
          .eq("is_active", true)
          .limit(100),
      ]);

      if (deptRes.error || empRes.error) {
        setLoadError(deptRes.error?.message ?? empRes.error?.message ?? "Could not load org chart data.");
        setLoading(false);
        return;
      }

      if (deptRes.data) setDepts(deptRes.data as Department[]);

      if (empRes.data) {
        // PostgREST returns the nested hr_positions join as an array
        // ([{ title }]) even though each employee has at most one
        // position -- normalize to the singular shape Employee expects
        // (same pattern as CaseStatusReport.tsx).
        const normalized = (empRes.data as any[]).map((e) => ({
          id: e.id,
          first_name: e.first_name,
          last_name: e.last_name,
          department_id: e.department_id,
          hr_positions: Array.isArray(e.hr_positions) ? e.hr_positions[0] ?? null : e.hr_positions ?? null,
        }));
        setEmployees(normalized as Employee[]);
      }

      setLoading(false);
    };
    fetch();
  }, []);

  const renderDept = (dept: Department, level: number = 0) => {
    const children = depts.filter(d => d.parent_department_id === dept.id);
    const deptEmployees = employees.filter(e => e.department_id === dept.id);

    return (
      <Box key={dept.id} sx={{ ml: level * 3, mb: 2, borderLeft: level > 0 ? "2px solid #e0e0e0" : "none", pl: level > 0 ? 2 : 0 }}>
        <Card variant="outlined" sx={{ mb: 1, bgcolor: level === 0 ? "primary.light" : "white" }}>
          <CardContent sx={{ p: 1.5, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
              <AccountTree fontSize="small" />
              <Typography variant="subtitle2" fontWeight={700}>{dept.name}</Typography>
            </Box>
            <Chip label={`${deptEmployees.length} employees`} size="small" />
          </CardContent>
        </Card>
        {deptEmployees.length > 0 && (
          <Box sx={{ display: "flex", gap: 1, flexWrap: "wrap", mb: 1, ml: 2 }}>
            {deptEmployees.map(emp => (
              <Chip key={emp.id} label={`${emp.first_name} ${emp.last_name}${emp.hr_positions?.title ? ` - ${emp.hr_positions.title}` : ""}`} size="small" variant="outlined" />
            ))}
          </Box>
        )}
        {children.map(child => renderDept(child, level + 1))}
      </Box>
    );
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (loadError) {
    return (
      <Box sx={{ p: 3 }}>
        <Alert severity="error">{loadError}</Alert>
      </Box>
    );
  }

  const topLevel = depts.filter(d => !d.parent_department_id);

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Organization Chart</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Hierarchical view of departments and employees. Based on departments parent_department_id and hr_employees department_id.</Typography>
      
      {topLevel.length === 0 ? (
        <Card><CardContent><Typography color="text.secondary">No departments yet. Create departments in Admin → Departments with parent-child relationships to build org chart.</Typography></CardContent></Card>
      ) : (
        <Box>
          {topLevel.map(dept => renderDept(dept, 0))}
        </Box>
      )}

      {employees.filter(e => !e.department_id).length > 0 && (
        <Box sx={{ mt: 3 }}>
          <Typography variant="subtitle2" gutterBottom>Unassigned Employees (no department)</Typography>
          <Box sx={{ display: "flex", gap: 1, flexWrap: "wrap" }}>
            {employees.filter(e => !e.department_id).map(emp => (
              <Chip key={emp.id} label={`${emp.first_name} ${emp.last_name}`} size="small" />
            ))}
          </Box>
        </Box>
      )}
    </Box>
  );
}