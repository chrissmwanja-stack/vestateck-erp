import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function MaintenanceHistory() {
  const [history, setHistory] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("maintenance_requests").select("*, machines(name, machine_no)").eq("status", "completed").order("updated_at", { ascending: false }).limit(100);
      if (data) {
        const normalized = (data as any[]).map((r: any) => ({
          ...r,
          machines: Array.isArray(r.machines) ? r.machines[0] ?? null : r.machines ?? null,
        }));
        setHistory(normalized);
      }
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Maintenance History</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Past completed maintenance, cost, downtime from maintenance_requests status completed.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Completed Date</TableCell><TableCell>Description</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{history.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No history yet. Completed maintenance requests appear here.</Typography></TableCell></TableRow> : history.map(h => <TableRow key={h.id} hover><TableCell>{h.machines ? `${h.machines.machine_no} - ${h.machines.name}` : "-"}</TableCell><TableCell>{h.type}</TableCell><TableCell>{h.updated_at ? new Date(h.updated_at).toLocaleDateString() : "-"}</TableCell><TableCell><Typography variant="body2" sx={{ maxWidth: 350, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{h.description || "-"}</Typography></TableCell><TableCell><Chip label={h.status} size="small" color="success" /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
