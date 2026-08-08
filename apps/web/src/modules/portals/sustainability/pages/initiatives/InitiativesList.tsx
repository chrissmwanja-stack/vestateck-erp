import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, LinearProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { Add } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

export default function InitiativesList() {
  const navigate = useNavigate();
  const [initiatives, setInitiatives] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchInitiatives = async () => {
    setLoading(true);
    const { data } = await supabase.from("sustainability_initiatives").select("*, sustainability_initiative_categories(name)").order("created_at", { ascending: false });
    if (data) setInitiatives(data);
    setLoading(false);
  };

  useEffect(() => { fetchInitiatives(); }, []);

  const getStatusColor = (s: string) => {
    if (s === 'completed') return 'success';
    if (s === 'in_progress') return 'primary';
    if (s === 'on_hold') return 'warning';
    return 'default';
  };

  const getProgress = (current: number | null, target: number | null) => {
    if (!target || target === 0 || current === null) return 0;
    return Math.min(100, (current / target) * 100);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Initiatives</Typography><Typography variant="body2" color="text.secondary">{initiatives.length} sustainability initiatives • Tracks target vs current progress.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/sustainability/initiatives/new")}>New Initiative</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Category</TableCell><TableCell>Status</TableCell><TableCell>Owner</TableCell><TableCell>Target / Current</TableCell><TableCell>Progress</TableCell></TableRow></TableHead><TableBody>{initiatives.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No initiatives yet. Create in New Initiative — needs category lookup from Admin → Initiative Categories.</Typography></TableCell></TableRow> : initiatives.map((i: any) => {
        const progress = getProgress(i.current_value, i.target_value);
        return <TableRow key={i.id} hover><TableCell><Typography fontWeight={600}>{i.title}</Typography></TableCell><TableCell>{i.sustainability_initiative_categories?.name || i.initiative_categories?.name || "-"}</TableCell><TableCell><Chip label={i.status} size="small" color={getStatusColor(i.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{i.owner || "-"}</TableCell><TableCell>{i.current_value ?? "-"} / {i.target_value ?? "-"}</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={progress} sx={{ flex: 1, height: 6, borderRadius: 1 }} color={progress >= 100 ? "success" : "primary"} /><Typography variant="caption">{progress.toFixed(0)}%</Typography></Box></TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
