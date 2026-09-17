import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, IconButton, Tooltip, Alert } from "@mui/material";
import { CheckCircle } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function MaintenanceSchedule() {
  const [schedule, setSchedule] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchData = async () => {
    setLoading(true);
    const { data } = await supabase.from("maintenance_requests").select("*, machines(name, machine_no)").eq("status", "scheduled").order("scheduled_date", { ascending: true }).limit(200);
    if (data) {
      const normalized = (data as any[]).map((r: any) => ({
        ...r,
        machines: Array.isArray(r.machines) ? r.machines[0] ?? null : r.machines ?? null,
      }));
      setSchedule(normalized);
    }
    setLoading(false);
  };
  useEffect(() => { fetchData(); }, []);

  const markInProgress = async (row: any) => {
    const { error } = await supabase.from("maintenance_requests").update({ status: "in_progress" }).eq("id", row.id);
    if (error) alert(error.message);
    else fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const today = new Date().toISOString().slice(0, 10);
  const overdue = schedule.filter(s => s.scheduled_date && s.scheduled_date < today).length;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Maintenance Schedule</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>Preventive maintenance calendar — scheduled items only. {schedule.length} scheduled{overdue ? ` • ${overdue} overdue` : ""}.</Typography>
      {overdue > 0 && <Alert severity="warning" sx={{ mb: 2 }}>{overdue} scheduled maintenance item(s) are overdue (scheduled date before today).</Alert>}
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Scheduled Date</TableCell><TableCell>Status</TableCell><TableCell>Description</TableCell><TableCell align="right">Start</TableCell></TableRow></TableHead><TableBody>{schedule.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No scheduled maintenance yet. Create requests with status scheduled and scheduled_date.</Typography></TableCell></TableRow> : schedule.map(s => {
        const isOverdue = !!(s.scheduled_date && s.scheduled_date < today);
        return <TableRow key={s.id} hover sx={isOverdue ? { bgcolor: "error.lighter", "& td": { bgcolor: "rgba(211,47,47,0.06)" } } : undefined}><TableCell>{s.machines ? `${s.machines.machine_no} - ${s.machines.name}` : "-"}</TableCell><TableCell><Chip label={s.type} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell><Chip label={s.scheduled_date ? new Date(s.scheduled_date).toLocaleDateString() : "-"} size="small" color={isOverdue ? "error" : "default"} />{isOverdue && <Chip label="Overdue" size="small" color="error" sx={{ ml: 1 }} />}</TableCell><TableCell><Chip label={s.status} size="small" color="warning" /></TableCell><TableCell><Typography variant="body2" sx={{ maxWidth: 350, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{s.description || "-"}</Typography></TableCell><TableCell align="right"><Tooltip title="Mark In Progress"><IconButton size="small" aria-label="Mark in progress" onClick={() => markInProgress(s)}><CheckCircle fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
