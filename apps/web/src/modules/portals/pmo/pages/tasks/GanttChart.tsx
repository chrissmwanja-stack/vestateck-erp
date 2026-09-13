import { useEffect, useMemo, useState } from "react";
import { Box, Card, CardContent, Typography, Chip, Tooltip, CircularProgress, Alert } from "@mui/material";
import { AccountTree } from "@mui/icons-material";
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

interface Dependency {
  predecessor_task_id: string;
  successor_task_id: string;
}

// Chart-ready row: tasks and milestones normalized to a shared shape so the
// timeline layout code doesn't need to branch on type everywhere. Tasks with
// no start_date get start_date = due_date (renders as a single-day marker,
// same visual treatment as a milestone) -- a task with only a due date
// can't be given a meaningful bar width, and dropping it from the chart
// entirely would hide real work from the timeline.
interface ChartRow {
  type: 'task' | 'milestone';
  id: string;
  title: string;
  project: string;
  start: Date | null;
  end: Date | null;
  status: string;
  progress: number;
}

const DAY_MS = 24 * 60 * 60 * 1000;
const DAY_WIDTH_PX = 28;
const LABEL_COL_WIDTH_PX = 260;
const RANGE_PADDING_DAYS = 3;

function toDate(d: string | null): Date | null {
  if (!d) return null;
  // date columns come back as 'YYYY-MM-DD' -- parsing as local midnight
  // (not UTC) keeps the displayed date matching what was actually stored,
  // since new Date('YYYY-MM-DD') parses as UTC midnight and can shift a
  // day backward for anyone west of UTC.
  const [y, m, day] = d.split('-').map(Number);
  return new Date(y, m - 1, day);
}

function daysBetween(a: Date, b: Date): number {
  return Math.round((b.getTime() - a.getTime()) / DAY_MS);
}

