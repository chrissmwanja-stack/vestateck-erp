import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function EquipmentList() {
  const [machines, setMachines] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("machines").select("*, machine_types(name)").order("created_at", { ascending: false }).limit(100);
      if (data) setMachines(data);
      setLoading(false);
    };
    fetch();
  }, []);

  const getStatusColor = (s: string) => {
    if (s === 'available') return 'success';
    if (s === 'in_use') return 'primary';
    if (s === 'breakdown') return 'error';
    return 'warning';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Equipment List</Typography><Typography variant="body2" color="text.secondary">{machines.length} machines</Typography></Box>
        <Button variant="contained" startIcon={<Add />} disabled>New Equipment</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine No</TableCell><TableCell>Name</TableCell><TableCell>Type</TableCell><TableCell>Status</TableCell><TableCell>Location</TableCell></TableRow></TableHead><TableBody>{machines.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No machines yet. Create via New Equipment or import. Needs machine_types lookup.</Typography></TableCell></TableRow> : machines.map(m => <TableRow key={m.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{m.machine_no || m.id.slice(0,8)}</Typography></TableCell><TableCell>{m.name}</TableCell><TableCell>{m.machine_types?.name || "-"}</TableCell><TableCell><Chip label={m.status} size="small" color={getStatusColor(m.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{m.location || "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
