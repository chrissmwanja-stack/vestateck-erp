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
  ExpandMore as ExpandMoreIcon,
  ExpandLess as ExpandLessIcon,
  AssignmentTurnedIn as AssignmentTurnedInIcon,
} from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

function usePayrollApproverAccess() {
  const [isApprover, setIsApprover] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc("is_payroll_approver").then(({ data, error }) => setIsApprover(error ? false : Boolean(data)));
  }, []);
  return isApprover;
}

interface PayrollRun {
  id: string;
  period: string;
  status: string;
  submitted_at: string | null;
}

interface PayrollItem {
  id: string;
  basic_salary: number;
  allowances: number;
  deductions: number;
  paye_amount: number;
  nssf_employee: number;
  nssf_employer: number;
  net_pay: number;
  employee_name: string;
  employee_no: string;
}

function RunReview({ run }: { run: PayrollRun }) {
  const [items, setItems] = useState<PayrollItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase
      .from("hr_payroll_items")
      .select(
        "id, basic_salary, allowances, deductions, paye_amount, nssf_employee, nssf_employer, net_pay, hr_employees(first_name, last_name, employee_no)"
      )
      .eq("payroll_run_id", run.id)
      .order("id")
      .then(({ data }) => {
        setItems(
          ((data ?? []) as any[]).map((r) => ({
            id: r.id,
            basic_salary: r.basic_salary,
            allowances: r.allowances,
            deductions: r.deductions,
            paye_amount: r.paye_amount,
            nssf_employee: r.nssf_employee,
            nssf_employer: r.nssf_employer,
            net_pay: r.net_pay,
            employee_name: r.hr_employees ? `${r.hr_employees.first_name} ${r.hr_employees.last_name}` : "—",
            employee_no: r.hr_employees?.employee_no ?? "—",
          }))
        );
        setLoading(false);
      });
  }, [run.id]);

  const totalNet = items.reduce((sum, i) => sum + Number(i.net_pay), 0);
  const totalPaye = items.reduce((sum, i) => sum + Number(i.paye_amount), 0);
  const totalNssf = items.reduce((sum, i) => sum + Number(i.nssf_employee) + Number(i.nssf_employer), 0);

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={2}>
        <CircularProgress size={20} />
      </Box>
    );
  }

  return (
    <Box sx={{ px: 2, pb: 2 }}>
      <TableContainer>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Employee</TableCell>
              <TableCell align="right">Basic</TableCell>
              <TableCell align="right">Allowances</TableCell>
              <TableCell align="right">Deductions</TableCell>
              <TableCell align="right">PAYE</TableCell>
              <TableCell align="right">NSSF (Employee)</TableCell>
              <TableCell align="right">Net Pay</TableCell>
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
                <TableCell align="right">{Number(item.allowances).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(item.deductions).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(item.paye_amount).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(item.nssf_employee).toLocaleString()}</TableCell>
                <TableCell align="right"><Typography fontWeight={700}>{Number(item.net_pay).toLocaleString()}</Typography></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>
      <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
        {items.length} employee{items.length === 1 ? "" : "s"} · Total net {totalNet.toLocaleString()} · Total PAYE{" "}
        {totalPaye.toLocaleString()} · Total NSSF (employee + employer) {totalNssf.toLocaleString()}
      </Typography>
    </Box>
  );
}

export default function PayrollApprovals() {
  const isApprover = usePayrollApproverAccess();
  const [runs, setRuns] = useState<PayrollRun[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [actingId, setActingId] = useState<string | null>(null);

  const [rejectTarget, setRejectTarget] = useState<PayrollRun | null>(null);
  const [rejectReason, setRejectReason] = useState("");
  const [rejectError, setRejectError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: err } = await supabase
      .from("hr_payroll_runs")
      .select("id, period, status, submitted_at")
      .eq("status", "pending_approval")
      .order("submitted_at", { ascending: true });
    if (err) setError(err.message);
    else setRuns((data ?? []) as PayrollRun[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function handleApprove(runId: string) {
    setActingId(runId);
    setError(null);
    const { error: err } = await supabase.rpc("approve_payroll_run", { p_run_id: runId });
    setActingId(null);
    if (err) {
      setError(err.message ?? "Could not approve.");
      return;
    }
    load();
  }

  function openReject(run: PayrollRun) {
    setRejectTarget(run);
    setRejectReason("");
    setRejectError(null);
  }

  async function handleReject() {
    if (!rejectTarget) return;
    if (!rejectReason.trim()) {
      setRejectError("A reason is required so HR knows what to fix.");
      return;
    }
    setActingId(rejectTarget.id);
    const { error: err } = await supabase.rpc("reject_payroll_run", { p_run_id: rejectTarget.id, p_reason: rejectReason.trim() });
    setActingId(null);
    if (err) {
      setRejectError(err.message ?? "Could not reject.");
      return;
    }
    setRejectTarget(null);
    load();
  }

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" sx={{ display: "flex", alignItems: "center", gap: 1, mb: 1 }}>
        <AssignmentTurnedInIcon /> Payroll Approvals
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Runs HR has submitted, waiting on approval before Finance can disburse.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {isApprover === false && (
        <Alert severity="info" sx={{ mb: 2 }}>
          You're not currently listed as a payroll approver for this organization.
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
                    <Chip size="small" label="Pending approval" color="warning" />
                  </Stack>
                  <Stack direction="row" spacing={1} alignItems="center" onClick={(e) => e.stopPropagation()}>
                    {isApprover && (
                      <>
                        <Button size="small" color="error" variant="outlined" disabled={actingId === run.id} onClick={() => openReject(run)}>
                          Reject
                        </Button>
                        <Button size="small" variant="contained" disabled={actingId === run.id} onClick={() => handleApprove(run.id)}>
                          {actingId === run.id ? "Working…" : "Approve"}
                        </Button>
                      </>
                    )}
                    <IconButton size="small" onClick={() => setOpenId(openId === run.id ? null : run.id)}>
                      {openId === run.id ? <ExpandLessIcon /> : <ExpandMoreIcon />}
                    </IconButton>
                  </Stack>
                </Box>
                <Collapse in={openId === run.id} timeout="auto" unmountOnExit>
                  <RunReview run={run} />
                </Collapse>
              </Box>
            ))}
            {runs.length === 0 && (
              <Box sx={{ p: 4, textAlign: "center", color: "text.secondary" }}>Nothing waiting on approval.</Box>
            )}
          </>
        )}
      </Paper>

      <Dialog open={!!rejectTarget} onClose={() => setRejectTarget(null)} maxWidth="xs" fullWidth>
        <DialogTitle>Reject {rejectTarget?.period}</DialogTitle>
        <DialogContent>
          <TextField
            label="Reason"
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 1 }}
            value={rejectReason}
            onChange={(e) => setRejectReason(e.target.value)}
            helperText="Sent back to HR as a draft, with this note attached."
          />
          {rejectError && <Alert severity="error" sx={{ mt: 2 }}>{rejectError}</Alert>}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setRejectTarget(null)}>Cancel</Button>
          <Button variant="contained" color="error" onClick={handleReject} disabled={actingId === rejectTarget?.id}>
            {actingId === rejectTarget?.id ? "Working…" : "Reject"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}