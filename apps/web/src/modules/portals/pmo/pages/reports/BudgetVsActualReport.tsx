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
  Chip,
  LinearProgress,
  Button,
  Alert,
  Grid,
  TextField,
  MenuItem,
} from "@mui/material";
import { Download, FileDownload, Refresh } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

interface ProjectRow {
  id: string;
  name: string;
  budget: number | null;
  currency: string;
  status: string;
  pmo_tasks?: { completion_percent: number | null; status: string }[] | null;
  pmo_milestones?: { completion_percent: number; status: string }[] | null;
}

interface ComputedRow {
  id: string;
  name: string;
  currency: string;
  status: string;
  budget: number;
  taskCount: number;
  milestoneCount: number;
  avgCompletion: number;
  actual: number;
  variance: number;
  utilization: number; // actual/budget*100
  earned: number;
}

export default function BudgetVsActualReport() {
  const [projects, setProjects] = useState<ProjectRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<string>("all");

  const fetch = async () => {
    setLoading(true);
    setError(null);
    // Fetch projects with tasks + milestones in one go (PostgREST embed)
    const { data, error: err } = await supabase
      .from("pmo_projects")
      .select("id, name, budget, currency, status, pmo_tasks(completion_percent, status), pmo_milestones(completion_percent, status)")
      .order("created_at", { ascending: false })
      .limit(200);

    if (err) {
      setError(err.message);
      setLoading(false);
      return;
    }
    setProjects((data as ProjectRow[]) || []);
    setLoading(false);
  };

  useEffect(() => {
    fetch();
  }, []);

  const computed: ComputedRow[] = useMemo(() => {
    return projects.map((p) => {
      const budget = Number(p.budget) || 0;
      const tasks = (p.pmo_tasks as any[]) || [];
      const milestones = (p.pmo_milestones as any[]) || [];

      // Weighted progress: 70% tasks + 30% milestones, else tasks-only
      const taskAvg = tasks.length ? tasks.reduce((s: number, t: any) => s + (Number(t.completion_percent) || 0), 0) / tasks.length : 0;
      const msAvg = milestones.length ? milestones.reduce((s: number, m: any) => s + (Number(m.completion_percent) || 0), 0) / milestones.length : 0;
      const avgCompletion = tasks.length && milestones.length ? taskAvg * 0.7 + msAvg * 0.3 : tasks.length ? taskAvg : msAvg;

      // Earned Value = budget * completion
      const actual = budget * (avgCompletion / 100);
      const variance = budget - actual;
      const utilization = budget > 0 ? (actual / budget) * 100 : 0;

      return {
        id: p.id,
        name: p.name,
        currency: p.currency || "UGX",
        status: p.status,
        budget,
        taskCount: tasks.length,
        milestoneCount: milestones.length,
        avgCompletion,
        actual,
        variance,
        utilization,
        earned: actual,
      };
    });
  }, [projects]);

  const filtered = useMemo(() => {
    if (statusFilter === "all") return computed;
    return computed.filter((r) => r.status === statusFilter);
  }, [computed, statusFilter]);

  const totals = useMemo(() => {
    const totalBudget = filtered.reduce((s, r) => s + r.budget, 0);
    const totalActual = filtered.reduce((s, r) => s + r.actual, 0);
    const totalVariance = totalBudget - totalActual;
    const avgUtil = filtered.length ? filtered.reduce((s, r) => s + r.utilization, 0) / filtered.length : 0;
    const overBudget = filtered.filter((r) => r.variance < 0).length;
    return { totalBudget, totalActual, totalVariance, avgUtil, overBudget };
  }, [filtered]);

  const handleExportExcel = () => {
    const cols = [
      { header: "Project", accessor: (r: ComputedRow) => r.name },
      { header: "Status", accessor: (r: ComputedRow) => r.status },
      { header: "Budget", accessor: (r: ComputedRow) => `${r.currency} ${r.budget.toLocaleString()}` },
      { header: "Avg Completion %", accessor: (r: ComputedRow) => r.avgCompletion.toFixed(1) },
      { header: "Earned (Actual)", accessor: (r: ComputedRow) => `${r.currency} ${r.actual.toLocaleString(undefined, { maximumFractionDigits: 0 })}` },
      { header: "Variance (Budget - Earned)", accessor: (r: ComputedRow) => `${r.currency} ${r.variance.toLocaleString(undefined, { maximumFractionDigits: 0 })}` },
      { header: "Utilization %", accessor: (r: ComputedRow) => r.utilization.toFixed(1) },
      { header: "Tasks", accessor: (r: ComputedRow) => r.taskCount },
      { header: "Milestones", accessor: (r: ComputedRow) => r.milestoneCount },
    ];
    exportReportToExcel(`pmo-budget-vs-actual-${new Date().toISOString().slice(0, 10)}`, "Budget vs Actual", cols as any, filtered);
  };

  const handleExportPdf = () => {
    const cols = [
      { header: "Project", accessor: (r: ComputedRow) => r.name },
      { header: "Status", accessor: (r: ComputedRow) => r.status },
      { header: "Budget", accessor: (r: ComputedRow) => `${r.currency} ${r.budget.toLocaleString()}` },
      { header: "Completion", accessor: (r: ComputedRow) => `${r.avgCompletion.toFixed(1)}%` },
      { header: "Earned", accessor: (r: ComputedRow) => `${r.currency} ${Math.round(r.actual).toLocaleString()}` },
      { header: "Variance", accessor: (r: ComputedRow) => `${r.currency} ${Math.round(r.variance).toLocaleString()}` },
      { header: "Util %", accessor: (r: ComputedRow) => `${r.utilization.toFixed(1)}%` },
    ];
    exportReportToPdf(
      `pmo-budget-vs-actual-${new Date().toISOString().slice(0, 10)}.pdf`,
      "Budget vs Actual Report",
      cols as any,
      filtered,
      `Total Budget: UGX ${totals.totalBudget.toLocaleString()} • Earned: UGX ${Math.round(totals.totalActual).toLocaleString()} • Variance: UGX ${Math.round(totals.totalVariance).toLocaleString()} • Avg Util ${totals.avgUtil.toFixed(1)}%`
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
            Budget vs Actual
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 700 }}>
            Earned-value view: <strong>Actual (Earned) = Budget × Avg Completion %</strong> (tasks 70% + milestones 30% when both exist).
            Replace with real cost-ledger integration (e.g. <code>supplier_invoices</code> / <code>expenditure_slips</code> linked to project cost center) when Finance rollup lands.
          </Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1, alignItems: "center", flexWrap: "wrap" }}>
          <TextField select size="small" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} sx={{ minWidth: 140 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="not_started">Not Started</MenuItem>
            <MenuItem value="in_progress">In Progress</MenuItem>
            <MenuItem value="on_hold">On Hold</MenuItem>
            <MenuItem value="completed">Completed</MenuItem>
            <MenuItem value="cancelled">Cancelled</MenuItem>
          </TextField>
          <Button size="small" variant="outlined" startIcon={<Refresh />} onClick={fetch}>
            Refresh
          </Button>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExportExcel} disabled={filtered.length === 0}>
            Excel
          </Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPdf} disabled={filtered.length === 0}>
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
                Total Budget (filtered)
              </Typography>
              <Typography variant="h6" fontWeight={700}>
                UGX {totals.totalBudget.toLocaleString()}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {filtered.length} projects
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="caption" color="text.secondary">
                Earned (Actual)
              </Typography>
              <Typography variant="h6" fontWeight={700}>
                UGX {Math.round(totals.totalActual).toLocaleString()}
              </Typography>
              <LinearProgress variant="determinate" value={Math.min(100, totals.avgUtil)} sx={{ mt: 1, height: 6 }} />
              <Typography variant="caption">{totals.avgUtil.toFixed(1)}% avg utilization</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card variant="outlined" sx={{ bgcolor: totals.totalVariance < 0 ? "error.light" : "success.light" }}>
            <CardContent>
              <Typography variant="caption">Variance (Budget − Earned)</Typography>
              <Typography variant="h6" fontWeight={700} color={totals.totalVariance < 0 ? "error.main" : "success.main"}>
                UGX {Math.round(totals.totalVariance).toLocaleString()}
              </Typography>
              <Typography variant="caption">{totals.totalVariance < 0 ? "Overspent (forecast)" : "Remaining / under"}</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="caption" color="text.secondary">
                Projects Over Forecast
              </Typography>
              <Typography variant="h4" fontWeight={700}>
                {totals.overBudget}
              </Typography>
              <Typography variant="caption">variance &lt; 0</Typography>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Project</TableCell>
                <TableCell>Status</TableCell>
                <TableCell align="right">Budget</TableCell>
                <TableCell>Completion</TableCell>
                <TableCell align="right">Earned (Actual)</TableCell>
                <TableCell align="right">Variance</TableCell>
                <TableCell>Utilization</TableCell>
                <TableCell>Tasks / MS</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={8} sx={{ textAlign: "center", py: 5 }}>
                    <Typography color="text.secondary">No projects for this filter. Set budget on New Project and add tasks/milestones to see earned value.</Typography>
                  </TableCell>
                </TableRow>
              ) : (
                filtered.map((p) => {
                  const over = p.variance < 0;
                  return (
                    <TableRow key={p.id} hover>
                      <TableCell>
                        <Typography fontWeight={600}>{p.name}</Typography>
                        <Typography variant="caption" color="text.secondary" fontFamily="monospace">
                          {p.id.slice(0, 8)}
                        </Typography>
                      </TableCell>
                      <TableCell>
                        <Chip label={p.status} size="small" sx={{ textTransform: "capitalize" }} />
                      </TableCell>
                      <TableCell align="right">
                        {p.currency} {p.budget.toLocaleString()}
                      </TableCell>
                      <TableCell sx={{ minWidth: 150 }}>
                        <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                          <LinearProgress variant="determinate" value={p.avgCompletion} sx={{ flex: 1, height: 6 }} />
                          <Typography variant="caption">{p.avgCompletion.toFixed(0)}%</Typography>
                        </Box>
                        <Typography variant="caption" color="text.secondary">
                          {p.taskCount} tasks • {p.milestoneCount} milestones
                        </Typography>
                      </TableCell>
                      <TableCell align="right">
                        {p.currency} {Math.round(p.actual).toLocaleString()}
                      </TableCell>
                      <TableCell align="right" sx={{ color: over ? "error.main" : "success.main", fontWeight: 600 }}>
                        {p.currency} {Math.round(p.variance).toLocaleString()}
                      </TableCell>
                      <TableCell sx={{ minWidth: 120 }}>
                        <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                          <LinearProgress variant="determinate" value={Math.min(100, p.utilization)} sx={{ flex: 1, height: 6 }} color={over ? "error" : "primary"} />
                          <Typography variant="caption">{p.utilization.toFixed(0)}%</Typography>
                        </Box>
                      </TableCell>
                      <TableCell>
                        {p.taskCount} / {p.milestoneCount}
                      </TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Alert severity="info" sx={{ mt: 2 }}>
        <Typography variant="caption">
          <strong>Methodology:</strong> Budget is from <code>pmo_projects.budget</code>. Actual is <em>earned value</em> (budget × avg completion %). Avg completion
          is average <code>completion_percent</code> across tasks (and milestones blended 70/30). When a real cost ledger exists, replace this with
          <code>SUM(supplier_invoices/expenditure_slips WHERE cost_center linked to project)</code> — see Finance's <code>v_cost_transactions_inquiry</code> pattern.
        </Typography>
      </Alert>
    </Box>
  );
}
