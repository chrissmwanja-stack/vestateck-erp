import { useState } from "react";
import { Alert, Button, Dialog, DialogActions, DialogContent, DialogTitle, MenuItem, Stack, TextField } from "@mui/material";
import { supabase } from "../../lib/supabaseClient";
import { useAuth } from "../../lib/authContext";
import { resolveTenantId } from "../../lib/ResolveTenantId";
import type { Assignment, TeamMember, LookupRow, Stage, ScopeType } from "./useApprovalWorkflowData";

const emptyAssignmentForm = {
  user_id: "",
  workflow_stage_id: "",
  scope_type: "global" as ScopeType,
  scope_id: "",
  threshold_max: "",
};

export type AssignmentFormState = typeof emptyAssignmentForm;

export function useAssignmentDialog(
  onSaved: () => void,
) {
  const { session } = useAuth();
  const [open, setOpen] = useState(false);
  const [editAssignment, setEditAssignment] = useState<Assignment | null>(null);
  const [form, setForm] = useState<AssignmentFormState>(emptyAssignmentForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const openNew = () => {
    setEditAssignment(null);
    setForm(emptyAssignmentForm);
    setSaveError(null);
    setOpen(true);
  };

  const openEdit = (a: Assignment) => {
    setEditAssignment(a);
    setForm({
      user_id: a.user_id,
      workflow_stage_id: a.workflow_stage_id,
      scope_type: a.scope_type,
      scope_id: a.scope_id ?? "",
      threshold_max: a.threshold_max === null ? "" : String(a.threshold_max),
    });
    setSaveError(null);
    setOpen(true);
  };

  const close = () => {
    if (!saving) setOpen(false);
  };

  const save = async () => {
    setSaveError(null);
    if (!form.user_id) {
      setSaveError("Choose a team member.");
      return;
    }
    if (!form.workflow_stage_id) {
      setSaveError("Choose a stage.");
      return;
    }
    if (form.scope_type !== "global" && !form.scope_id) {
      setSaveError("Choose a department or cost center for this scope, or switch scope to Global.");
      return;
    }

    setSaving(true);
    const payload = {
      user_id: form.user_id,
      workflow_stage_id: form.workflow_stage_id,
      scope_type: form.scope_type,
      scope_id: form.scope_type === "global" ? null : form.scope_id,
      threshold_max: form.threshold_max.trim() === "" ? null : Number(form.threshold_max),
    };

    let err;
    if (editAssignment) {
      ({ error: err } = await supabase.from("approval_assignments").update(payload).eq("id", editAssignment.id));
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setSaving(false);
        setSaveError(tenantResult.error);
        return;
      }
      ({ error: err } = await supabase.from("approval_assignments").insert({ ...payload, tenant_id: tenantResult.tenantId }));
    }
    setSaving(false);
    if (err) {
      setSaveError(err.message);
      return;
    }
    setOpen(false);
    onSaved();
  };

  return { open, editAssignment, form, setForm, saving, saveError, openNew, openEdit, close, save };
}

export function AssignmentDialog({
  dialog,
  members,
  stages,
  departments,
  costCenters,
}: {
  dialog: ReturnType<typeof useAssignmentDialog>;
  members: TeamMember[];
  stages: Stage[];
  departments: LookupRow[];
  costCenters: LookupRow[];
}) {
  return (
    <Dialog open={dialog.open} onClose={dialog.close} maxWidth="sm" fullWidth>
      <DialogTitle>{dialog.editAssignment ? "Edit Assignment" : "New Assignment"}</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ mt: 1 }}>
          <TextField
            select
            label="Team member"
            fullWidth
            value={dialog.form.user_id}
            onChange={(e) => dialog.setForm((v) => ({ ...v, user_id: e.target.value }))}
          >
            {members.map((m) => (
              <MenuItem key={m.user_id} value={m.user_id}>
                {m.name?.trim() || m.email}
              </MenuItem>
            ))}
          </TextField>
          <TextField
            select
            label="Stage"
            fullWidth
            value={dialog.form.workflow_stage_id}
            onChange={(e) => dialog.setForm((v) => ({ ...v, workflow_stage_id: e.target.value }))}
          >
            {stages.map((s) => (
              <MenuItem key={s.id} value={s.id}>
                {s.name} ({s.applies_to === "requests" ? "Requests" : "Invoices"})
              </MenuItem>
            ))}
          </TextField>
          <TextField
            select
            label="Scope"
            fullWidth
            value={dialog.form.scope_type}
            onChange={(e) => dialog.setForm((v) => ({ ...v, scope_type: e.target.value as ScopeType, scope_id: "" }))}
          >
            <MenuItem value="global">Global (whole company)</MenuItem>
            <MenuItem value="department">Department</MenuItem>
            <MenuItem value="cost_center">Cost center</MenuItem>
          </TextField>
          {dialog.form.scope_type !== "global" && (
            <TextField
              select
              label={dialog.form.scope_type === "department" ? "Department" : "Cost center"}
              fullWidth
              value={dialog.form.scope_id}
              onChange={(e) => dialog.setForm((v) => ({ ...v, scope_id: e.target.value }))}
            >
              {(dialog.form.scope_type === "department" ? departments : costCenters).map((row) => (
                <MenuItem key={row.id} value={row.id}>
                  {row.name}
                </MenuItem>
              ))}
            </TextField>
          )}
          <TextField
            label="Personal approval cap (optional)"
            type="number"
            fullWidth
            value={dialog.form.threshold_max}
            helperText="Leave blank to allow up to the stage's own threshold."
            onChange={(e) => dialog.setForm((v) => ({ ...v, threshold_max: e.target.value }))}
          />
          {dialog.saveError && <Alert severity="error">{dialog.saveError}</Alert>}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={dialog.close} disabled={dialog.saving}>
          Cancel
        </Button>
        <Button onClick={dialog.save} variant="contained" disabled={dialog.saving}>
          {dialog.saving ? "Saving…" : "Save"}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
