import { useState } from "react";
import {
  Alert,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  MenuItem,
  Stack,
  Switch,
  TextField,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";
import { useAuth } from "../../lib/authContext";
import { resolveTenantId } from "../../lib/ResolveTenantId";
import type { Stage, AppliesTo } from "./useApprovalWorkflowData";

const emptyStageForm = {
  name: "",
  approver_role: "",
  sequence_order: 1,
  threshold_amount: "",
  next_stage_low_id: "",
  next_stage_high_id: "",
  requires_offer_entry: false,
  requires_offer_selection: false,
  blocks_offer_submitter_approval: false,
  is_finance_terminal_stage: false,
  is_active: true,
};

export type StageFormState = typeof emptyStageForm;

export function useStageDialog(
  stagesForAppliesTo: Stage[],
  appliesTo: AppliesTo,
  onSaved: () => void,
) {
  const { session } = useAuth();
  const [open, setOpen] = useState(false);
  const [editStage, setEditStage] = useState<Stage | null>(null);
  const [form, setForm] = useState<StageFormState>(emptyStageForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [occupancyWarning, setOccupancyWarning] = useState<{ openRequests: number; openInvoices: number } | null>(null);
  const [occupancyChecking, setOccupancyChecking] = useState(false);

  const hasThreshold = form.threshold_amount.trim() !== "";

  const openNew = () => {
    setEditStage(null);
    setForm({
      ...emptyStageForm,
      sequence_order: stagesForAppliesTo.length > 0 ? Math.max(...stagesForAppliesTo.map((s) => s.sequence_order)) + 1 : 1,
    });
    setSaveError(null);
    setOpen(true);
  };

  const openEdit = (stage: Stage) => {
    setEditStage(stage);
    setForm({
      name: stage.name,
      approver_role: stage.approver_role,
      sequence_order: stage.sequence_order,
      threshold_amount: stage.threshold_amount === null ? "" : String(stage.threshold_amount),
      next_stage_low_id: stage.next_stage_low_id ?? "",
      next_stage_high_id: stage.next_stage_high_id ?? "",
      requires_offer_entry: stage.requires_offer_entry,
      requires_offer_selection: stage.requires_offer_selection,
      blocks_offer_submitter_approval: stage.blocks_offer_submitter_approval,
      is_finance_terminal_stage: stage.is_finance_terminal_stage,
      is_active: stage.is_active,
    });
    setSaveError(null);
    setOccupancyWarning(null);
    setOpen(true);
  };

  const close = () => {
    if (!saving) setOpen(false);
  };

  const routingFieldsChanged = (): boolean => {
    if (!editStage) return false;
    const newThreshold = hasThreshold ? Number(form.threshold_amount) : null;
    return (
      newThreshold !== editStage.threshold_amount ||
      (form.next_stage_low_id || null) !== editStage.next_stage_low_id ||
      (hasThreshold ? form.next_stage_high_id || null : null) !== editStage.next_stage_high_id ||
      (editStage.is_active && !form.is_active)
    );
  };

  const save = async (skipOccupancyCheck = false) => {
    setSaveError(null);
    if (!form.name.trim()) {
      setSaveError("Name is required.");
      return;
    }
    if (!form.approver_role.trim()) {
      setSaveError("Approver role is required.");
      return;
    }
    if (editStage && (form.next_stage_low_id === editStage.id || form.next_stage_high_id === editStage.id)) {
      setSaveError("A stage cannot point to itself as its own next stage.");
      return;
    }
    if (hasThreshold && !form.next_stage_high_id) {
      setSaveError('A threshold needs an "above threshold" next stage as well as an "at or below" one.');
      return;
    }

    if (!skipOccupancyCheck && editStage && routingFieldsChanged()) {
      setOccupancyChecking(true);
      const { data, error: rpcError } = await supabase
        .rpc("count_open_items_at_workflow_stage", { p_stage_id: editStage.id })
        .single();
      setOccupancyChecking(false);
      if (!rpcError && data) {
        const counts = data as { open_requests: number; open_invoices: number };
        if (counts.open_requests > 0 || counts.open_invoices > 0) {
          setOccupancyWarning({ openRequests: counts.open_requests, openInvoices: counts.open_invoices });
          return;
        }
      }
    }

    setSaving(true);
    const payload = {
      name: form.name.trim(),
      approver_role: form.approver_role.trim(),
      sequence_order: form.sequence_order,
      threshold_amount: hasThreshold ? Number(form.threshold_amount) : null,
      next_stage_low_id: form.next_stage_low_id || null,
      next_stage_high_id: hasThreshold ? form.next_stage_high_id || null : null,
      requires_offer_entry: form.requires_offer_entry,
      requires_offer_selection: form.requires_offer_selection,
      blocks_offer_submitter_approval: form.blocks_offer_submitter_approval,
      is_finance_terminal_stage: form.is_finance_terminal_stage,
      is_active: form.is_active,
      applies_to: appliesTo,
    };

    let err;
    if (editStage) {
      ({ error: err } = await supabase.from("workflow_stages").update(payload).eq("id", editStage.id));
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setSaving(false);
        setSaveError(tenantResult.error);
        return;
      }
      ({ error: err } = await supabase.from("workflow_stages").insert({ ...payload, tenant_id: tenantResult.tenantId }));
    }
    setSaving(false);
    if (err) {
      setSaveError(err.message);
      return;
    }
    setOpen(false);
    onSaved();
  };

  return {
    open,
    editStage,
    form,
    setForm,
    saving,
    saveError,
    occupancyWarning,
    occupancyChecking,
    hasThreshold,
    openNew,
    openEdit,
    close,
    save,
  };
}

export function StageDialog({
  dialog,
  stagesForAppliesTo,
}: {
  dialog: ReturnType<typeof useStageDialog>;
  stagesForAppliesTo: Stage[];
}) {
  return (
    <Dialog open={dialog.open} onClose={dialog.close} maxWidth="sm" fullWidth>
      <DialogTitle>{dialog.editStage ? "Edit Stage" : "New Stage"}</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ mt: 1 }}>
          <TextField
            label="Stage name"
            fullWidth
            value={dialog.form.name}
            onChange={(e) => dialog.setForm((v) => ({ ...v, name: e.target.value }))}
          />
          <TextField
            label="Approver role"
            fullWidth
            value={dialog.form.approver_role}
            helperText="A role label, e.g. Cost Control Manager, PM, DGM, Finance."
            onChange={(e) => dialog.setForm((v) => ({ ...v, approver_role: e.target.value }))}
          />
          <TextField
            label="Sequence order"
            type="number"
            value={dialog.form.sequence_order}
            onChange={(e) => dialog.setForm((v) => ({ ...v, sequence_order: Number(e.target.value) }))}
            sx={{ width: 200 }}
          />
          <TextField
            label="Threshold amount (optional)"
            type="number"
            value={dialog.form.threshold_amount}
            helperText="Leave blank if this stage always goes to the same next stage regardless of amount."
            onChange={(e) => dialog.setForm((v) => ({ ...v, threshold_amount: e.target.value }))}
            fullWidth
          />
          <TextField
            select
            label={dialog.hasThreshold ? "Next stage — at or below threshold" : "Next stage"}
            fullWidth
            value={dialog.form.next_stage_low_id}
            onChange={(e) => dialog.setForm((v) => ({ ...v, next_stage_low_id: e.target.value }))}
          >
            <MenuItem value="">None (this is a final stage)</MenuItem>
            {stagesForAppliesTo
              .filter((s) => !dialog.editStage || s.id !== dialog.editStage.id)
              .map((s) => (
                <MenuItem key={s.id} value={s.id}>
                  {s.name}
                </MenuItem>
              ))}
          </TextField>
          {dialog.hasThreshold && (
            <TextField
              select
              label="Next stage — above threshold"
              fullWidth
              value={dialog.form.next_stage_high_id}
              onChange={(e) => dialog.setForm((v) => ({ ...v, next_stage_high_id: e.target.value }))}
            >
              <MenuItem value="">None</MenuItem>
              {stagesForAppliesTo
                .filter((s) => !dialog.editStage || s.id !== dialog.editStage.id)
                .map((s) => (
                  <MenuItem key={s.id} value={s.id}>
                    {s.name}
                  </MenuItem>
                ))}
            </TextField>
          )}
          <FormControlLabel
            control={
              <Switch
                checked={dialog.form.requires_offer_entry}
                onChange={(e) => dialog.setForm((v) => ({ ...v, requires_offer_entry: e.target.checked }))}
              />
            }
            label="Requires a vendor offer to be entered before this stage"
          />
          <FormControlLabel
            control={
              <Switch
                checked={dialog.form.requires_offer_selection}
                onChange={(e) => dialog.setForm((v) => ({ ...v, requires_offer_selection: e.target.checked }))}
              />
            }
            label="Requires an offer to be selected before this stage"
          />
          <FormControlLabel
            control={
              <Switch
                checked={dialog.form.blocks_offer_submitter_approval}
                onChange={(e) => dialog.setForm((v) => ({ ...v, blocks_offer_submitter_approval: e.target.checked }))}
              />
            }
            label="The person who submitted the offer can't approve this stage"
          />
          <FormControlLabel
            control={
              <Switch
                checked={dialog.form.is_finance_terminal_stage}
                onChange={(e) => dialog.setForm((v) => ({ ...v, is_finance_terminal_stage: e.target.checked }))}
              />
            }
            label="This is Finance's terminal stage"
          />
          <FormControlLabel
            control={
              <Switch
                checked={dialog.form.is_active}
                onChange={(e) => dialog.setForm((v) => ({ ...v, is_active: e.target.checked }))}
              />
            }
            label="Active"
          />
          {dialog.occupancyWarning && (
            <Alert severity="warning">
              {dialog.occupancyWarning.openRequests > 0 && (
                <>{dialog.occupancyWarning.openRequests} open request{dialog.occupancyWarning.openRequests === 1 ? "" : "s"}</>
              )}
              {dialog.occupancyWarning.openRequests > 0 && dialog.occupancyWarning.openInvoices > 0 && " and "}
              {dialog.occupancyWarning.openInvoices > 0 && (
                <>{dialog.occupancyWarning.openInvoices} open invoice{dialog.occupancyWarning.openInvoices === 1 ? "" : "s"}</>
              )}{" "}
              {dialog.occupancyWarning.openRequests + dialog.occupancyWarning.openInvoices === 1 ? "is" : "are"} currently sitting at this stage.
              This change applies the next time each one advances — it won't move or reroute anything that's already there.
            </Alert>
          )}
          {dialog.saveError && <Alert severity="error">{dialog.saveError}</Alert>}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={dialog.close} disabled={dialog.saving}>
          Cancel
        </Button>
        {dialog.occupancyWarning ? (
          <Button onClick={() => dialog.save(true)} variant="contained" color="warning" disabled={dialog.saving}>
            {dialog.saving ? "Saving…" : "Save anyway"}
          </Button>
        ) : (
          <Button onClick={() => dialog.save()} variant="contained" disabled={dialog.saving || dialog.occupancyChecking}>
            {dialog.occupancyChecking ? "Checking…" : dialog.saving ? "Saving…" : "Save"}
          </Button>
        )}
      </DialogActions>
    </Dialog>
  );
}
