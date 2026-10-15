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
    inviteAdminOpen,
    setInviteAdminOpen,
    inviteEmail,
    setInviteEmail,
    inviteError,
    confirmInviteAdmin,
    deleteOpen,
    setDeleteOpen,
    deleteConfirm,
    setDeleteConfirm,
    deleteError,
    confirmDelete,
  } = state;

  return (
    <>
      <Dialog open={inviteAdminOpen} onClose={() => !dialogSaving && setInviteAdminOpen(false)} fullWidth maxWidth="xs">
        <DialogTitle>Invite company admin</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {t.name} has no admin yet. We'll email an invitation; they set their password and become the company admin.
            The address must not already have an account on the platform.
          </DialogContentText>
          <TextField
            autoFocus
            fullWidth
            type="email"
            sx={{ mt: 2 }}
            label="Admin email"
            value={inviteEmail}
            onChange={(e) => setInviteEmail(e.target.value)}
            disabled={dialogSaving}
            error={!!inviteError}
            helperText={inviteError ?? ' '}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setInviteAdminOpen(false)} disabled={dialogSaving}>
            Cancel
          </Button>
          <Button variant="contained" onClick={confirmInviteAdmin} disabled={dialogSaving || !inviteEmail.trim()}>
            {dialogSaving ? 'Sending…' : 'Send invite'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={deleteOpen} onClose={() => !dialogSaving && setDeleteOpen(false)} fullWidth maxWidth="xs">
        <DialogTitle>Delete company?</DialogTitle>
        <DialogContent>
          <DialogContentText>
            This permanently removes <strong>{t.name}</strong> and its starter setup. It only works for companies with no
            users and no data; otherwise suspend instead. Type the company name to confirm.
          </DialogContentText>
          <TextField
            autoFocus
            fullWidth
            sx={{ mt: 2 }}
            label="Company name"
            value={deleteConfirm}
            onChange={(e) => setDeleteConfirm(e.target.value)}
            disabled={dialogSaving}
          />
          <TextField
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 2 }}
            label="Reason (optional)"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={dialogSaving}
            error={!!deleteError}
            helperText={deleteError ?? 'Recorded in the platform audit log.'}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDeleteOpen(false)} disabled={dialogSaving}>
            Cancel
          </Button>
          <Button
            color="error"
            variant="contained"
            onClick={confirmDelete}
            disabled={dialogSaving || deleteConfirm.trim() !== t.name}
          >
            {dialogSaving ? 'Deleting…' : 'Delete company'}
          </Button>
        </DialogActions>
      </Dialog>

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