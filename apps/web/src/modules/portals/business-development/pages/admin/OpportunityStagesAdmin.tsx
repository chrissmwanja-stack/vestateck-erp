import { useEffect, useState } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  Chip,
  CircularProgress,
  MenuItem,
  Slider,
} from "@mui/material";
import { Add, Edit, Delete, DragIndicator } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { resolveTenantId } from "../../../../../lib/ResolveTenantId";
import { useAuth } from "../../../../../lib/authContext";

type OpportunityStageEnum = 'identification' | 'qualification' | 'proposal' | 'negotiation' | 'closed_won' | 'closed_lost';

interface OpportunityStage {
  id: string;
  tenant_id: string;
  stage: OpportunityStageEnum;
  label: string;
  order_index: number;
  probability_default: number;
  color: string;
  is_active: boolean;
}

const STAGE_OPTIONS: { value: OpportunityStageEnum; label: string; defaultProb: number; color: string }[] = [
  { value: 'identification', label: 'Identification', defaultProb: 10, color: '#90caf9' },
  { value: 'qualification', label: 'Qualification', defaultProb: 25, color: '#ffb74d' },
  { value: 'proposal', label: 'Proposal', defaultProb: 50, color: '#fff176' },
  { value: 'negotiation', label: 'Negotiation', defaultProb: 75, color: '#ff8a65' },
  { value: 'closed_won', label: 'Closed Won', defaultProb: 100, color: '#81c784' },
  { value: 'closed_lost', label: 'Closed Lost', defaultProb: 0, color: '#e57373' },
];

