import { useCallback, useEffect, useState } from "react";
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog,
  DialogActions, DialogContent, DialogTitle, Divider, Grid, IconButton,
  LinearProgress, MenuItem, Table, TableBody, TableCell, TableHead, TableRow,
  TextField, Tooltip, Typography,
} from "@mui/material";
import { Add, Delete, History } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface CostEntry {
  id: string;
  entry_date: string;
  description: string;
  category: string;
  amount: number;
  reference_no: string | null;
}
interface TimeEntry {
  id: string;
  entry_date: string;
  hours: number;
  note: string | null;
  hourly_rate: number | null;
  task_id: string | null;
  app_users?: { name: string } | null;
}
interface DecisionRow {
  id: string;
  decision: string;
  notes: string | null;
  created_at: string;
  app_users?: { name: string } | null;
}

const CATEGORIES = ["materials", "equipment", "subcontractor", "travel", "labor", "other"] as const;

// "Budget & Time" section on the project detail page: real actuals from
// pmo_cost_entries + pmo_time_entries (the ledger added in
// 20260921113000), cost booking for pmo admin/manager, time logging for
// everyone, and the approval decision trail.
export default function ProjectBudgetPanel({
  projectId,
  budget,
  currency,
  projectName,
  onLogTime,
}: {
  projectId: string;
  budget: number | null;
  currency: string;
  projectName: string;
  onLogTime: () => void;
}) {
  const { session } = useAuth();
  const [costs, setCosts] = useState<CostEntry[]>([]);
  const [time, setTime] = useState<TimeEntry[]>([]);
  const [decisions, setDecisions] = useState<DecisionRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [canBook, setCanBook] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({ description: "", category: "other", amount: "", entry_date: new Date().toISOString().slice(0, 10), reference_no: "" });

  const fetchAll = useCallback(async () => {
    setLoading(true);
    const [costsRes, timeRes, decisionsRes, tierRes] = await Promise.all([
      supabase.from("pmo_cost_entries").select("id, entry_date, description, category, amount, reference_no").eq("project_id", projectId).order("entry_date", { ascending: false }).limit(100),
      supabase.from("pmo_time_entries").select("id, entry_date, hours, note, hourly_rate, task_id, app_users(name)").eq("project_id", projectId).order("entry_date", { ascending: false }).limit(100),
      supabase.from("pmo_project_decisions").select("id, decision, notes, created_at, app_users(name)").eq("project_id", projectId).order("created_at", { ascending: false }),
      supabase.rpc("has_module_role", { p_module: "pmo", p_roles: ["admin", "manager"] }),
    ]);
    if (costsRes.data) setCosts(costsRes.data as CostEntry[]);
    if (timeRes.data) setTime(timeRes.data.map((t: any) => ({ ...t, app_users: Array.isArray(t.app_users) ? t.app_users[0] ?? null : t.app_users ?? null })) as TimeEntry[]);
    if (decisionsRes.data) setDecisions(decisionsRes.data.map((d: any) => ({ ...d, app_users: Array.isArray(d.app_users) ? d.app_users[0] ?? null : d.app_users ?? null })) as DecisionRow[]);
    setCanBook(tierRes.data === true);
    setLoading(false);
  }, [projectId]);

  useEffect(() => { fetchAll(); }, [fetchAll]);

  const totalActual =
    costs.reduce((s, c) => s + Number(c.amount || 0), 0) +
    time.reduce((s, t) => s + Number(t.hours || 0) * Number(t.hourly_rate || 0), 0);
  const totalHours = time.reduce((s, t) => s + Number(t.hours || 0), 0);
  const b = Number(budget || 0);
  const utilization = b > 0 ? (totalActual / b) * 100 : 0;
  const over = b > 0 && totalActual > b;

  const handleAddCost = async () => {
    const amount = parseFloat(form.amount);
    if (!form.description.trim() || isNaN(amount) || amount < 0) {
      setError("Description and a non-negative amount are required.");
      return;
    }
    const tenantId = (session?.user?.user_metadata as { tenant_id?: string } | undefined)?.tenant_id;
    if (!tenantId) {
      setError("Your account is not associated with a tenant.");
      return;
    }
    setSaving(true);
    setError(null);
    const { error } = await supabase.from("pmo_cost_entries").insert({
      project_id: projectId,
      tenant_id: tenantId,
      description: form.description.trim(),
      category: form.category,
      amount,
      entry_date: form.entry_date,
      reference_no: form.reference_no.trim() || null,
      created_by: session?.user?.id ?? null,
    });
    setSaving(false);
    if (error) { setError(error.message); return; }
    setAddOpen(false);
    setForm({ description: "", category: "other", amount: "", entry_date: new Date().toISOString().slice(0, 10), reference_no: "" });
    fetchAll();
  };

  const handleDeleteCost = async (id: string) => {
    const { error } = await supabase.from("pmo_cost_entries").delete().eq("id", id);
    if (error) setError(error.message);
    else fetchAll();
  };

  if (loading) return <Box sx={{ display: "flex", justifyContent: "center", py: 3 }}><CircularProgress size={28} /></Box>;

  return (
    <Grid container spacing={2}>
      <Grid item xs={12} md={5}>
        <Card sx={{ height: "100%" }}><CardContent>
          <Typography variant="subtitle2" color="text.secondary" gutterBottom>Budget vs Actual</Typography>
          <Typography variant="h5" fontWeight={700}>
            {currency} {b > 0 ? b.toLocaleString() : "—"}
          </Typography>
          <Typography variant="body2" color={over ? "error.main" : "text.secondary"} sx={{ mt: 1 }}>
            Actual: <strong>{currency} {Math.round(totalActual).toLocaleString()}</strong>
            {" "}({totalHours.toFixed(1)}h logged{costs.length > 0 ? ` + ${costs.length} cost entr${costs.length === 1 ? "y" : "ies"}` : ""})
          </Typography>
          {b > 0 && (
            <Box sx={{ mt: 1.5 }}>
              <LinearProgress variant="determinate" value={Math.min(100, utilization)} color={over ? "error" : utilization > 80 ? "warning" : "success"} sx={{ height: 8, borderRadius: 1 }} />
              <Typography variant="caption" color={over ? "error.main" : "text.secondary"}>
                {utilization.toFixed(1)}% of budget{over ? ` — over by ${currency} ${Math.round(totalActual - b).toLocaleString()}` : ""}
              </Typography>
            </Box>
          )}
          <Box sx={{ display: "flex", gap: 1, mt: 2, flexWrap: "wrap" }}>
            {canBook && (
              <Button size="small" variant="outlined" startIcon={<Add />} onClick={() => setAddOpen(true)}>Add cost</Button>
            )}
            <Button size="small" variant="outlined" onClick={onLogTime}>Log time</Button>
          </Box>
          {error && <Alert severity="error" sx={{ mt: 2 }} onClose={() => setError(null)}>{error}</Alert>}
        </CardContent></Card>
      </Grid>

      <Grid item xs={12} md={7}>
        <Card sx={{ height: "100%" }}><CardContent>
          <Box sx={{ display: "flex", alignItems: "center", gap: 1, mb: 1 }}>
            <History fontSize="small" color="action" />
            <Typography variant="subtitle2" color="text.secondary">Approval history</Typography>
          </Box>
          {decisions.length === 0 ? (
            <Typography variant="body2" color="text.secondary">No approval decisions yet.</Typography>
          ) : decisions.map((d, i) => (
            <Box key={d.id}>
              {i > 0 && <Divider sx={{ my: 1 }} />}
              <Box sx={{ display: "flex", alignItems: "center", gap: 1, flexWrap: "wrap" }}>
                <Chip label={d.decision} size="small" color={d.decision === "approved" ? "success" : d.decision === "rejected" ? "error" : "info"} sx={{ textTransform: "capitalize", minWidth: 80 }} />
                <Typography variant="body2" fontWeight={600}>{d.app_users?.name ?? "Unknown user"}</Typography>
                <Typography variant="body2" color="text.secondary">{new Date(d.created_at).toLocaleString()}</Typography>
              </Box>
              {d.notes && <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5, ml: 1 }}>{d.notes}</Typography>}
            </Box>
          ))}
        </CardContent></Card>
      </Grid>

      {(costs.length > 0 || time.length > 0) && (
        <Grid item xs={12}>
          <Card><CardContent sx={{ p: 0 }}>
            <Box sx={{ px: 2, pt: 2 }}><Typography variant="subtitle2" color="text.secondary">Ledger</Typography></Box>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Date</TableCell>
                  <TableCell>What</TableCell>
                  <TableCell>Who</TableCell>
                  <TableCell>Category</TableCell>
                  <TableCell align="right">Amount</TableCell>
                  {canBook && <TableCell align="right" />}
                </TableRow>
              </TableHead>
              <TableBody>
                {costs.map((c) => (
                  <TableRow key={`c-${c.id}`}>
                    <TableCell>{new Date(c.entry_date).toLocaleDateString()}</TableCell>
                    <TableCell>{c.description}{c.reference_no ? ` (${c.reference_no})` : ""}</TableCell>
                    <TableCell>—</TableCell>
                    <TableCell><Chip label={c.category} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell align="right">{currency} {Number(c.amount).toLocaleString()}</TableCell>
                    {canBook && (
                      <TableCell align="right">
                        <Tooltip title="Delete cost"><IconButton size="small" onClick={() => handleDeleteCost(c.id)}><Delete fontSize="small" /></IconButton></Tooltip>
                      </TableCell>
                    )}
                  </TableRow>
                ))}
                {time.map((t) => (
                  <TableRow key={`t-${t.id}`}>
                    <TableCell>{new Date(t.entry_date).toLocaleDateString()}</TableCell>
                    <TableCell>{t.note || "Time logged"}</TableCell>
                    <TableCell>{t.app_users?.name ?? "—"}</TableCell>
                    <TableCell><Chip label={`${Number(t.hours)}h`} size="small" variant="outlined" /></TableCell>
                    <TableCell align="right">
                      {t.hourly_rate != null ? `${currency} ${Math.round(Number(t.hours) * Number(t.hourly_rate)).toLocaleString()}` : "uncosted"}
                    </TableCell>
                    {canBook && <TableCell align="right" />}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent></Card>
        </Grid>
      )}

      <Dialog open={addOpen} onClose={() => !saving && setAddOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle>Add cost — {projectName}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField label="Description *" value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} fullWidth autoFocus placeholder="e.g. Concrete delivery, site survey" />
          <TextField select label="Category" value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })} fullWidth>
            {CATEGORIES.map((c) => <MenuItem key={c} value={c} sx={{ textTransform: "capitalize" }}>{c}</MenuItem>)}
          </TextField>
          <Grid container spacing={2}>
            <Grid item xs={6}><TextField label={`Amount * (${currency})`} type="number" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} fullWidth inputProps={{ min: 0, step: "any" }} /></Grid>
            <Grid item xs={6}><TextField label="Date" type="date" value={form.entry_date} onChange={(e) => setForm({ ...form, entry_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
          </Grid>
          <TextField label="Reference No" value={form.reference_no} onChange={(e) => setForm({ ...form, reference_no: e.target.value })} fullWidth placeholder="Invoice / receipt no" />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAddOpen(false)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={handleAddCost} disabled={saving || !form.description.trim() || !form.amount.trim()}>
            {saving ? "Saving…" : "Add cost"}
          </Button>
        </DialogActions>
      </Dialog>
    </Grid>
  );
}
