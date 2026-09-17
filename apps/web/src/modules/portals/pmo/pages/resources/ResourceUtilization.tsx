import { useEffect, useState, useMemo } from "react";
import {
  Box,
  Card,
  CardContent,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
  CircularProgress,
  LinearProgress,
  Chip,
  Button,
  Alert,
  Tooltip,
  Grid,
} from "@mui/material";
import { Download, FileDownload, Refresh, Warning } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

interface AllocationRow {
  id: string;
  employee_id: string | null;
  project_id: string | null;
  allocation_percent: number;
  start_date: string | null;
  end_date: string | null;
  status: string | null;
  hr_employees?: { first_name: string; last_name: string } | null;
  pmo_projects?: { name: string } | null;
}

interface TaskRow {
  assignee_id: string | null;
  status: string;
}

interface EmpUtil {
  employeeId: string;
  name: string;
  totalAllocation: number;
  activeAllocations: number;
  projectCount: number;
  projects: { name: string; percent: number; status: string | null }[];
  taskCount: number;
  utilization: number; // = totalAllocation, 100% = full
  availableHours: string;
  status: "Normal" | "High" | "Overallocated";
}

export default function ResourceUtilization() {
  const [allocations, setAllocations] = useState<AllocationRow[]>([]);
  const [tasks, setTasks] = useState<TaskRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetch = async () => {
    setLoading(true);
    setError(null);
    const [allocRes, taskRes] = await Promise.all([
      supabase
        .from("pmo_resource_allocations")
        .select("id, employee_id, project_id, allocation_percent, start_date, end_date, status, hr_employees(first_name, last_name), pmo_projects(name)")
        .order("created_at", { ascending: false })
        .limit(500),
      supabase.from("pmo_tasks").select("assignee_id, status").limit(500),
    ]);

    if (allocRes.error) {
      setError(allocRes.error.message);
      setLoading(false);
      return;
    }
    if (taskRes.error) {
      setError(taskRes.error.message);
      setLoading(false);
      return;
    }

    // normalize joins
    const normAllocs = ((allocRes.data as any[]) || []).map((a: any) => ({
      ...a,
      hr_employees: Array.isArray(a.hr_employees) ? a.hr_employees[0] ?? null : a.hr_employees ?? null,
      pmo_projects: Array.isArray(a.pmo_projects) ? a.pmo_projects[0] ?? null : a.pmo_projects ?? null,
    })) as AllocationRow[];

    setAllocations(normAllocs);
    setTasks((taskRes.data as TaskRow[]) || []);
    setLoading(false);
  };

  useEffect(() => {
    fetch();
  }, []);

  const taskCountByEmployee = useMemo(() => {
    const map: Record<string, number> = {};
    for (const t of tasks) {
      if (!t.assignee_id) continue;
      map[t.assignee_id] = (map[t.assignee_id] || 0) + 1;
    }
    return map;
  }, [tasks]);

  const utilization: EmpUtil[] = useMemo(() => {
    // group allocations by employee_id (ignore rows with no employee)
    const byEmp = new Map<string, AllocationRow[]>();
    for (const a of allocations) {
      if (!a.employee_id) continue;
      const list = byEmp.get(a.employee_id) ?? [];
      list.push(a);
      byEmp.set(a.employee_id, list);
    }

    // also need to include employees who only have tasks but no allocation
    // so they still show in report
    for (const empId of Object.keys(taskCountByEmployee)) {
      if (!byEmp.has(empId)) byEmp.set(empId, []);
    }

    const rows: EmpUtil[] = [];
    for (const [empId, allocs] of byEmp.entries()) {
      const activeAllocs = allocs.filter((a) => a.status === "active" || a.status === "planned");
      const totalAllocation = activeAllocs.reduce((s, a) => s + (a.allocation_percent || 0), 0);
      // If employee has no allocation but has tasks, we synthesize 20% per task (legacy) but capped and noted
      const taskCount = taskCountByEmployee[empId] || 0;
      const effectiveUtil =
        totalAllocation > 0 ? totalAllocation : Math.min(100, taskCount * 20);

      let status: EmpUtil["status"] = "Normal";
      if (effectiveUtil > 100) status = "Overallocated";
      else if (effectiveUtil > 80) status = "High";

      // name lookup: prefer allocation's hr_employees, fallback to sliced id
      const sample = allocs.find((a) => a.hr_employees)?.hr_employees;
      const name = sample ? `${sample.first_name} ${sample.last_name}` : empId.slice(0, 8);

      const projects = allocs.map((a) => ({
        name: a.pmo_projects?.name || a.project_id?.slice(0, 8) || "-",
        percent: a.allocation_percent,
        status: a.status,
      }));

      const projectCount = new Set(allocs.map((a) => a.project_id)).size;
      // Available hours assuming 40h week full-time = 100%
      const available = Math.max(0, 40 - (effectiveUtil / 100) * 40);
      const availableHours = `${available.toFixed(1)}h / 40h free`;

      rows.push({
        employeeId: empId,
        name,
        totalAllocation,
        activeAllocations: activeAllocs.length,
        projectCount,
        projects,
        taskCount,
        utilization: effectiveUtil,
        availableHours,
        status,
      });
    }

    // sort overallocated first, then high util
    return rows.sort((a, b) => b.utilization - a.utilization);
  }, [allocations, taskCountByEmployee]);

  const summary = useMemo(() => {
    const totalEmployees = utilization.length;
    const overallocated = utilization.filter((u) => u.status === "Overallocated").length;
    const high = utilization.filter((u) => u.status === "High").length;
    const avgUtil = totalEmployees ? utilization.reduce((s, u) => s + u.utilization, 0) / totalEmployees : 0;
    return { totalEmployees, overallocated, high, avgUtil };
  }, [utilization]);

  const handleExportExcel = () => {
    const cols = [
      { header: "Resource", accessor: (r: EmpUtil) => r.name },
      { header: "Total Allocation %", accessor: (r: EmpUtil) => r.utilization },
      { header: "Active Allocations", accessor: (r: EmpUtil) => r.activeAllocations },
      { header: "Projects", accessor: (r: EmpUtil) => r.projectCount },
      { header: "Assigned Tasks", accessor: (r: EmpUtil) => r.taskCount },
      { header: "Available", accessor: (r: EmpUtil) => r.availableHours },
      { header: "Status", accessor: (r: EmpUtil) => r.status },
    ];
    exportReportToExcel(`pmo-resource-utilization-${new Date().toISOString().slice(0, 10)}`, "Utilization", cols as any, utilization);
  };

  const handleExportPdf = () => {
    const cols = [
      { header: "Resource", accessor: (r: EmpUtil) => r.name },
      { header: "Alloc %", accessor: (r: EmpUtil) => `${r.utilization}%` },
      { header: "Allocs", accessor: (r: EmpUtil) => r.activeAllocations },
      { header: "Projects", accessor: (r: EmpUtil) => r.projectCount },
      { header: "Tasks", accessor: (r: EmpUtil) => r.taskCount },
      { header: "Available", accessor: (r: EmpUtil) => r.availableHours },
      { header: "Status", accessor: (r: EmpUtil) => r.status },
    ];
    exportReportToPdf(
      `pmo-resource-utilization-${new Date().toISOString().slice(0, 10)}.pdf`,
      "Resource Utilization",
      cols as any,
      utilization,
      `${summary.totalEmployees} resources • ${summary.overallocated} overallocated • Avg ${summary.avgUtil.toFixed(0)}%`
    );
  };

  if (loading)
    return (
      <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}>
        <CircularProgress />
      </Box>
    );

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>
            Resource Utilization
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 700 }}>
            Real utilization from <code>pmo_resource_allocations</code> (allocation_percent per project) + assigned task count. 100% = 40h/week full-time.
            Over 100% = overallocated — reduce allocation % or reassign tasks. High = 81-100%.
          </Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1, flexWrap: "wrap" }}>
          <Button size="small" variant="outlined" startIcon={<Refresh />} onClick={fetch}>
            Refresh
          </Button>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExportExcel} disabled={utilization.length === 0}>
            Excel
          </Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPdf} disabled={utilization.length === 0}>
            PDF
          </Button>
        </Box>
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}

      <Grid container spacing={2} sx={{ mb: 2 }}>
        <Grid item xs={12} sm={6} md={3}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="caption" color="text.secondary">
                Resources Tracked
              </Typography>
              <Typography variant="h4" fontWeight={700}>
                {summary.totalEmployees}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                With allocations or tasks
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card variant="outlined" sx={{ bgcolor: summary.overallocated > 0 ? "error.light" : "white" }}>
            <CardContent>
              <Typography variant="caption">Overallocated (&gt;100%)</Typography>
              <Typography variant="h4" fontWeight={700}>
                {summary.overallocated}
              </Typography>
              <Typography variant="caption">{summary.overallocated > 0 ? "Needs rebalancing" : "All good"}</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card variant="outlined" sx={{ bgcolor: summary.high > 0 ? "warning.light" : "white" }}>
            <CardContent>
              <Typography variant="caption">High (81-100%)</Typography>
              <Typography variant="h4" fontWeight={700}>
                {summary.high}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="caption" color="text.secondary">
                Avg Utilization
              </Typography>
              <Typography variant="h4" fontWeight={700}>
                {summary.avgUtil.toFixed(0)}%
              </Typography>
              <Box sx={{ mt: 1 }}>
                <LinearProgress variant="determinate" value={Math.min(100, summary.avgUtil)} color={summary.avgUtil > 100 ? "error" : summary.avgUtil > 80 ? "warning" : "success"} />
              </Box>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Resource</TableCell>
                <TableCell>Projects</TableCell>
                <TableCell>Allocations</TableCell>
                <TableCell>Tasks</TableCell>
                <TableCell>Available</TableCell>
                <TableCell>Utilization %</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {utilization.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}>
                    <Typography color="text.secondary">No utilization data yet.</Typography>
                    <Typography variant="caption" color="text.secondary">
                      Allocate employees to projects via <strong>Resource Allocation → New Allocation</strong> or assign tasks to employees.
                      <br />
                      This report rolls up <code>allocation_percent</code> per active allocation; task count is supplemental when no allocation exists.
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                utilization.map((u) => (
                  <TableRow key={u.employeeId} hover sx={u.status === "Overallocated" ? { bgcolor: "error.lighter" } : undefined}>
                    <TableCell>
                      <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                        <Typography fontWeight={600}>{u.name}</Typography>
                        {u.status === "Overallocated" && (
                          <Tooltip title="Overallocated — total active allocation exceeds 100% (40h/week)">
                            <Warning fontSize="small" color="error" />
                          </Tooltip>
                        )}
                      </Box>
                      <Typography variant="caption" color="text.secondary" fontFamily="monospace">
                        {u.employeeId.slice(0, 8)}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">{u.projectCount} project(s)</Typography>
                      {u.projects.length > 0 && (
                        <Box sx={{ display: "flex", gap: 0.5, flexWrap: "wrap", mt: 0.5 }}>
                          {u.projects.slice(0, 3).map((p, i) => (
                            <Chip key={i} label={`${p.name} ${p.percent}%`} size="small" variant="outlined" />
                          ))}
                          {u.projects.length > 3 && <Chip label={`+${u.projects.length - 3}`} size="small" />}
                        </Box>
                      )}
                    </TableCell>
                    <TableCell>
                      <Chip
                        label={`${u.totalAllocation}% across ${u.activeAllocations} alloc`}
                        size="small"
                        color={u.totalAllocation > 100 ? "error" : u.totalAllocation > 80 ? "warning" : "default"}
                      />
                    </TableCell>
                    <TableCell>{u.taskCount}</TableCell>
                    <TableCell>
                      <Typography variant="body2">{u.availableHours}</Typography>
                    </TableCell>
                    <TableCell sx={{ minWidth: 140 }}>
                      <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                        <LinearProgress
                          variant="determinate"
                          value={Math.min(100, u.utilization)}
                          sx={{ width: 100, height: 8, borderRadius: 1 }}
                          color={u.utilization > 100 ? "error" : u.utilization > 80 ? "warning" : "success"}
                        />
                        <Typography variant="body2" fontWeight={700} color={u.status === "Overallocated" ? "error.main" : "text.primary"}>
                          {u.utilization}%
                        </Typography>
                      </Box>
                    </TableCell>
                    <TableCell>
                      <Chip
                        label={u.status}
                        size="small"
                        color={u.status === "Overallocated" ? "error" : u.status === "High" ? "warning" : "success"}
                      />
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Alert severity="info" sx={{ mt: 2 }}>
        <Typography variant="caption">
          <strong>How utilization is computed:</strong> Sum of <code>allocation_percent</code> for each employee's active <em>pmo_resource_allocations</em> rows
          (100% = full-time, 50% = half-time). If an employee has no allocation but has tasks assigned, we estimate 20% per task (capped at 100%) as a fallback.
          Edit allocations in <strong>Resource Allocation</strong> to rebalance — overallocated resources show first.
        </Typography>
      </Alert>
    </Box>
  );
}
