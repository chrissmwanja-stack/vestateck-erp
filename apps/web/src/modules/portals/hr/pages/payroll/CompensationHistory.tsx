import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  CircularProgress,
  Grid,
  MenuItem,
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
import { RequestQuote as RequestQuoteIcon } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

function useHrAccess() {
  const [isHr, setIsHr] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc("is_hr_team_member").then(({ data, error }) => setIsHr(error ? false : Boolean(data)));
  }, []);
  return isHr;
}

interface Employee {
  id: string;
  first_name: string;
  last_name: string;
  employee_no: string;
}

interface CompensationRow {
  id: string;
  basic_salary: number;
  currency: string;
  effective_date: string;
  contract_reference: string | null;
  note: string | null;
  created_at: string;
}

const emptyForm = { basic_salary: "", currency: "UGX", effective_date: "", contract_reference: "", note: "" };

export default function CompensationHistory() {
  const isHr = useHrAccess();
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [employeeId, setEmployeeId] = useState("");
  const [history, setHistory] = useState<CompensationRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  useEffect(() => {
    supabase
      .from("hr_employees")
      .select("id, first_name, last_name, employee_no")
      .eq("is_active", true)
      .order("first_name")
      .then(({ data }) => setEmployees((data ?? []) as Employee[]));
  }, []);

  const loadHistory = useCallback(async (empId: string) => {
    if (!empId) {
      setHistory([]);
      return;
    }
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from("hr_employee_compensation")
      .select("id, basic_salary, currency, effective_date, contract_reference, note, created_at")
      .eq("employee_id", empId)
      .order("effective_date", { ascending: false });
    setLoading(false);
    if (err) {
      setError(err.message);
      return;
    }
    setHistory((data ?? []) as CompensationRow[]);
  }, []);

  useEffect(() => {
    loadHistory(employeeId);
  }, [employeeId, loadHistory]);

  async function handleSave() {
    if (!employeeId) {
      setSaveError("Pick an employee first.");
      return;
    }
    const salary = parseFloat(form.basic_salary);
    if (!salary || salary <= 0) {
      setSaveError("Enter a basic salary greater than 0.");
      return;
    }
    if (!form.effective_date) {
      setSaveError("Effective date is required.");
      return;
    }
    setSaveError(null);
    setSaving(true);
    const { error: err } = await supabase.rpc("record_employee_compensation", {
      p_employee_id: employeeId,
      p_basic_salary: salary,
      p_effective_date: form.effective_date,
      p_contract_reference: form.contract_reference.trim() || undefined,
      p_note: form.note.trim() || undefined,
    });
    setSaving(false);
    if (err) {
      setSaveError(err.message ?? "Could not save.");
      return;
    }
    setForm(emptyForm);
    loadHistory(employeeId);
  }

  const current = history[0];

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" sx={{ display: "flex", alignItems: "center", gap: 1, mb: 1 }}>
        <RequestQuoteIcon /> Compensation
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Salary is set once at hiring and only changes with a new contract — there's no approval step here since
        that negotiation already happened. Payroll runs pull the current figure automatically.
      </Typography>

      <Paper variant="outlined" sx={{ p: 2, mb: 3 }}>
        <TextField
          select
          label="Employee"
          size="small"
          sx={{ minWidth: 280 }}
          value={employeeId}
          onChange={(e) => setEmployeeId(e.target.value)}
        >
          <MenuItem value="">— Select —</MenuItem>
          {employees.map((e) => (
            <MenuItem key={e.id} value={e.id}>
              {e.first_name} {e.last_name} ({e.employee_no})
            </MenuItem>
          ))}
        </TextField>
      </Paper>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      {employeeId && (
        <>
          {loading ? (
            <Box display="flex" justifyContent="center" py={3}>
              <CircularProgress size={20} />
            </Box>
          ) : (
            <>
              {current && (
                <Card variant="outlined" sx={{ mb: 3, bgcolor: "action.hover" }}>
                  <CardContent>
                    <Typography variant="caption" color="text.secondary">Current salary</Typography>
                    <Typography variant="h5" fontWeight={700}>
                      {current.currency} {Number(current.basic_salary).toLocaleString()}
                    </Typography>
                    <Typography variant="caption" color="text.secondary">
                      Effective {current.effective_date}
                      {current.contract_reference ? ` · ${current.contract_reference}` : ""}
                    </Typography>
                  </CardContent>
                </Card>
              )}

              {isHr && (
                <Paper variant="outlined" sx={{ p: 2, mb: 3 }}>
                  <Typography variant="subtitle2" sx={{ fontWeight: 600, mb: 2 }}>
                    Record a salary change
                  </Typography>
                  <Grid container spacing={2}>
                    <Grid item xs={12} sm={4}>
                      <TextField
                        label="Basic salary"
                        type="number"
                        fullWidth
                        size="small"
                        value={form.basic_salary}
                        onChange={(e) => setForm((v) => ({ ...v, basic_salary: e.target.value }))}
                      />
                    </Grid>
                    <Grid item xs={12} sm={2}>
                      <TextField
                        select
                        label="Currency"
                        fullWidth
                        size="small"
                        value={form.currency}
                        onChange={(e) => setForm((v) => ({ ...v, currency: e.target.value }))}
                      >
                        <MenuItem value="UGX">UGX</MenuItem>
                        <MenuItem value="USD">USD</MenuItem>
                        <MenuItem value="EUR">EUR</MenuItem>
                      </TextField>
                    </Grid>
                    <Grid item xs={12} sm={3}>
                      <TextField
                        label="Effective date"
                        type="date"
                        fullWidth
                        size="small"
                        InputLabelProps={{ shrink: true }}
                        value={form.effective_date}
                        onChange={(e) => setForm((v) => ({ ...v, effective_date: e.target.value }))}
                      />
                    </Grid>
                    <Grid item xs={12} sm={3}>
                      <TextField
                        label="Contract ref (optional)"
                        fullWidth
                        size="small"
                        value={form.contract_reference}
                        onChange={(e) => setForm((v) => ({ ...v, contract_reference: e.target.value }))}
                      />
                    </Grid>
                    <Grid item xs={12}>
                      <TextField
                        label="Note (optional)"
                        fullWidth
                        size="small"
                        value={form.note}
                        onChange={(e) => setForm((v) => ({ ...v, note: e.target.value }))}
                      />
                    </Grid>
                  </Grid>
                  {saveError && <Alert severity="error" sx={{ mt: 2 }}>{saveError}</Alert>}
                  <Stack direction="row" justifyContent="flex-end" sx={{ mt: 2 }}>
                    <Button variant="contained" disabled={saving} onClick={handleSave}>
                      {saving ? "Saving…" : "Save"}
                    </Button>
                  </Stack>
                </Paper>
              )}

              <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>History</Typography>
              <Paper variant="outlined">
                <TableContainer>
                  <Table size="small">
                    <TableHead>
                      <TableRow>
                        <TableCell>Effective</TableCell>
                        <TableCell align="right">Salary</TableCell>
                        <TableCell>Contract ref</TableCell>
                        <TableCell>Note</TableCell>
                        <TableCell>Recorded</TableCell>
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {history.map((h) => (
                        <TableRow key={h.id} hover>
                          <TableCell>{h.effective_date}</TableCell>
                          <TableCell align="right">{h.currency} {Number(h.basic_salary).toLocaleString()}</TableCell>
                          <TableCell>{h.contract_reference ?? "—"}</TableCell>
                          <TableCell>{h.note ?? "—"}</TableCell>
                          <TableCell>{new Date(h.created_at).toLocaleDateString()}</TableCell>
                        </TableRow>
                      ))}
                      {history.length === 0 && (
                        <TableRow>
                          <TableCell colSpan={5} align="center" sx={{ color: "text.secondary", py: 3 }}>
                            No compensation recorded yet for this employee.
                          </TableCell>
                        </TableRow>
                      )}
                    </TableBody>
                  </Table>
                </TableContainer>
              </Paper>
            </>
          )}
        </>
      )}
    </Box>
  );
}