export default function OpportunityStagesAdmin() {
  const { session } = useAuth();
  const [stages, setStages] = useState<OpportunityStage[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<OpportunityStage | null>(null);
  const [form, setForm] = useState<{
    stage: OpportunityStageEnum;
    label: string;
    order_index: number;
    probability_default: number;
    color: string;
    is_active: boolean;
  }>({
    stage: 'identification',
    label: 'Identification',
    order_index: 0,
    probability_default: 10,
    color: '#90caf9',
    is_active: true,
  });

  const fetchStages = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("bd_opportunity_stages")
      .select("*")
      .order("order_index", { ascending: true });
    
    if (error) console.error(error);
    else setStages(data as OpportunityStage[]);
    setLoading(false);
  };

  useEffect(() => { fetchStages(); }, []);

  const handleOpenNew = () => {
    setEditing(null);
    setForm({
      stage: 'identification',
      label: 'Identification',
      order_index: stages.length,
      probability_default: 10,
      color: '#90caf9',
      is_active: true,
    });
    setOpen(true);
  };

  const handleOpenEdit = (s: OpportunityStage) => {
    setEditing(s);
    setForm({
      stage: s.stage,
      label: s.label,
      order_index: s.order_index,
      probability_default: s.probability_default,
      color: s.color,
      is_active: s.is_active,
    });
    setOpen(true);
  };

  const handleStageChange = (stageValue: OpportunityStageEnum) => {
    const opt = STAGE_OPTIONS.find(o => o.value === stageValue);
    if (opt) {
      setForm(f => ({
        ...f,
        stage: stageValue,
        label: f.label === STAGE_OPTIONS.find(o => o.value === f.stage)?.label || !f.label ? opt.label : f.label,
        probability_default: opt.defaultProb,
        color: opt.color,
      }));
    }
  };

  const handleSave = async () => {
    if (!form.label.trim()) return;

    const payload = {
      stage: form.stage,
      label: form.label.trim(),
      order_index: form.order_index,
      probability_default: form.probability_default,
      color: form.color,
      is_active: form.is_active,
    };

    if (editing) {
      const { error } = await supabase.from("bd_opportunity_stages").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) { alert(tenantResult.error); return; }
      const insertPayload = { ...payload, tenant_id: tenantResult.tenantId };

      const { error } = await supabase.from("bd_opportunity_stages").insert(insertPayload);
      if (error) { alert(`Error: ${error.message}`); return; }
    }

    setOpen(false);
    fetchStages();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete this stage? If opportunities use it, deletion will fail. Deactivate instead?")) return;
    const { error } = await supabase.from("bd_opportunity_stages").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`);
    else fetchStages();
  };

  const handleSeedDefaults = async () => {
    const tenantResult = await resolveTenantId(session);
    if (!tenantResult.ok) { alert(tenantResult.error); return; }
    for (const [idx, opt] of STAGE_OPTIONS.entries()) {
      await supabase.from("bd_opportunity_stages").insert({
        stage: opt.value,
        label: opt.label,
        order_index: idx,
        probability_default: opt.defaultProb,
        color: opt.color,
        is_active: true,
        tenant_id: tenantResult.tenantId,
      });
    }
    setTimeout(fetchStages, 1000);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Opportunity Stages</Typography>
          <Typography variant="body2" color="text.secondary">
            Drives Pipeline Board columns, card colors, and weighted forecast (value × probability). Order controls board left-to-right.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Stage</Button>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell width={40}></TableCell>
                <TableCell>Stage</TableCell>
                <TableCell>Label</TableCell>
                <TableCell>Order</TableCell>
                <TableCell>Probability</TableCell>
                <TableCell>Color</TableCell>
                <TableCell>Active</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {stages.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={8} sx={{ textAlign: "center", py: 4 }}>
                    <Typography color="text.secondary">No stages yet. Create Identification, Qualification, Proposal, Negotiation, Closed Won, Closed Lost — same pattern as IT SLA Policies.</Typography>
                    <Button sx={{ mt: 2 }} variant="outlined" onClick={handleSeedDefaults}>Seed Default 6 Stages</Button>
                  </TableCell>
                </TableRow>
              ) : (
                stages.map((s) => (
                  <TableRow key={s.id} hover>
                    <TableCell><DragIndicator fontSize="small" color="disabled" /></TableCell>
                    <TableCell><Chip label={s.stage} size="small" variant="outlined" /></TableCell>
                    <TableCell><Typography variant="body2" fontWeight={600}>{s.label}</Typography></TableCell>
                    <TableCell>{s.order_index}</TableCell>
                    <TableCell>
                      <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                        <Box sx={{ width: 60, height: 6, bgcolor: "grey.200", borderRadius: 1 }}>
                          <Box sx={{ width: `${s.probability_default}%`, height: "100%", bgcolor: s.color, borderRadius: 1 }} />
                        </Box>
                        <Typography variant="caption">{s.probability_default}%</Typography>
                      </Box>
                    </TableCell>
                    <TableCell>
                      <Box sx={{ width: 20, height: 20, borderRadius: "50%", bgcolor: s.color, border: "1px solid #ddd" }} />
                    </TableCell>
                    <TableCell><Chip label={s.is_active ? "Active" : "Inactive"} size="small" color={s.is_active ? "success" : "default"} /></TableCell>
                    <TableCell align="right">
                      <IconButton size="small" onClick={() => handleOpenEdit(s)}><Edit fontSize="small" /></IconButton>
                      <IconButton size="small" onClick={() => handleDelete(s.id)}><Delete fontSize="small" /></IconButton>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Stage" : "New Stage"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2.5, pt: 2 }}>
          <TextField
            select
            label="Stage Enum *"
            value={form.stage}
            onChange={(e) => handleStageChange(e.target.value as OpportunityStageEnum)}
            fullWidth
          >
            {STAGE_OPTIONS.map(opt => (
              <MenuItem key={opt.value} value={opt.value}>{opt.label} ({opt.value})</MenuItem>
            ))}
          </TextField>
          <TextField
            label="Display Label *"
            value={form.label}
            onChange={(e) => setForm({ ...form, label: e.target.value })}
            fullWidth
          />
          <Box sx={{ display: "flex", gap: 2 }}>
            <TextField
              label="Order Index"
              type="number"
              value={form.order_index}
              onChange={(e) => setForm({ ...form, order_index: parseInt(e.target.value) || 0 })}
              fullWidth
              helperText="Left to right in Pipeline Board"
            />
            <TextField
              label="Color"
              type="color"
              value={form.color}
              onChange={(e) => setForm({ ...form, color: e.target.value })}
              fullWidth
              sx={{ maxWidth: 120 }}
            />
          </Box>
          <Box>
            <Typography variant="body2" gutterBottom>Default Probability: {form.probability_default}%</Typography>
            <Slider
              value={form.probability_default}
              onChange={(_, v) => setForm({ ...form, probability_default: v as number })}
              min={0}
              max={100}
              step={5}
              valueLabelDisplay="auto"
            />
            <Typography variant="caption" color="text.secondary">
              Weighted forecast = opportunity value × {form.probability_default}% when opportunity is in this stage
            </Typography>
          </Box>
          <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
            <Switch checked={form.is_active} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
            <Typography variant="body2">Active</Typography>
          </Box>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave}>{editing ? "Update" : "Create"}</Button>
        </DialogActions>
      </Dialog>

      <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}>
        <Typography variant="caption" fontWeight={600}>How this powers Pipeline Board:</Typography>
        <Typography variant="caption" component="div" color="text.secondary">
          <ul style={{ margin: "4px 0", paddingLeft: "18px" }}>
            <li><b>order_index</b> = column order left→right in board</li>
            <li><b>color</b> = card header color in board</li>
            <li><b>probability_default</b> = auto-filled when opportunity moves to this stage, drives weighted forecast report</li>
            <li>Next: Build New Opportunity form — Stage dropdown now has values</li>
          </ul>
        </Typography>
      </Box>
    </Box>
  );
}
