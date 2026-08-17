import { useCallback, useEffect, useState } from "react";
import {
  Alert, Box, Button, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogTitle, Paper, Stack, Table, TableBody, TableCell, TableContainer,
  TableHead, TableRow, TextField, Typography,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";
import type { CostCenter } from "@erp-platform/shared";

const emptyForm = { name: "", project_code: "", budget_amount: "" };

// Create/edit is Finance-only server-side (cost_centers_insert_finance /
// cost_centers_update_finance RLS policies both require has_po_access()).
// This client-side check just avoids showing a form that would only error
// out on save for anyone else -- same pattern as ProcurementTrack.tsx.
function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    supabase.rpc("am_i_finance").then(({ data, error }) => {
      if (cancelled) return;
      setIsFinance(error ? false : Boolean(data));
    });
    return () => {
      cancelled = true;
    };
  }, []);

  return isFinance;
}

export default function CostCodeListNew() {
  const [items, setItems] = useState<CostCenter[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setErrorState] = useState<string | null>(null);
  const [editTarget, setEditTarget] = useState<CostCenter | null>(null);
  const [editForm, setEditForm] = useState(emptyForm);
  const [editSubmitting, setEditSubmitting] = useState(false);
  const [editError, setEditError] = useState<string | null>(null);
  const isFinance = useFinanceAccess();

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase.from("cost_centers").select("*").order("name");
    if (error) setErrorState(error.message);
    else setItems((data ?? []) as CostCenter[]);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const openNew = () => {
    setEditTarget(null);
    setEditForm(emptyForm);
    setEditError(null);
  };

  const openEdit = (item: CostCenter) => {
    setEditTarget(item);
    setEditForm({
      name: item.name || "",
      project_code: item.project_code || "",
      budget_amount: item.budget_amount != null ? String(item.budget_amount) : "",
    });
    setEditError(null);
  };

  // Dialog is open whenever we're either editing an existing row or
  // creating a new one. Distinguish "closed" from "new" with a separate
  // flag rather than overloading editTarget's nullability for both.
  const [dialogOpen, setDialogOpen] = useState(false);

  const openNewDialog = () => { openNew(); setDialogOpen(true); };
  const openEditDialog = (item: CostCenter) => { openEdit(item); setDialogOpen(true); };
  const closeEdit = () => { if (!editSubmitting) { setDialogOpen(false); setEditTarget(null); } };

  const saveEdit = async () => {
    setEditError(null);

    const name = editForm.name.trim();
    if (!name) {
      setEditError("Name is required.");
      return;
    }

    const budgetAmount = editForm.budget_amount.trim() === ""
      ? null
      : Number(editForm.budget_amount);
    if (budgetAmount !== null && (Number.isNaN(budgetAmount) || budgetAmount < 0)) {
      setEditError("Budget amount must be a valid non-negative number.");
      return;
    }

    setEditSubmitting(true);

    // tenant_id is set server-side by trg_set_cost_center_defaults
    // (BEFORE INSERT, resolves via get_my_tenant_id()) -- no need to send
    // it from here. Both insert and update are additionally RLS-gated to
    // has_po_access(); the useFinanceAccess() check above just keeps this
    // form from being shown to users who'd fail that check on save.
    const { error } = editTarget
      ? await supabase
          .from("cost_centers")
          .update({
            name,
            project_code: editForm.project_code.trim() || null,
            budget_amount: budgetAmount,
          })
          .eq("id", editTarget.id)
      : await supabase
          .from("cost_centers")
          .insert({
            name,
            project_code: editForm.project_code.trim() || null,
            budget_amount: budgetAmount,
          } as any);

    setEditSubmitting(false);

    if (error) {
      setEditError(error.message);
      return;
    }

    setDialogOpen(false);
    setEditTarget(null);
    load();
  };

  if (loading) return <Box display="flex" justifyContent="center" py={6}><CircularProgress /></Box>;
  if (loadError) return <Alert severity="error" sx={{ maxWidth: 700, mx: "auto" }}>{loadError}</Alert>;

  return (
    <Box sx={{ maxWidth: 1000, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>Admin — Cost Code List</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Manage cost centers and project codes. All changes are audited via RLS. Direct edits to financial fields (if any) are blocked by trigger.
      </Typography>
      {isFinance && (
        <Button variant="contained" sx={{ mb: 2 }} onClick={openNewDialog}>
          New Cost Code
        </Button>
      )}
      <Paper variant="outlined">
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Project Code</TableCell>
                <TableCell>Tenant</TableCell>
                {isFinance && <TableCell>Actions</TableCell>}
              </TableRow>
            </TableHead>
            <TableBody>
              {items.map((item) => (
                <TableRow key={item.id} hover>
                  <TableCell>{item.name}</TableCell>
                  <TableCell>{item.project_code || "—"}</TableCell>
                  <TableCell>{item.tenant_id ? item.tenant_id.slice(0, 8) : "—"}</TableCell>
                  {isFinance && (
                    <TableCell>
                      <Button size="small" onClick={() => openEditDialog(item)}>Edit</Button>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      <Dialog open={dialogOpen} onClose={closeEdit} maxWidth="sm" fullWidth>
        <DialogTitle>Cost Code — {editTarget ? "Edit" : "New"}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Name" fullWidth value={editForm.name} onChange={(e) => setEditForm({ ...editForm, name: e.target.value })} />
            <TextField label="Project Code" fullWidth value={editForm.project_code} onChange={(e) => setEditForm({ ...editForm, project_code: e.target.value })} />
            <TextField
              label="Budget Amount (UGX)"
              type="number"
              fullWidth
              value={editForm.budget_amount}
              onChange={(e) => setEditForm({ ...editForm, budget_amount: e.target.value })}
            />
            {editError && <Alert severity="error">{editError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={closeEdit}>Cancel</Button>
          <Button onClick={saveEdit} variant="contained" disabled={editSubmitting}>
            {editSubmitting ? "Saving…" : "Save"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}