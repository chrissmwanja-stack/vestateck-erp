import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function MaintenanceSchedule() {
  const [schedule, setSchedule] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("maintenance_requests").select("*, machines(name, machine_no)").eq("status", "scheduled").order("scheduled_date", { ascending: true }).limit(100);
      if (data) {
        const normalized = (data as any[]).map((r: any) => ({
          ...r,
          machines: Array.isArray(r.machines) ? r.machines[0] ?? null : r.machines ?? null,
        }));
        setSchedule(normalized);
      }
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Maintenance Schedule</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Preventive maintenance calendar, scheduled date, status scheduled. {schedule.length} scheduled.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Scheduled Date</TableCell><TableCell>Status</TableCell><TableCell>Description</TableCell></TableRow></TableHead><TableBody>{schedule.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No scheduled maintenance yet. Create requests with status scheduled and scheduled_date.</Typography></TableCell></TableRow> : schedule.map(s => <TableRow key={s.id} hover><TableCell>{s.machines ? `${s.machines.machine_no} - ${s.machines.name}` : "-"}</TableCell><TableCell><Chip label={s.type} size="small" variant="outlined" /></TableCell><TableCell>{s.scheduled_date ? new Date(s.scheduled_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={s.status} size="small" color="warning" /></TableCell><TableCell><Typography variant="body2" sx={{ maxWidth: 300, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{s.description || "-"}</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
