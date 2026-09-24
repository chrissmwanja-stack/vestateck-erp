import { Alert, Box, Button, Paper, Stack, TextField, Typography } from '@mui/material';
import { appliesToLabel } from './Constants';
import type { WorkflowStage } from './Types';
import type { CompanyDetailState } from './useCompanyDetail';

export function ApprovalsTab({ state }: { state: CompanyDetailState }) {
  const { stages, blockedReason, saveError, setSaveError, drafts, setDrafts, savingStageId, saveThreshold } = state;

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
                  <Stack key={stage.id} direction="row" spacing={1} alignItems="center">
                    <Box sx={{ flex: 1 }}>
                      <Typography variant="body2">{stage.name}</Typography>
                      <Typography variant="caption" color="text.secondary">
                        {stage.approver_role}
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
                ))}
              </Stack>
            </Paper>
          ))}
        </Stack>
      )}
    </>
  );
}