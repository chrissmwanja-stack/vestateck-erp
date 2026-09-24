import { Button, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle, TextField } from "@mui/material";
import type { Tenant } from "./companiesList";

export function SuspendReactivateDialog({
  target,
  saving,
  reason,
  setReason,
  onClose,
  onConfirm,
}: {
  target: { tenant: Tenant; next: "active" | "suspended" } | null;
  saving: boolean;
  reason: string;
  setReason: (v: string) => void;
  onClose: () => void;
  onConfirm: () => void;
}) {
  return (
    <Dialog open={!!target} onClose={() => !saving && onClose()}>
      <DialogTitle>{target?.next === "suspended" ? "Suspend company?" : "Reactivate company?"}</DialogTitle>
      <DialogContent>
        <DialogContentText>
          {target?.next === "suspended" ? (
            <>
              {target?.tenant.name} will be marked suspended. Their users will immediately lose access to the platform (they'll see a "your company's
              access has been suspended" message) — you'll still be able to "View as" them for support purposes.
            </>
          ) : (
            <>{target?.tenant.name} will be marked active again.</>
          )}
        </DialogContentText>
        <TextField
          fullWidth
          multiline
          minRows={2}
          sx={{ mt: 2 }}
          label={target?.next === "suspended" ? "Reason (required)" : "Reason (optional)"}
          placeholder={target?.next === "suspended" ? "e.g. Invoice INV-0231 unpaid 60 days past due" : "e.g. Payment received 22 Sep"}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          disabled={saving}
          helperText="Recorded in the platform audit log."
        />
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={saving}>
          Cancel
        </Button>
        <Button
          color={target?.next === "suspended" ? "warning" : "success"}
          onClick={onConfirm}
          disabled={saving || (target?.next === "suspended" && reason.trim().length === 0)}
        >
          {saving ? "Saving…" : target?.next === "suspended" ? "Suspend" : "Activate"}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