function formatShort(d: Date): string {
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

export default function GanttChart() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [milestones, setMilestones] = useState<Milestone[]>([]);
  const [dependencies, setDependencies] = useState<Dependency[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      setError(null);
      const [tasksRes, milestonesRes, dependenciesRes] = await Promise.all([
        supabase.from("pmo_tasks").select("id, title, status, start_date, due_date, completion_percent, pmo_projects(name)").order("due_date", { ascending: true }).limit(200),
        supabase.from("pmo_milestones").select("id, title, due_date, completion_percent, pmo_projects(name)").order("due_date", { ascending: true }).limit(100),
        supabase.from("pmo_task_dependencies").select("predecessor_task_id, successor_task_id").order("created_at", { ascending: true }).limit(500),
      ]);

      if (tasksRes.error || milestonesRes.error || dependenciesRes.error) {
        setError(
          tasksRes.error?.message ?? milestonesRes.error?.message ?? dependenciesRes.error?.message ?? 'Failed to load Gantt data.',
        );
        setLoading(false);
        return;
      }

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
      setDependencies((dependenciesRes.data as Dependency[]) || []);
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

  const getProgress = (t: Task) => t.completion_percent ?? 0;

  const rows: ChartRow[] = useMemo(() => {
    const taskRows: ChartRow[] = tasks.map((t) => {
      const end = toDate(t.due_date) ?? toDate(t.start_date);
      const start = toDate(t.start_date) ?? end;
      return {
        type: 'task',
        id: t.id,
        title: t.title,
        project: t.pmo_projects?.name ?? 'No project',
        start,
        end,
        status: t.status,
        progress: getProgress(t),
      };
    });
    const milestoneRows: ChartRow[] = milestones.map((m) => {
      const d = toDate(m.due_date);
      return {
        type: 'milestone',
        id: m.id,
        title: m.title,
        project: m.pmo_projects?.name ?? 'No project',
        start: d,
        end: d,
        status: 'milestone',
        progress: m.completion_percent,
      };
    });
    return [...taskRows, ...milestoneRows].filter((r) => r.start && r.end);
  }, [tasks, milestones]);

  // Dependencies only ever link two tasks (see pmo_task_dependencies'
  // FKs), and only tasks with dates appear in `rows` at all, so an edge
  // referencing a hidden/undated task is dropped here rather than
  // crashing the walk below.
  const { predecessorsOf, successorsOf, titleById } = useMemo(() => {
    const titles = new Map(rows.filter((r) => r.type === 'task').map((r) => [r.id, r.title]));
    const preds = new Map<string, string[]>();
    const succs = new Map<string, string[]>();
    for (const d of dependencies) {
      if (!titles.has(d.predecessor_task_id) || !titles.has(d.successor_task_id)) continue;
      preds.set(d.successor_task_id, [...(preds.get(d.successor_task_id) ?? []), d.predecessor_task_id]);
      succs.set(d.predecessor_task_id, [...(succs.get(d.predecessor_task_id) ?? []), d.successor_task_id]);
    }
    return { predecessorsOf: preds, successorsOf: succs, titleById: titles };
  }, [rows, dependencies]);

  // Critical path = the longest chain of dependent tasks by duration
  // (classic CPM longest-path-in-a-DAG, using each task's own
  // start_date/due_date span as its duration rather than a computed
  // schedule -- dates here are set by whoever plans the task, not
  // derived, so this highlights the longest *actual* chain rather than
  // an idealized one). The DB trigger on pmo_task_dependencies rejects
  // cycles at write time, but this still guards against one slipping
  // through (e.g. a race) by bailing out to "no critical path" instead
  // of an infinite loop.
  const { criticalTaskIds, criticalPathDays } = useMemo(() => {
    const taskRowMap = new Map(rows.filter((r) => r.type === 'task').map((r) => [r.id, r]));
    const nodes = Array.from(titleById.keys());
    if (nodes.length === 0) return { criticalTaskIds: new Set<string>(), criticalPathDays: 0 };

    const duration = (id: string) => {
      const r = taskRowMap.get(id)!;
      return Math.max(daysBetween(r.start!, r.end!) + 1, 1);
    };

    const inDegree = new Map(nodes.map((id) => [id, (predecessorsOf.get(id) ?? []).length]));
    const queue = nodes.filter((id) => (inDegree.get(id) ?? 0) === 0);
    const topoOrder: string[] = [];
    while (queue.length) {
      const n = queue.shift()!;
      topoOrder.push(n);
      for (const s of successorsOf.get(n) ?? []) {
        inDegree.set(s, (inDegree.get(s) ?? 0) - 1);
        if (inDegree.get(s) === 0) queue.push(s);
      }
    }
    if (topoOrder.length < nodes.length) return { criticalTaskIds: new Set<string>(), criticalPathDays: 0 };

    const earliestFinish = new Map<string, number>();
    const criticalPred = new Map<string, string | null>();
    for (const id of topoOrder) {
      const preds = predecessorsOf.get(id) ?? [];
      if (preds.length === 0) {
        earliestFinish.set(id, duration(id));
        criticalPred.set(id, null);
      } else {
        let best = -1;
        let bestPred: string | null = null;
        for (const p of preds) {
          const ef = earliestFinish.get(p) ?? 0;
          if (ef > best) {
            best = ef;
            bestPred = p;
          }
        }
        earliestFinish.set(id, best + duration(id));
        criticalPred.set(id, bestPred);
      }
    }

    let endNode: string | null = null;
    let maxFinish = 0;
    for (const [id, ef] of earliestFinish) {
      if (ef > maxFinish) {
        maxFinish = ef;
        endNode = id;
      }
    }

    const critical = new Set<string>();
    let cur = endNode;
    while (cur) {
      critical.add(cur);
      cur = criticalPred.get(cur) ?? null;
    }
    // A lone task with no dependency edges "wins" the longest-path walk
    // trivially -- only worth flagging as a critical *path* once it's
    // actually chained to something else.
    if (critical.size <= 1) return { criticalTaskIds: new Set<string>(), criticalPathDays: 0 };
    return { criticalTaskIds: critical, criticalPathDays: maxFinish };
  }, [rows, predecessorsOf, successorsOf, titleById]);

  const groups = useMemo(() => {
    const byProject = new Map<string, ChartRow[]>();
    for (const row of rows) {
      const list = byProject.get(row.project) ?? [];
      list.push(row);
      byProject.set(row.project, list);
    }
    return Array.from(byProject.entries())
      .map(([project, items]) => ({
        project,
        items: items.sort((a, b) => (a.start && b.start ? a.start.getTime() - b.start.getTime() : 0)),
      }))
      .sort((a, b) => a.project.localeCompare(b.project));
  }, [rows]);

  const { rangeStart, rangeEnd, totalDays, weekTicks, today, todayInRange } = useMemo(() => {
    const dates = rows.flatMap((r) => [r.start, r.end]).filter((d): d is Date => d !== null);
    const now = new Date();
    now.setHours(0, 0, 0, 0);
    if (dates.length === 0) {
      const start = new Date(now);
      start.setDate(start.getDate() - RANGE_PADDING_DAYS);
      const end = new Date(now);
      end.setDate(end.getDate() + 30);
      return { rangeStart: start, rangeEnd: end, totalDays: daysBetween(start, end), weekTicks: [], today: now, todayInRange: true };
    }
    const minD = new Date(Math.min(...dates.map((d) => d.getTime())));
    const maxD = new Date(Math.max(...dates.map((d) => d.getTime())));
    const start = new Date(minD);
    start.setDate(start.getDate() - RANGE_PADDING_DAYS);
    const end = new Date(maxD);
    end.setDate(end.getDate() + RANGE_PADDING_DAYS);
    const total = Math.max(daysBetween(start, end), 1);

    const ticks: { date: Date; leftPct: number }[] = [];
    const tick = new Date(start);
    // Align the first tick to a Monday so week columns land on consistent
    // boundaries regardless of where the padded range happens to start.
    const dayOfWeek = tick.getDay();
    tick.setDate(tick.getDate() + ((8 - dayOfWeek) % 7));
    while (tick <= end) {
      ticks.push({ date: new Date(tick), leftPct: (daysBetween(start, tick) / total) * 100 });
      tick.setDate(tick.getDate() + 7);
    }

    return {
      rangeStart: start,
      rangeEnd: end,
      totalDays: total,
      weekTicks: ticks,
      today: now,
      todayInRange: now >= start && now <= end,
    };
  }, [rows]);

  const leftPct = (d: Date) => (daysBetween(rangeStart, d) / totalDays) * 100;
  const widthPct = (start: Date, end: Date) => Math.max((daysBetween(start, end) / totalDays) * 100, 0);
  const todayLeftPct = todayInRange ? (daysBetween(rangeStart, today) / totalDays) * 100 : null;

  const timelineWidthPx = totalDays * DAY_WIDTH_PX;
  const totalWidthPx = LABEL_COL_WIDTH_PX + timelineWidthPx;
  const ROW_HEIGHT_PX = 40;
  const HEADER_HEIGHT_PX = 32;

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1400 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Gantt Chart</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Timeline view of {tasks.length} tasks and {milestones.length} milestones, grouped by project. Bars run
        start_date → due_date; milestones and tasks without a start_date show as a marker at their due date. Tasks
        with dependencies show a link icon (hover for what they wait on or block), and the longest dependency chain
        is outlined as the critical path.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Card variant="outlined">
        <CardContent>
          <Box sx={{ display: "flex", gap: 1, mb: 2, flexWrap: "wrap" }}>
            <Chip label={`${tasks.length} Tasks`} size="small" />
            <Chip label={`${milestones.length} Milestones`} size="small" color="primary" variant="outlined" />
            {rows.length < tasks.length + milestones.length && (
              <Chip
                label={`${tasks.length + milestones.length - rows.length} without dates hidden`}
                size="small"
                variant="outlined"
              />
            )}
            {rows.length > 0 && (
              <Chip
                label={`${formatShort(rangeStart)} – ${formatShort(rangeEnd)}`}
                size="small"
                variant="outlined"
              />
            )}
            {criticalTaskIds.size > 0 && (
              <Chip
                label={`Critical path: ${criticalPathDays}d across ${criticalTaskIds.size} tasks`}
                size="small"
                color="error"
                variant="outlined"
              />
            )}
          </Box>

          {rows.length === 0 ? (
            <Typography color="text.secondary" sx={{ textAlign: "center", py: 6 }}>
              No tasks or milestones with dates yet. Add a start_date + due_date to a task or a due_date to a
              milestone to see it on the timeline.
            </Typography>
          ) : (
            <Box sx={{ overflowX: "auto", border: "1px solid", borderColor: "divider", borderRadius: 1 }}>
              <Box sx={{ minWidth: totalWidthPx, position: "relative" }}>
                {/* Today marker -- spans the full grid height, positioned in
                    a single absolute box rather than per-row so it draws as
                    one continuous line instead of N misaligned fragments. */}
                {todayLeftPct !== null && (
                  <Tooltip title={`Today — ${formatShort(today)}`}>
                    <Box
                      sx={{
                        position: "absolute",
                        top: 0,
                        bottom: 0,
                        left: `calc(${LABEL_COL_WIDTH_PX}px + (100% - ${LABEL_COL_WIDTH_PX}px) * ${todayLeftPct / 100})`,
                        width: "2px",
                        bgcolor: "error.main",
                        opacity: 0.6,
                        zIndex: 4,
                        pointerEvents: "none",
                      }}
                    />
                  </Tooltip>
                )}

                {/* Header: sticky label cell + week-tick date axis */}
                <Box
                  sx={{
                    display: "flex",
                    height: HEADER_HEIGHT_PX,
                    borderBottom: "1px solid",
                    borderColor: "divider",
                    position: "sticky",
                    top: 0,
                    bgcolor: "background.paper",
                    zIndex: 3,
                  }}
                >
                  <Box
                    sx={{
                      width: LABEL_COL_WIDTH_PX,
                      flexShrink: 0,
                      position: "sticky",
                      left: 0,
                      bgcolor: "background.paper",
                      zIndex: 3,
                      borderRight: "1px solid",
                      borderColor: "divider",
                      display: "flex",
                      alignItems: "center",
                      px: 1.5,
                    }}
                  >
                    <Typography variant="caption" fontWeight={700} color="text.secondary">
                      TASK / MILESTONE
                    </Typography>
                  </Box>
                  <Box sx={{ position: "relative", flex: 1 }}>
                    {weekTicks.map((t) => (
                      <Box
                        key={t.date.toISOString()}
                        sx={{
                          position: "absolute",
                          left: `${t.leftPct}%`,
                          top: 0,
                          bottom: 0,
                          borderLeft: "1px solid",
                          borderColor: "divider",
                          pl: 0.5,
                          display: "flex",
                          alignItems: "center",
                        }}
                      >
                        <Typography variant="caption" color="text.secondary" noWrap>
                          {formatShort(t.date)}
                        </Typography>
                      </Box>
                    ))}
                  </Box>
                </Box>

                {/* Rows, grouped by project */}
                {groups.map((group) => (
                  <Box key={group.project}>
                    <Box
                      sx={{
                        display: "flex",
                        height: ROW_HEIGHT_PX * 0.75,
                        alignItems: "center",
                        bgcolor: "grey.100",
                        position: "sticky",
                        left: 0,
                        zIndex: 1,
                        width: "fit-content",
                        minWidth: "100%",
                        px: 1.5,
                      }}
                    >
                      <Typography variant="caption" fontWeight={700}>
                        {group.project} ({group.items.length})
                      </Typography>
                    </Box>
                    {group.items.map((item) => (
                      <Box
                        key={`${item.type}-${item.id}`}
                        sx={{
                          display: "flex",
                          alignItems: "center",
                          height: ROW_HEIGHT_PX,
                          borderBottom: "1px solid",
                          borderColor: "divider",
                          "&:hover": { bgcolor: "action.hover" },
                        }}
                      >
                        <Box
                          sx={{
                            width: LABEL_COL_WIDTH_PX,
                            flexShrink: 0,
                            position: "sticky",
                            left: 0,
                            bgcolor: "background.paper",
                            zIndex: 2,
                            borderRight: "1px solid",
                            borderColor: "divider",
                            display: "flex",
                            alignItems: "center",
                            gap: 1,
                            px: 1.5,
                            minWidth: 0,
                          }}
                        >
                          {item.type === "milestone" ? (
                            <Box sx={{ width: 10, height: 10, bgcolor: "warning.main", transform: "rotate(45deg)", flexShrink: 0 }} />
                          ) : (
                            <Box
                              sx={{
                                width: 8,
                                height: 8,
                                borderRadius: "50%",
                                bgcolor: getStatusColor(item.status),
                                flexShrink: 0,
                                ...(criticalTaskIds.has(item.id) && { outline: "2px solid", outlineColor: "error.main", outlineOffset: "1px" }),
                              }}
                            />
                          )}
                          <Typography variant="body2" noWrap title={item.title}>
                            {item.title}
                          </Typography>
                          {item.type === "task" && (predecessorsOf.has(item.id) || successorsOf.has(item.id)) && (
                            <Tooltip
                              title={[
                                predecessorsOf.get(item.id)?.length
                                  ? `Waits on: ${predecessorsOf.get(item.id)!.map((id) => titleById.get(id)).join(', ')}`
                                  : null,
                                successorsOf.get(item.id)?.length
                                  ? `Blocks: ${successorsOf.get(item.id)!.map((id) => titleById.get(id)).join(', ')}`
                                  : null,
                              ]
                                .filter(Boolean)
                                .join(' • ')}
                            >
                              <AccountTree sx={{ fontSize: 14, color: "text.secondary", flexShrink: 0 }} />
                            </Tooltip>
                          )}
                        </Box>
                        <Box sx={{ position: "relative", flex: 1, height: "100%" }}>
                          {item.type === "milestone" ? (
                            <Tooltip title={`${item.title} — ${item.end ? formatShort(item.end) : ''} (${item.progress}%)`}>
                              <Box
                                sx={{
                                  position: "absolute",
                                  left: `${leftPct(item.end!)}%`,
                                  top: "50%",
                                  width: 14,
                                  height: 14,
                                  bgcolor: "warning.main",
                                  border: "2px solid",
                                  borderColor: "warning.dark",
                                  transform: "translate(-50%, -50%) rotate(45deg)",
                                }}
                              />
                            </Tooltip>
                          ) : (
                            <Tooltip
                              title={`${item.title} — ${item.start ? formatShort(item.start) : ''} to ${item.end ? formatShort(item.end) : ''} (${item.progress}%)${criticalTaskIds.has(item.id) ? ' — critical path' : ''}`}
                            >
                              <Box
                                sx={{
                                  position: "absolute",
                                  left: `${leftPct(item.start!)}%`,
                                  width: `${Math.max(widthPct(item.start!, item.end!), 100 / timelineWidthPx * 6)}%`,
                                  minWidth: 6,
                                  top: "50%",
                                  transform: "translateY(-50%)",
                                  height: 18,
                                  borderRadius: 0.5,
                                  bgcolor: "grey.200",
                                  overflow: "hidden",
                                  ...(criticalTaskIds.has(item.id) && { border: "1px solid", borderColor: "error.main" }),
                                }}
                              >
                                <Box
                                  sx={{
                                    height: "100%",
                                    width: `${item.progress}%`,
                                    bgcolor: getStatusColor(item.status),
                                  }}
                                />
                              </Box>
                            </Tooltip>
                          )}
                        </Box>
                      </Box>
                    ))}
                  </Box>
                ))}
              </Box>
            </Box>
          )}

          <Box sx={{ mt: 2, display: "flex", gap: 2, alignItems: "center", flexWrap: "wrap" }}>
            <Box sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
              <Box sx={{ width: 10, height: 10, borderRadius: "50%", bgcolor: "primary.main" }} />
              <Typography variant="caption" color="text.secondary">In progress</Typography>
            </Box>
            <Box sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
              <Box sx={{ width: 10, height: 10, borderRadius: "50%", bgcolor: "warning.main" }} />
              <Typography variant="caption" color="text.secondary">Review</Typography>
            </Box>
            <Box sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
              <Box sx={{ width: 10, height: 10, borderRadius: "50%", bgcolor: "success.main" }} />
              <Typography variant="caption" color="text.secondary">Done</Typography>
            </Box>
            <Box sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
              <Box sx={{ width: 10, height: 10, bgcolor: "warning.main", transform: "rotate(45deg)" }} />
              <Typography variant="caption" color="text.secondary">Milestone</Typography>
            </Box>
            <Box sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
              <Box sx={{ width: 10, height: 2, bgcolor: "error.main", opacity: 0.6 }} />
              <Typography variant="caption" color="text.secondary">Today</Typography>
            </Box>
            <Box sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
              <Box sx={{ width: 10, height: 10, borderRadius: 0.5, border: "1px solid", borderColor: "error.main", bgcolor: "grey.200" }} />
              <Typography variant="caption" color="text.secondary">Critical path</Typography>
            </Box>
            <Box sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
              <AccountTree sx={{ fontSize: 12, color: "text.secondary" }} />
              <Typography variant="caption" color="text.secondary">Has dependencies</Typography>
            </Box>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}