import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function MaintenanceRequests() {
  const [requests, setRequests] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("maintenance_requests").select("*, machines(name, machine_no)").order("created_at", { ascending: false }).limit(100);
      if (data) setRequests(data);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Maintenance Requests</Typography><Typography variant="body2" color="text.secondary">{requests.length} requests</Typography></Box>
        <Button variant="contained" startIcon={<Add />} disabled>New Request</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Description</TableCell><TableCell>Status</TableCell><TableCell>Scheduled</TableCell></TableRow></TableHead><TableBody>{requests.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No maintenance requests yet. Create breakdown or preventive requests.</Typography></TableCell></TableRow> : requests.map(r => <TableRow key={r.id} hover><TableCell>{r.machines ? `${r.machines.machine_no} - ${r.machines.name}` : "-"}</TableCell><TableCell>{r.type}</TableCell><TableCell>{r.description?.slice(0,80) || "-"}</TableCell><TableCell><Chip label={r.status} size="small" /></TableCell><TableCell>{r.scheduled_date ? new Date(r.scheduled_date).toLocaleDateString() : "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
