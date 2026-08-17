import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from "@mui/material";
import {
  Add as AddIcon,
  ExpandMore as ExpandMoreIcon,
  ExpandLess as ExpandLessIcon,
  Payments as PaymentsIcon,
  Sync as SyncIcon,
} from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

// Same shape as is_finance_team_member() checks elsewhere -- local to
// this file rather than a shared hook, matching the existing convention
// (see ProcurementInfo.tsx / MaterialLookupsAdmin.tsx).
function useHrAccess() {
  const [isHr, setIsHr] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc("is_hr_team_member").then(({ data, error }) => setIsHr(error ? false : Boolean(data)));
  }, []);
  return isHr;
}

const statusColor: Record<string, "default" | "warning" | "success" | "info" | "error"> = {
  draft: "default",
  pending_approval: "warning",
  approved: "info",
  rejected: "error",
  disbursed: "success",
};

interface PayrollRun {
  id: string;
  period: string;
  status: string;
  amount_disbursed: number;
  rejection_reason: string | null;
  rejected_at: string | null;
  submitted_at: string | null;
  approved_at: string | null;
  created_at: string;
}

interface PayrollItem {
  id: string;
  employee_id: string;
  basic_salary: number;
  allowances: number;
  deductions: number;
  net_pay: number;
  note: string | null;
  employee_name: string;
  employee_no: string;
}

