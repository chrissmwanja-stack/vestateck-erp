import { Alert, Box, Button, Checkbox, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, FormControlLabel, FormGroup, Stack, Typography } from "@mui/material";
import type { Tenant } from "./companiesList";
import { useModuleRegistry } from "../../lib/useModuleRegistry";

export function ModulesDialog({
  target,
  selection,
  loading,
  saving,
  error,
  onClose,
  onToggle,
  onSave,
}: {
  target: Tenant | null;
  selection: Set<string>;
  loading: boolean;
  saving: boolean;
  error: string | null;
  onClose: () => void;
  onToggle: (m: string) => void;
  onSave: () => void;
}) {
  const { entitledModules, loading: registryLoading, error: registryError } = useModuleRegistry();
  const busy = loading || registryLoading;
  return (
    <Dialog open={!!target} onClose={onClose} maxWidth="xs" fullWidth>
      <DialogTitle>Modules — {target?.name}</DialogTitle>
      <DialogContent>
        {busy ? (
          <Box display="flex" justifyContent="center" py={3}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <Stack spacing={1} sx={{ mt: 1 }}>
            <Typography variant="body2" color="text.secondary">
              Modules this company can access. Finance and core Purchasing & Logistics aren't listed — every tenant has those by default.
            </Typography>
            <FormGroup>
              {entitledModules.map((opt) => (
                <FormControlLabel
                  key={opt.key}
                  control={<Checkbox checked={selection.has(opt.key)} onChange={() => onToggle(opt.key)} disabled={saving} />}
                  label={opt.name}
                />
              ))}
            </FormGroup>
            {(error || registryError) && <Alert severity="error">{error ?? registryError}</Alert>}
          </Stack>
        )}
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={saving}>
          Cancel
        </Button>
        <Button onClick={onSave} variant="contained" disabled={saving || busy}>
          {saving ? "Saving…" : "Save"}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
