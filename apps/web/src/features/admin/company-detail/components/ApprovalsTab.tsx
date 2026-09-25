import { Alert, Box, Button, Paper, Stack, TextField, Typography } from '@mui/material';
import { appliesToLabel } from './Constants';
import type { WorkflowStage } from './Types';
import type { CompanyDetailState } from './useCompanyDetail';

export function ApprovalsTab({ state }: { state: CompanyDetailState }) {
  const {
    stages,
    blockedReason,
    saveError,
    setSaveError,
    drafts,
    setDrafts,
    savingStageId,
    saveThreshold,
    approverDrafts,
    setApproverDrafts,
    savingApproverStageId,
    approverSaveError,
    setApproverSaveError,
    saveApproverRole,
  } = state;

  const thresholdStages = stages.filter((s) => s.threshold_amount !== null);
  const grouped = thresholdStages.reduce<Record<string, WorkflowStage[]>>((acc, s) => {
    (acc[s.applies_to] ??= []).push(s);
    return acc;
  }, {});

  return (
    <>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Amount (UGX) at which each branch point routes to the higher-authority path instead of the default one.
        New tenants are seeded at 5,000,000; edit per stage below.
      </Typography>
      {saveError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setSaveError(null)}>
          {saveError}
        </Alert>
      )}
      {approverSaveError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setApproverSaveError(null)}>
          {approverSaveError}
        </Alert>
      )}
      {thresholdStages.length === 0 ? (
        <Typography variant="body2" color="text.secondary">
          No threshold branch points configured for this tenant.
        </Typography>
      ) : (
        <Stack direction="row" spacing={2} flexWrap="wrap" useFlexGap>
          {Object.entries(grouped).map(([appliesTo, group]) => (
            <Paper key={appliesTo} variant="outlined" sx={{ p: 2, flex: '1 1 320px' }}>
              <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
                {appliesToLabel[appliesTo] ?? appliesTo}
              </Typography>
              <Stack spacing={1.5}>
                {group.map((stage) => (
                  <Stack key={stage.id} spacing={1}>
                    <Typography variant="body2">{stage.name}</Typography>
                    <Stack direction="row" spacing={1} alignItems="center">
                      <TextField
                        size="small"
                        label="Approver label"
                        value={approverDrafts[stage.id] ?? ''}
                        onChange={(e) => setApproverDrafts((prev) => ({ ...prev, [stage.id]: e.target.value }))}
                        sx={{ flex: 1 }}
                        helperText="Display only — doesn't change who actually approves (set at /admin/approval-workflow)."
                      />
                      <Button
                        size="small"
                        variant="outlined"
                        disabled={
                          !!blockedReason ||
                          savingApproverStageId === stage.id ||
                          (approverDrafts[stage.id] ?? '').trim() === stage.approver_role
                        }
                        onClick={() => saveApproverRole(stage.id)}
                      >
                        {savingApproverStageId === stage.id ? 'Saving…' : 'Save'}
                      </Button>
                    </Stack>
                    <Stack direction="row" spacing={1} alignItems="center">
                      <Box sx={{ flex: 1 }}>
                        <Typography variant="caption" color="text.secondary">
                          Threshold (UGX)
                        </Typography>
                      </Box>
                      <TextField
                        size="small"
                        type="number"
                        value={drafts[stage.id] ?? ''}
                        onChange={(e) => setDrafts((prev) => ({ ...prev, [stage.id]: e.target.value }))}
                        sx={{ width: 140 }}
                        inputProps={{ min: 0, step: '0.01' }}
                      />
                      <Button
                        size="small"
                        variant="outlined"
                        disabled={
                          !!blockedReason || savingStageId === stage.id || drafts[stage.id] === String(stage.threshold_amount)
                        }
                        onClick={() => saveThreshold(stage.id)}
                      >
                        {savingStageId === stage.id ? 'Saving…' : 'Save'}
                      </Button>
                    </Stack>
                  </Stack>
                ))}
              </Stack>
            </Paper>
          ))}
        </Stack>
      )}
    </>
  );
}