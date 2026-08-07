import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, IconButton, Tooltip } from "@mui/material";
import { Add, Visibility } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Project {
  id: string;
  project_no: string;
  name: string;
  status: string;
  budget: number | null;
  currency: string;
  start_date: string | null;
  end_date: string | null;
  created_at: string;
  project_categories?: { name: string } | null;
}

export default function ProjectsList() {
  const navigate = useNavigate();
  const [projects, setProjects] = useState<Project[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("pmo_projects").select("*, pmo_project_categories(name)").order("created_at", { ascending: false });
      if (data) setProjects(data as Project[]);
      setLoading(false);
    };
    fetch();
  }, []);

  const getStatusColor = (s: string) => {
    if (s === 'in_progress') return 'primary';
    if (s === 'completed') return 'success';
    if (s === 'on_hold') return 'warning';
    if (s === 'cancelled') return 'error';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Projects</Typography><Typography variant="body2" color="text.secondary">{projects.length} projects • Project No auto PMO-P-2026-0001</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/pmo/projects/new")}>New Project</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Project No</TableCell><TableCell>Name</TableCell><TableCell>Category</TableCell><TableCell>Status</TableCell><TableCell>Budget</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell align="right">View</TableCell></TableRow></TableHead><TableBody>{projects.length === 0 ? <TableRow><TableCell colSpan={8} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No projects yet. Create first via New Project — needs Category lookup you built.</Typography></TableCell></TableRow> : projects.map(p => <TableRow key={p.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{p.project_no || p.id.slice(0,8)}</Typography></TableCell><TableCell><Typography fontWeight={600}>{p.name}</Typography></TableCell><TableCell><Chip label={p.project_categories?.name || "-"} size="small" variant="outlined" /></TableCell><TableCell><Chip label={p.status} size="small" color={getStatusColor(p.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{p.budget ? `${p.currency} ${Number(p.budget).toLocaleString()}` : "-"}</TableCell><TableCell>{p.start_date ? new Date(p.start_date).toLocaleDateString() : "-"}</TableCell><TableCell>{p.end_date ? new Date(p.end_date).toLocaleDateString() : "-"}</TableCell><TableCell align="right"><Tooltip title="View"><IconButton size="small" onClick={() => navigate(`/pmo/projects/${p.id}`)}><Visibility fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}