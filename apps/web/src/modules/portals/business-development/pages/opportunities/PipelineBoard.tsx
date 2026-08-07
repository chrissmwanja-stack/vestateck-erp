import { useEffect, useState } from "react";
import {
  Box,
  Card,
  CardContent,
  Typography,
  Chip,
  CircularProgress,
  Paper,
} from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Stage {
  id: string;
  stage: string;
  label: string;
  order_index: number;
  probability_default: number;
  color: string;
  is_active: boolean;
}

interface Opportunity {
  id: string;
  opportunity_no: string;
  title: string;
  stage: string;
  probability: number;
  estimated_value: number;
  currency: string;
  bd_clients?: { name: string } | null;
}

export default function PipelineBoard() {
  const [stages, setStages] = useState<Stage[]>([]);
  const [opps, setOpps] = useState<Opportunity[]>([]);
  const [loading, setLoading] = useState(true);
  const [draggedId, setDraggedId] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const [stagesRes, oppsRes] = await Promise.all([
      supabase.from("bd_opportunity_stages").select("*").eq("is_active", true).order("order_index"),
      supabase.from("bd_opportunities").select("*, bd_clients(name)").order("created_at", { ascending: false }),
    ]);
    if (stagesRes.data) setStages(stagesRes.data as Stage[]);
    if (oppsRes.data) setOpps(oppsRes.data as Opportunity[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleDragStart = (id: string) => setDraggedId(id);
  const handleDragOver = (e: React.DragEvent) => e.preventDefault();

  const handleDrop = async (newStage: string) => {
    if (!draggedId) return;
    const stage = stages.find(s => s.stage === newStage);
    const opp = opps.find(o => o.id === draggedId);
    if (!opp || !stage) return;

    // Optimistic update
    setOpps(prev => prev.map(o => o.id === draggedId ? { ...o, stage: newStage, probability: stage.probability_default } : o));
    
    const { error } = await supabase
      .from("bd_opportunities")
      .update({ stage: newStage, probability: stage.probability_default })
      .eq("id", draggedId);
    
    if (error) {
      console.error(error);
      fetchData(); // revert on error
    }
    setDraggedId(null);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (stages.length === 0) {
    return (
      <Box sx={{ p: 3 }}>
        <Typography variant="h5" fontWeight={700} gutterBottom>Pipeline Board</Typography>
        <Typography color="text.secondary">No active Opportunity Stages. Go to Admin → Opportunity Stages → Seed Default 6 Stages.</Typography>
      </Box>
    );
  }

  return (
    <Box sx={{ p: 2, maxWidth: "100%", overflow: "auto" }}>
      <Box sx={{ mb: 2 }}>
        <Typography variant="h5" fontWeight={700}>Pipeline Board</Typography>
        <Typography variant="body2" color="text.secondary">
          Drag cards between columns to change stage. Probability auto-updates from stage default. Weighted forecast = value × probability.
        </Typography>
      </Box>

      <Box sx={{ display: "flex", gap: 2, overflowX: "auto", pb: 2, minHeight: "70vh" }}>
        {stages.map(stage => {
          const stageOpps = opps.filter(o => o.stage === stage.stage);
          const total = stageOpps.reduce((sum, o) => sum + Number(o.estimated_value), 0);
          const weighted = stageOpps.reduce((sum, o) => sum + Number(o.estimated_value) * (o.probability / 100), 0);
          const currency = stageOpps[0]?.currency || "USD";

          return (
            <Paper
              key={stage.id}
              elevation={0}
              onDragOver={handleDragOver}
              onDrop={() => handleDrop(stage.stage)}
              sx={{
                minWidth: 280,
                maxWidth: 320,
                flex: 1,
                bgcolor: "grey.50",
                border: "1px solid",
                borderColor: "divider",
                borderTop: `4px solid ${stage.color}`,
                borderRadius: 2,
                display: "flex",
                flexDirection: "column",
                maxHeight: "75vh",
              }}
            >
              <Box sx={{ p: 1.5, borderBottom: 1, borderColor: "divider", bgcolor: "white" }}>
                <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <Typography variant="subtitle2" fontWeight={700}>{stage.label}</Typography>
                  <Chip label={stageOpps.length} size="small" />
                </Box>
                <Typography variant="caption" color="text.secondary">
                  {stage.probability_default}% default • {currency} {total.toLocaleString()} total • Weighted {weighted.toLocaleString()}
                </Typography>
              </Box>

              <Box sx={{ flex: 1, overflow: "auto", p: 1, display: "flex", flexDirection: "column", gap: 1 }}>
                {stageOpps.length === 0 ? (
                  <Box sx={{ p: 2, textAlign: "center", border: "1px dashed", borderColor: "divider", borderRadius: 1, bgcolor: "white" }}>
                    <Typography variant="caption" color="text.secondary">No opportunities<br />Drop here to move</Typography>
                  </Box>
                ) : (
                  stageOpps.map(opp => (
                    <Card
                      key={opp.id}
                      draggable
                      onDragStart={() => handleDragStart(opp.id)}
                      sx={{
                        cursor: "grab",
                        opacity: draggedId === opp.id ? 0.5 : 1,
                        borderLeft: `3px solid ${stage.color}`,
                        "&:hover": { boxShadow: 2 },
                      }}
                    >
                      <CardContent sx={{ p: 1.5, "&:last-child": { pb: 1.5 } }}>
                        <Typography variant="caption" fontFamily="monospace" color="text.secondary">{opp.opportunity_no}</Typography>
                        <Typography variant="body2" fontWeight={600} sx={{ mb: 0.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{opp.title}</Typography>
                        <Typography variant="caption" color="text.secondary" sx={{ display: "block", mb: 1 }}>{opp.bd_clients?.name || "No client"}</Typography>
                        <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                          <Chip label={`${opp.currency} ${Number(opp.estimated_value).toLocaleString()}`} size="small" variant="outlined" />
                          <Chip label={`${opp.probability}%`} size="small" sx={{ bgcolor: stage.color, color: "#000", fontWeight: 600 }} />
                        </Box>
                        <Typography variant="caption" color="text.secondary" sx={{ mt: 0.5, display: "block" }}>
                          Weighted: {opp.currency} {(Number(opp.estimated_value) * opp.probability / 100).toLocaleString()}
                        </Typography>
                      </CardContent>
                    </Card>
                  ))
                )}
              </Box>
            </Paper>
          );
        })}
      </Box>
    </Box>
  );
}
