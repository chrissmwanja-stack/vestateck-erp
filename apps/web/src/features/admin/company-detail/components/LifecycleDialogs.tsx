import { Button, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle, TextField } from '@mui/material';
import type { TenantRow } from './Types';
import type { CompanyDetailState } from './useCompanyDetail';

export function LifecycleDialogs({ state, t }: { state: CompanyDetailState; t: TenantRow }) {
  const {
    statusDialog,
    setStatusDialog,
    readOnlyDialog,
    setReadOnlyDialog,
    reason,
    setReason,
    dialogSaving,
    confirmStatus,
    confirmReadOnly,
  } = state;

  return (
    <>
      <Dialog open={!!statusDialog} onClose={() => !dialogSaving && setStatusDialog(null)}>
        <DialogTitle>{statusDialog === 'suspended' ? 'Suspend company?' : 'Reactivate company?'}</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {statusDialog === 'suspended' ? (
              <>
                {t.name} will be marked suspended. Their users will immediately lose access (they'll see a "your
                company's access has been suspended" message). You'll still be able to View as them.
              </>
            ) : (
              <>{t.name} will be marked active again.</>
            )}
          </DialogContentText>
          <TextField
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 2 }}
            label={statusDialog === 'suspended' ? 'Reason (required)' : 'Reason (optional)'}
            placeholder={statusDialog === 'suspended' ? 'e.g. Invoice INV-0231 unpaid 60 days past due' : 'e.g. Payment received 22 Sep'}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={dialogSaving}
            helperText="Recorded in the platform audit log."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatusDialog(null)} disabled={dialogSaving}>
            Cancel
          </Button>
          <Button
            color={statusDialog === 'suspended' ? 'error' : 'success'}
            onClick={confirmStatus}
            disabled={dialogSaving || (statusDialog === 'suspended' && reason.trim().length === 0)}
          >
            {dialogSaving ? 'Saving…' : statusDialog === 'suspended' ? 'Suspend' : 'Reactivate'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={readOnlyDialog !== null} onClose={() => !dialogSaving && setReadOnlyDialog(null)}>
        <DialogTitle>{readOnlyDialog ? 'Put company in read-only mode?' : 'Lift read-only mode?'}</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {readOnlyDialog ? (
              <>
                {t.name}'s users will keep signing in and seeing their data, but every create/edit/delete will be
                refused with a message quoting the reason below. Platform admins are exempt.
              </>
            ) : (
              <>{t.name}'s users will be able to make changes again.</>
            )}
          </DialogContentText>
          <TextField
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 2 }}
            label={readOnlyDialog ? 'Reason (required — shown to their users)' : 'Reason (optional)'}
            placeholder={readOnlyDialog ? 'e.g. Subscription payment overdue — contact billing@vestateck.com' : ''}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={dialogSaving}
            helperText="Recorded in the platform audit log."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setReadOnlyDialog(null)} disabled={dialogSaving}>
            Cancel
          </Button>
          <Button
            color="warning"
            onClick={confirmReadOnly}
            disabled={dialogSaving || (readOnlyDialog === true && reason.trim().length === 0)}
          >
            {dialogSaving ? 'Saving…' : readOnlyDialog ? 'Make read-only' : 'Lift read-only'}
          </Button>
        </DialogActions>
      </Dialog>
    </>
  );
}