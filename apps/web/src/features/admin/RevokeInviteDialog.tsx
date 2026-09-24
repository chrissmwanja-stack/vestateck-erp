import { Button, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle } from "@mui/material";
import type { CompanyAdminInvitation } from "./useCompaniesData";

export function RevokeInviteDialog({
  target,
  rowActionId,
  onClose,
  onConfirm,
}: {
  target: CompanyAdminInvitation | null;
  rowActionId: string | null;
  onClose: () => void;
  onConfirm: () => void;
}) {
  return (
    <Dialog open={!!target} onClose={onClose}>
      <DialogTitle>Revoke invite?</DialogTitle>
      <DialogContent>
        <DialogContentText>
          {target?.email} won't be able to use this invite link anymore. This can't be undone — you'd need to send a new invite.
        </DialogContentText>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>Cancel</Button>
        <Button color="error" onClick={onConfirm} disabled={rowActionId === target?.id}>
          Revoke invite
        </Button>
      </DialogActions>
    </Dialog>
  );
}