function RunItems({ run, onRunChanged }: { run: PayrollRun; onRunChanged: () => void }) {
  const [items, setItems] = useState<PayrollItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [generating, setGenerating] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Local edit buffer keyed by item id -- avoids firing a save on every
  // keystroke; commits on blur, same pattern as the offer-entry screens.
  const [edits, setEdits] = useState<Record<string, { allowances: string; deductions: string; note: string }>>({});

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: err } = await supabase
      .from("hr_payroll_items")
      .select("id, employee_id, basic_salary, allowances, deductions, net_pay, note, hr_employees(first_name, last_name, employee_no)")
      .eq("payroll_run_id", run.id)
      .order("id");
    if (err) {
      setError(err.message);
    } else {
      const mapped = ((data ?? []) as any[]).map((r) => ({
        id: r.id,
        employee_id: r.employee_id,
        basic_salary: r.basic_salary,
        allowances: r.allowances,
        deductions: r.deductions,
        net_pay: r.net_pay,
        note: r.note,
        employee_name: r.hr_employees ? `${r.hr_employees.first_name} ${r.hr_employees.last_name}` : "—",
        employee_no: r.hr_employees?.employee_no ?? "—",
      }));
      setItems(mapped);
      setEdits(Object.fromEntries(mapped.map((m) => [m.id, { allowances: String(m.allowances), deductions: String(m.deductions), note: m.note ?? "" }])));
    }
    setLoading(false);
  }, [run.id]);

  useEffect(() => {
    load();
  }, [load]);

  async function handleGenerate() {
    setGenerating(true);
    setError(null);
    const { error: err } = await supabase.rpc("generate_payroll_items", { p_run_id: run.id });
    setGenerating(false);
    if (err) {
      setError(err.message ?? "Could not generate payroll items.");
      return;
    }
    load();
  }

  async function handleSaveItem(itemId: string) {
    const buf = edits[itemId];
    if (!buf) return;
    const allowances = parseFloat(buf.allowances) || 0;
    const deductions = parseFloat(buf.deductions) || 0;
    const { error: err } = await supabase.rpc("update_payroll_item", {
      p_item_id: itemId,
      p_allowances: allowances,
      p_deductions: deductions,
      p_note: buf.note.trim() || undefined,
    });
    if (err) {
      setError(err.message ?? "Could not save the line item.");
      return;
    }
    load();
  }

  async function handleSubmit() {
    setSubmitting(true);
    setError(null);
    const { error: err } = await supabase.rpc("submit_payroll_run", { p_run_id: run.id });
    setSubmitting(false);
    if (err) {
      setError(err.message ?? "Could not submit for approval.");
      return;
    }
    onRunChanged();
  }

  const isDraft = run.status === "draft";
  const totalNet = items.reduce((sum, i) => sum + Number(i.net_pay), 0);

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={2}>
        <CircularProgress size={20} />
      </Box>
    );
  }

  return (
    <Box sx={{ px: 2, pb: 2 }}>
      {error && <Alert severity="error" sx={{ mb: 1 }} onClose={() => setError(null)}>{error}</Alert>}
      {run.rejection_reason && (
        <Alert severity="warning" sx={{ mb: 1 }}>
          Sent back by an approver: "{run.rejection_reason}"
        </Alert>
      )}

      {isDraft && (
        <Button size="small" startIcon={<SyncIcon />} onClick={handleGenerate} disabled={generating} sx={{ mb: 1 }}>
          {generating ? "Generating…" : "Generate / refresh items from current employees"}
        </Button>
      )}

      <TableContainer>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Employee</TableCell>
              <TableCell align="right">Basic</TableCell>
              <TableCell align="right">Allowances</TableCell>
              <TableCell align="right">Deductions</TableCell>
              <TableCell align="right">Net Pay</TableCell>
              <TableCell>Note</TableCell>
              {isDraft && <TableCell />}
            </TableRow>
          </TableHead>
          <TableBody>
            {items.map((item) => (
              <TableRow key={item.id} hover>
                <TableCell>
                  <Typography variant="body2" fontWeight={600}>{item.employee_name}</Typography>
                  <Typography variant="caption" color="text.secondary">{item.employee_no}</Typography>
                </TableCell>
                <TableCell align="right">{Number(item.basic_salary).toLocaleString()}</TableCell>
                <TableCell align="right" sx={{ minWidth: 100 }}>
                  {isDraft ? (
                    <TextField
                      size="small"
                      variant="standard"
                      type="number"
                      value={edits[item.id]?.allowances ?? ""}
                      onChange={(e) => setEdits((s) => ({ ...s, [item.id]: { ...s[item.id], allowances: e.target.value } }))}
                      onBlur={() => handleSaveItem(item.id)}
                    />
                  ) : (
                    Number(item.allowances).toLocaleString()
                  )}
                </TableCell>
                <TableCell align="right" sx={{ minWidth: 100 }}>
                  {isDraft ? (
                    <TextField
                      size="small"
                      variant="standard"
                      type="number"
                      value={edits[item.id]?.deductions ?? ""}
                      onChange={(e) => setEdits((s) => ({ ...s, [item.id]: { ...s[item.id], deductions: e.target.value } }))}
                      onBlur={() => handleSaveItem(item.id)}
                    />
                  ) : (
                    Number(item.deductions).toLocaleString()
                  )}
                </TableCell>
                <TableCell align="right">
                  <Typography fontWeight={700}>{Number(item.net_pay).toLocaleString()}</Typography>
                </TableCell>
                <TableCell sx={{ minWidth: 140 }}>
                  {isDraft ? (
                    <TextField
                      size="small"
                      variant="standard"
                      fullWidth
                      value={edits[item.id]?.note ?? ""}
                      onChange={(e) => setEdits((s) => ({ ...s, [item.id]: { ...s[item.id], note: e.target.value } }))}
                      onBlur={() => handleSaveItem(item.id)}
                    />
                  ) : (
                    item.note ?? "—"
                  )}
                </TableCell>
              </TableRow>
            ))}
            {items.length === 0 && (
              <TableRow>
                <TableCell colSpan={isDraft ? 7 : 6} align="center" sx={{ color: "text.secondary", py: 2 }}>
                  No line items yet. {isDraft ? 'Click "Generate items" to pull in active employees.' : ""}
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>

      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mt: 1.5 }}>
        <Typography variant="body2" color="text.secondary">
          {items.length} employee{items.length === 1 ? "" : "s"} · Total net {totalNet.toLocaleString()}
        </Typography>
        {isDraft && (
          <Button variant="contained" size="small" disabled={submitting || items.length === 0} onClick={handleSubmit}>
            {submitting ? "Submitting…" : "Submit for approval"}
          </Button>
        )}
      </Stack>
    </Box>
  );
}

