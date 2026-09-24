import { Button, Chip, MenuItem, Stack, Table, TableBody, TableCell, TableContainer, TableHead, TableRow, TextField } from "@mui/material";
import { Add as AddIcon } from "@mui/icons-material";
import type { Stage, AppliesTo } from "./useApprovalWorkflowData";

export function StagesTab({
  stagesForAppliesTo,
  stageNameById,
  appliesTo,
  setAppliesTo,
  onNew,
  onEdit,
}: {
  stagesForAppliesTo: Stage[];
  stageNameById: Map<string, string>;
  appliesTo: AppliesTo;
  setAppliesTo: (v: AppliesTo) => void;
  onNew: () => void;
  onEdit: (s: Stage) => void;
}) {
  return (
    <>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <TextField
          select
          size="small"
          label="Applies to"
          value={appliesTo}
          onChange={(e) => setAppliesTo(e.target.value as AppliesTo)}
          sx={{ width: 220 }}
        >
          <MenuItem value="requests">Material / Purchase Requests</MenuItem>
          <MenuItem value="invoices">Invoices</MenuItem>
        </TextField>
        <Button variant="contained" startIcon={<AddIcon />} onClick={onNew}>
          New Stage
        </Button>
      </Stack>

      <TableContainer>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Order</TableCell>
              <TableCell>Name</TableCell>
              <TableCell>Approver Role</TableCell>
              <TableCell>Threshold</TableCell>
              <TableCell>Branches to</TableCell>
              <TableCell>Status</TableCell>
              <TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {stagesForAppliesTo.map((stage) => (
              <TableRow key={stage.id} hover>
                <TableCell>{stage.sequence_order}</TableCell>
                <TableCell>
                  {stage.name}
                  {stage.is_finance_terminal_stage && <Chip size="small" label="Terminal" sx={{ ml: 1 }} />}
                </TableCell>
                <TableCell>{stage.approver_role}</TableCell>
                <TableCell>{stage.threshold_amount === null ? "—" : stage.threshold_amount.toLocaleString()}</TableCell>
                <TableCell>
                  {stage.threshold_amount !== null ? (
                    <>
                      ≤ threshold → {stage.next_stage_low_id ? stageNameById.get(stage.next_stage_low_id) ?? "—" : "—"}
                      <br />&gt; threshold → {stage.next_stage_high_id ? stageNameById.get(stage.next_stage_high_id) ?? "—" : "—"}
                    </>
                  ) : (
                    (stage.next_stage_low_id ? stageNameById.get(stage.next_stage_low_id) : null) ?? "— (final)"
                  )}
                </TableCell>
                <TableCell>
                  <Chip size="small" label={stage.is_active ? "Active" : "Inactive"} color={stage.is_active ? "success" : "default"} />
                </TableCell>
                <TableCell align="right">
                  <Button size="small" onClick={() => onEdit(stage)}>
                    Edit
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {stagesForAppliesTo.length === 0 && (
              <TableRow>
                <TableCell colSpan={7} align="center" sx={{ color: "text.secondary", py: 3 }}>
                  No stages configured yet for this type.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
    </>
  );
}
