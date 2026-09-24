import { Alert, Box, Button, Checkbox, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, FormControlLabel, FormGroup, Stack, Typography } from "@mui/material";
import type { Tenant } from "./companiesList";

const MODULE_OPTIONS: { value: string; label: string }[] = [
  { value: "hr", label: "HR" },
  { value: "legal", label: "Law & Compliance" },
  { value: "bd", label: "Business Development" },
  { value: "it", label: "IT Support" },
  { value: "pmo", label: "PMO" },
  { value: "procurement", label: "Purchasing & Logistics extras" },
  { value: "machine_operation", label: "Machine Operation" },
  { value: "sustainability", label: "Sustainability" },
];

export { MODULE_OPTIONS };

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
  return (
    <Dialog open={!!target} onClose={onClose} maxWidth="xs" fullWidth>
      <DialogTitle>Modules — {target?.name}</DialogTitle>
      <DialogContent>
        {loading ? (
          <Box display="flex" justifyContent="center" py={3}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <Stack spacing={1} sx={{ mt: 1 }}>
            <Typography variant="body2" color="text.secondary">
              Modules this company can access. Finance and core Purchasing & Logistics aren't listed — every tenant has those by default.
            </Typography>
            <FormGroup>
              {MODULE_OPTIONS.map((opt) => (
                <FormControlLabel
                  key={opt.value}
                  control={<Checkbox checked={selection.has(opt.value)} onChange={() => onToggle(opt.value)} disabled={saving} />}
                  label={opt.label}
                />
              ))}
            </FormGroup>
            {error && <Alert severity="error">{error}</Alert>}
          </Stack>
        )}
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={saving}>
          Cancel
        </Button>
        <Button onClick={onSave} variant="contained" disabled={saving || loading}>
          {saving ? "Saving…" : "Save"}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