export default function PayrollList() {
  const isHr = useHrAccess();
  const [runs, setRuns] = useState<PayrollRun[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [period, setPeriod] = useState("");
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: err } = await supabase
      .from("hr_payroll_runs")
      .select("id, period, status, amount_disbursed, rejection_reason, rejected_at, submitted_at, approved_at, created_at")
      .order("period", { ascending: false });
    if (err) setError(err.message);
    else setRuns((data ?? []) as PayrollRun[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function handleCreate() {
    if (!/^\d{4}-\d{2}$/.test(period.trim())) {
      setCreateError("Use YYYY-MM, e.g. 2026-08.");
      return;
    }
    setCreating(true);
    setCreateError(null);
    const { error: err } = await supabase.rpc("create_payroll_run", { p_period: period.trim() });
    setCreating(false);
    if (err) {
      setCreateError(err.message.includes("duplicate key") ? `A run for ${period.trim()} already exists.` : err.message);
      return;
    }
    setNewOpen(false);
    setPeriod("");
    load();
  }

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
        <Typography variant="h5" sx={{ display: "flex", alignItems: "center", gap: 1 }}>
          <PaymentsIcon /> Payroll
        </Typography>
        {isHr && (
          <Button variant="contained" size="small" startIcon={<AddIcon />} onClick={() => { setCreateError(null); setNewOpen(true); }}>
            New run
          </Button>
        )}
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Prepare a payroll run per period, then submit it for approval. Basic salary is pulled from each employee's
        current compensation record — update that under Compensation if someone's contract changed.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {isHr === false && (
        <Alert severity="info" sx={{ mb: 2 }}>
          You can view payroll runs, but only HR team members can prepare or edit them.
        </Alert>
      )}

      <Paper variant="outlined">
        {loading ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <>
            {runs.map((run) => (
              <Box key={run.id} sx={{ borderBottom: 1, borderColor: "divider", "&:last-of-type": { borderBottom: 0 } }}>
                <Box
                  sx={{ p: 2, display: "flex", alignItems: "center", justifyContent: "space-between", cursor: "pointer" }}
                  onClick={() => setOpenId(openId === run.id ? null : run.id)}
                >
                  <Stack direction="row" spacing={2} alignItems="center">
                    <Typography variant="subtitle1" fontWeight={600}>{run.period}</Typography>
                    <Chip size="small" label={run.status.replace("_", " ")} color={statusColor[run.status]} sx={{ textTransform: "capitalize" }} />
                    {run.status === "disbursed" && (
                      <Typography variant="caption" color="text.secondary">
                        Disbursed {Number(run.amount_disbursed).toLocaleString()}
                      </Typography>
                    )}
                  </Stack>
                  <IconButton size="small">{openId === run.id ? <ExpandLessIcon /> : <ExpandMoreIcon />}</IconButton>
                </Box>
                <Collapse in={openId === run.id} timeout="auto" unmountOnExit>
                  <RunItems run={run} onRunChanged={load} />
                </Collapse>
              </Box>
            ))}
            {runs.length === 0 && (
              <Box sx={{ p: 4, textAlign: "center", color: "text.secondary" }}>No payroll runs yet.</Box>
            )}
          </>
        )}
      </Paper>

      <Dialog open={newOpen} onClose={() => !creating && setNewOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle>New Payroll Run</DialogTitle>
        <DialogContent>
          <TextField
            label="Period"
            placeholder="2026-08"
            fullWidth
            sx={{ mt: 1 }}
            value={period}
            onChange={(e) => setPeriod(e.target.value)}
            helperText="Format: YYYY-MM"
          />
          {createError && <Alert severity="error" sx={{ mt: 2 }}>{createError}</Alert>}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)} disabled={creating}>Cancel</Button>
          <Button variant="contained" onClick={handleCreate} disabled={creating}>
            {creating ? "Creating…" : "Create"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}