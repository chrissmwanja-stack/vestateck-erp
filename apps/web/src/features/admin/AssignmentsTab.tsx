import { Button, Stack, Table, TableBody, TableCell, TableContainer, TableHead, TableRow } from "@mui/material";
import { Add as AddIcon } from "@mui/icons-material";
import type { Assignment } from "./useApprovalWorkflowData";

export function AssignmentsTab({
  assignments,
  memberLabelById,
  stageNameById,
  deptNameById,
  costCenterNameById,
  onNew,
  onEdit,
}: {
  assignments: Assignment[];
  memberLabelById: Map<string, string>;
  stageNameById: Map<string, string>;
  deptNameById: Map<string, string>;
  costCenterNameById: Map<string, string>;
  onNew: () => void;
  onEdit: (a: Assignment) => void;
}) {
  return (
    <>
      <Stack direction="row" justifyContent="flex-end" sx={{ mb: 2 }}>
        <Button variant="contained" startIcon={<AddIcon />} onClick={onNew}>
          New Assignment
        </Button>
      </Stack>

      <TableContainer>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Team Member</TableCell>
              <TableCell>Stage</TableCell>
              <TableCell>Scope</TableCell>
              <TableCell>Cap</TableCell>
              <TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {assignments.map((a) => (
              <TableRow key={a.id} hover>
                <TableCell>{memberLabelById.get(a.user_id) ?? a.user_id}</TableCell>
                <TableCell>{stageNameById.get(a.workflow_stage_id) ?? "—"}</TableCell>
                <TableCell>
                  {a.scope_type === "global"
                    ? "Global"
                    : a.scope_type === "department"
                      ? `Department: ${a.scope_id ? deptNameById.get(a.scope_id) ?? "—" : "—"}`
                      : `Cost center: ${a.scope_id ? costCenterNameById.get(a.scope_id) ?? "—" : "—"}`}
                </TableCell>
                <TableCell>{a.threshold_max === null ? "—" : a.threshold_max.toLocaleString()}</TableCell>
                <TableCell align="right">
                  <Button size="small" onClick={() => onEdit(a)}>
                    Edit
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {assignments.length === 0 && (
              <TableRow>
                <TableCell colSpan={5} align="center" sx={{ color: "text.secondary", py: 3 }}>
                  No assignments yet.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
    </>
  );
}
