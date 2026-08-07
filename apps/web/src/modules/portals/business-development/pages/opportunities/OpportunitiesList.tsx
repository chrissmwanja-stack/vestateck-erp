import { useEffect, useState } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  MenuItem,
  LinearProgress,
  Tooltip,
  IconButton,
} from "@mui/material";
import { Add, Visibility } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

interface Opportunity {
  id: string;
  opportunity_no: string;
  title: string;
  stage: string;
  probability: number;
  estimated_value: number;
  currency: string;
  expected_close_date: string | null;
  created_at: string;
  bd_clients?: { name: string } | null;
  bd_opportunity_stages?: { label: string; color: string } | null;
}

interface Stage {
  stage: string;
  label: string;
}

export default function OpportunitiesList() {
  const navigate = useNavigate();
  const [opps, setOpps] = useState<Opportunity[]>([]);
  const [stages, setStages] = useState<Stage[]>([]);
  const [loading, setLoading] = useState(true);
  const [stageFilter, setStageFilter] = useState("all");

  const fetchData = async () => {
    setLoading(true);
    const [oppsRes, stagesRes] = await Promise.all([
      supabase.from("bd_opportunities").select("*, bd_clients(name), bd_opportunity_stages!left(label, color)").order("created_at", { ascending: false }),
      supabase.from("bd_opportunity_stages").select("stage, label").eq("is_active", true).order("order_index"),
    ]);
    if (oppsRes.data) {
      // supabase might not join stages automatically if no FK, so handle fallback
      setOpps(oppsRes.data as Opportunity[]);
    }
    if (stagesRes.data) setStages(stagesRes.data as Stage[]);
    setLoading(false);
  };

  useEffect(() => {
    // For demo, ignore stage filter in query and filter client side to avoid FK issues
    fetchData();
  }, []);

  const filtered = stageFilter === "all" ? opps : opps.filter(o => o.stage === stageFilter);

  const totalValue = filtered.reduce((sum, o) => sum + Number(o.estimated_value), 0);
  const weightedValue = filtered.reduce((sum, o) => sum + Number(o.estimated_value) * (o.probability / 100), 0);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2, flexWrap: "wrap", gap: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Opportunities</Typography>
          <Typography variant="body2" color="text.secondary">
            {filtered.length} opportunities • Total {filtered[0]?.currency || "USD"} {totalValue.toLocaleString()} • Weighted {weightedValue.toLocaleString()}
          </Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          <Button variant="outlined" onClick={() => navigate("/business-development/opportunities/pipeline")}>Pipeline Board</Button>
          <Button variant="contained" startIcon={<Add />} onClick={() => navigate("/business-development/opportunities/new")}>New Opportunity</Button>
        </Box>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2 }}>
          <TextField select label="Stage" value={stageFilter} onChange={e => setStageFilter(e.target.value)} size="small" sx={{ minWidth: 200 }}>
            <MenuItem value="all">All Stages</MenuItem>
            {stages.map(s => <MenuItem key={s.stage} value={s.stage}>{s.label}</MenuItem>)}
          </TextField>
        </CardContent>
      </Card>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Opp No</TableCell>
                <TableCell>Title</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Stage</TableCell>
                <TableCell>Probability</TableCell>
                <TableCell>Value</TableCell>
                <TableCell>Weighted</TableCell>
                <TableCell>Close Date</TableCell>
                <TableCell align="right">View</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.length === 0 ? (
                <TableRow><TableCell colSpan={9} sx={{ textAlign: "center", py: 6 }}><Typography color="text.secondary">No opportunities yet. Create first via New Opportunity — needs Client.</Typography></TableCell></TableRow>
              ) : (
                filtered.map(o => (
                  <TableRow key={o.id} hover>
                    <TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{o.opportunity_no}</Typography></TableCell>
                    <TableCell><Typography fontWeight={600} variant="body2">{o.title}</Typography></TableCell>
                    <TableCell>{o.bd_clients?.name || "-"}</TableCell>
                    <TableCell>
                      <Chip label={o.bd_opportunity_stages?.label || o.stage} size="small" sx={{ bgcolor: o.bd_opportunity_stages?.color || "#eee", color: "#000" }} />
                    </TableCell>
                    <TableCell>
                      <Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 80 }}>
                        <LinearProgress variant="determinate" value={o.probability} sx={{ flex: 1, height: 6, borderRadius: 1 }} />
                        <Typography variant="caption">{o.probability}%</Typography>
                      </Box>
                    </TableCell>
                    <TableCell>{o.currency} {Number(o.estimated_value).toLocaleString()}</TableCell>
                    <TableCell><Typography fontWeight={600}>{o.currency} {(Number(o.estimated_value) * o.probability / 100).toLocaleString()}</Typography></TableCell>
                    <TableCell>{o.expected_close_date ? new Date(o.expected_close_date).toLocaleDateString() : "-"}</TableCell>
                    <TableCell align="right">
                      <Tooltip title="View Pipeline Board"><IconButton size="small" onClick={() => navigate("/business-development/opportunities/pipeline")}><Visibility fontSize="small" /></IconButton></Tooltip>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
}
