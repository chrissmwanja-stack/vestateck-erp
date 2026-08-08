import { useEffect, useState } from "react";
import { Box, Card, CardContent, Typography, Chip, LinearProgress, Tooltip, CircularProgress } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Task {
  id: string;
  title: string;
  status: string;
  start_date: string | null;
  due_date: string | null;
  completion_percent?: number | null;
  pmo_projects?: { name: string } | null;
}

interface Milestone {
  id: string;
  title: string;
  due_date: string | null;
  completion_percent: number;
  pmo_projects?: { name: string } | null;
}

export default function GanttChart() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [milestones, setMilestones] = useState<Milestone[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const [tasksRes, milestonesRes] = await Promise.all([
        supabase.from("pmo_tasks").select("id, title, status, start_date, due_date, pmo_projects(name)").order("due_date", { ascending: true }).limit(50),
        supabase.from("pmo_milestones").select("id, title, due_date, completion_percent, pmo_projects(name)").order("due_date", { ascending: true }).limit(20),
      ]);

      // Normalize PostgREST to-one join that sometimes returns as array [{name}] instead of {name}
      const normalizedTasks = ((tasksRes.data as any[]) || []).map((t: any) => ({
        ...t,
        pmo_projects: Array.isArray(t.pmo_projects) ? t.pmo_projects[0] ?? null : t.pmo_projects ?? null,
      })) as Task[];

      const normalizedMilestones = ((milestonesRes.data as any[]) || []).map((m: any) => ({
        ...m,
        pmo_projects: Array.isArray(m.pmo_projects) ? m.pmo_projects[0] ?? null : m.pmo_projects ?? null,
      })) as Milestone[];

      setTasks(normalizedTasks);
      setMilestones(normalizedMilestones);
      setLoading(false);
    };
    fetch();
  }, []);

  const getStatusColor = (s: string) => {
    if (s === 'done' || s === 'completed') return 'success.main';
    if (s === 'in_progress') return 'primary.main';
    if (s === 'review') return 'warning.main';
    return 'grey.400';
  };

  const getProgress = (t: Task) => {
    if ((t as any).completion_percent !== undefined && (t as any).completion_percent !== null) return (t as any).completion_percent;
    if (t.status === 'done') return 100;
    if (t.status === 'in_progress') return 50;
    if (t.status === 'review') return 75;
    return 10;
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const allItems = [
    ...tasks.map(t => ({ type: 'task' as const, id: t.id, title: t.title, project: t.pmo_projects?.name, start: t.start_date, end: t.due_date, status: t.status, progress: getProgress(t) })),
    ...milestones.map(m => ({ type: 'milestone' as const, id: m.id, title: m.title, project: m.pmo_projects?.name, start: null, end: m.due_date, status: 'milestone', progress: m.completion_percent })),
  ].sort((a, b) => {
    const aDate = a.end ? new Date(a.end).getTime() : 0;
    const bDate = b.end ? new Date(b.end).getTime() : 0;
    return aDate - bDate;
  });

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Gantt Chart</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Timeline view of {tasks.length} tasks and {milestones.length} milestones. Shows project, progress, due dates. Real implementation would use gantt-task-react library with dependencies — this is custom timeline from pmo_tasks + pmo_milestones.
      </Typography>

      <Card variant="outlined">
        <CardContent>
          <Box sx={{ display: "flex", gap: 1, mb: 2, flexWrap: "wrap" }}>
            <Chip label={`${tasks.length} Tasks`} size="small" />
            <Chip label={`${milestones.length} Milestones`} size="small" color="primary" variant="outlined" />
            <Chip label="Progress bar = completion %" size="small" variant="outlined" />
          </Box>

          <Box sx={{ display: "flex", flexDirection: "column", gap: 1.5 }}>
            {allItems.length === 0 ? (
              <Typography color="text.secondary" sx={{ textAlign: "center", py: 6 }}>No tasks or milestones for Gantt. Create tasks with start_date + due_date and milestones with due_date to see timeline.</Typography>
            ) : (
              allItems.map((item) => (
                <Box key={`${item.type}-${item.id}`} sx={{ display: "flex", alignItems: "center", gap: 2, p: 1.5, border: "1px solid", borderColor: "divider", borderRadius: 1, bgcolor: item.type === 'milestone' ? "warning.light" : "white" }}>
                  <Box sx={{ minWidth: 20, display: "flex", justifyContent: "center" }}>
                    {item.type === 'milestone' ? <Box sx={{ width: 12, height: 12, bgcolor: "warning.main", transform: "rotate(45deg)" }} /> : <Box sx={{ width: 8, height: 8, borderRadius: "50%", bgcolor: getStatusColor(item.status) }} />}
                  </Box>
                  <Box sx={{ minWidth: 220, maxWidth: 280 }}>
                    <Typography variant="body2" fontWeight={600} noWrap>{item.title}</Typography>
                    <Typography variant="caption" color="text.secondary" noWrap>{item.project || "No project"} • {item.type === 'milestone' ? "Milestone" : "Task"}</Typography>
                  </Box>
                  <Box sx={{ flex: 1, minWidth: 200 }}>
                    <Tooltip title={`${item.progress}%`}>
                      <LinearProgress variant="determinate" value={item.progress} sx={{ height: 10, borderRadius: 1, bgcolor: "grey.200", "& .MuiLinearProgress-bar": { bgcolor: getStatusColor(item.status) } }} />
                    </Tooltip>
                  </Box>
                  <Box sx={{ minWidth: 100, textAlign: "right" }}>
                    <Typography variant="caption" color="text.secondary">{item.end ? new Date(item.end).toLocaleDateString() : "No due date"}</Typography>
                    <Chip label={`${item.progress}%`} size="small" sx={{ ml: 1, height: 18, fontSize: 10 }} />
                  </Box>
                  <Chip label={item.status} size="small" variant={item.type === 'milestone' ? "filled" : "outlined"} color={item.type === 'milestone' ? "warning" : item.status === 'done' ? "success" : "default"} sx={{ textTransform: "capitalize", minWidth: 80 }} />
                </Box>
              ))
            )}
          </Box>

          <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}>
            <Typography variant="caption" fontWeight={600}>Real Gantt implementation notes:</Typography>
            <Typography variant="caption" component="div" color="text.secondary">
              <ul style={{ margin: "4px 0", paddingLeft: "18px" }}>
                <li>This custom timeline uses tasks.start_date + due_date and milestones.due_date from pmo_tasks + pmo_milestones tables</li>
                <li>For full Gantt with dependencies, drag, critical path: install gantt-task-react and map tasks to {`{start: Date, end: Date, progress, dependencies}`}</li>
                <li>Next: Add dialog to create task with start/end dates, add dependencies selector</li>
              </ul>
            </Typography>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}
