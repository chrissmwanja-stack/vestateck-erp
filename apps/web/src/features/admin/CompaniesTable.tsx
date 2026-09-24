import { Button, Chip, Paper, Stack, Table, TableBody, TableCell, TableContainer, TableHead, TablePagination, TableRow, TableSortLabel, Tooltip, Typography, Link } from "@mui/material";
import { Link as RouterLink } from "react-router-dom";
import { STAGE_HINTS, STAGE_LABELS, type StageKey } from "./platformHealth";
import type { Tenant, SortKey } from "./companiesList";
import type { CompanyAdminInvitation } from "./useCompaniesData";

const subscriptionColor: Record<string, "default" | "success" | "warning" | "error" | "info"> = {
  trialing: "info",
  active: "success",
  past_due: "warning",
  cancelled: "error",
};

const statusColor: Record<Tenant["status"], "default" | "success" | "warning"> = {
  pending: "warning",
  active: "success",
  suspended: "default",
};

export function CompaniesTable({
  pagedRows,
  filteredRows,
  rows,
  sortKey,
  sortDir,
  page,
  rowsPerPage,
  onToggleSort,
  onPageChange,
  onRowsPerPageChange,
  onOpenModules,
  onOpenStatus,
  onImpersonate,
  blockedReason,
  moduleCount,
}: {
  pagedRows: Tenant[];
  filteredRows: Tenant[];
  rows: Tenant[];
  sortKey: SortKey;
  sortDir: "asc" | "desc";
  page: number;
  rowsPerPage: number;
  onToggleSort: (k: SortKey) => void;
  onPageChange: (p: number) => void;
  onRowsPerPageChange: (n: number) => void;
  onOpenModules: (t: Tenant) => void;
  onOpenStatus: (t: Tenant, next: "active" | "suspended") => void;
  onImpersonate: (t: Tenant) => void;
  blockedReason: string | null;
  moduleCount: number;
}) {
  return (
    <Paper variant="outlined">
      <TableContainer>
        <Table size="small">
          <TableHead>
            <TableRow>
              {(
                [
                  ["name", "Company", "left"],
                  ["status", "Status", "left"],
                  ["plan", "Plan", "left"],
                  ["created_at", "Created", "left"],
                  ["last_activity_at", "Last activity", "left"],
                  ["onboarding_stage", "Onboarding", "left"],
                  ["member_count", "Members", "right"],
                ] as [SortKey, string, "left" | "right"][]
              ).map(([key, label, align]) => (
                <TableCell key={key} align={align} sortDirection={sortKey === key ? sortDir : false}>
                  <TableSortLabel active={sortKey === key} direction={sortKey === key ? sortDir : "asc"} onClick={() => onToggleSort(key)}>
                    {label}
                  </TableSortLabel>
                </TableCell>
              ))}
              <TableCell align="right">Modules</TableCell>
              <TableCell align="right" sortDirection={sortKey === "request_count_30d" ? sortDir : false}>
                <TableSortLabel
                  active={sortKey === "request_count_30d"}
                  direction={sortKey === "request_count_30d" ? sortDir : "asc"}
                  onClick={() => onToggleSort("request_count_30d")}
                >
                  Requests (30d)
                </TableSortLabel>
              </TableCell>
              <TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {pagedRows.map((row) => (
              <TableRow key={row.id} hover>
                <TableCell>
                  <Link component={RouterLink} to={`/admin/companies/${row.id}`}>
                    {row.name}
                  </Link>
                </TableCell>
                <TableCell>
                  <Stack direction="row" spacing={0.5}>
                    <Chip size="small" label={row.status} color={statusColor[row.status]} />
                    {row.read_only && (
                      <Tooltip title="Read-only: users can view but not change anything">
                        <Chip size="small" label="read-only" color="warning" variant="outlined" />
                      </Tooltip>
                    )}
                  </Stack>
                </TableCell>
                <TableCell>
                  {row.plan ? (
                    <Stack direction="row" spacing={0.5} alignItems="center">
                      <Typography variant="body2">{row.plan}</Typography>
                      {row.subscription_status && row.subscription_status !== "active" && (
                        <Chip
                          size="small"
                          variant="outlined"
                          label={row.subscription_status.replace("_", " ")}
                          color={subscriptionColor[row.subscription_status] ?? "default"}
                        />
                      )}
                    </Stack>
                  ) : (
                    "—"
                  )}
                </TableCell>
                <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                <TableCell>{row.last_activity_at ? new Date(row.last_activity_at).toLocaleDateString() : "—"}</TableCell>
                <TableCell>
                  {row.onboarding_stage ? (
                    <Tooltip title={row.onboarding_next_step ?? STAGE_HINTS[row.onboarding_stage as StageKey] ?? ""}>
                      <Chip
                        size="small"
                        variant={row.onboarding_stage === "live" ? "filled" : "outlined"}
                        color={row.onboarding_stalled ? "error" : row.onboarding_stage === "live" ? "success" : "default"}
                        label={`${STAGE_LABELS[row.onboarding_stage as StageKey] ?? row.onboarding_stage}${row.onboarding_stalled ? " · stalled" : ""}`}
                      />
                    </Tooltip>
                  ) : (
                    "—"
                  )}
                </TableCell>
                <TableCell align="right">
                  {row.member_count ?? "—"}
                  {row.seat_limit != null && (
                    <Typography component="span" variant="caption" color="text.secondary">
                      {" "}
                      / {row.seat_limit}
                    </Typography>
                  )}
                </TableCell>
                <TableCell align="right">
                  {row.module_count ?? "—"} / {moduleCount}
                </TableCell>
                <TableCell align="right">{row.request_count_30d ?? "—"}</TableCell>
                <TableCell align="right">
                  <Stack direction="row" spacing={1} justifyContent="flex-end">
                    <Button size="small" onClick={() => onOpenModules(row)}>
                      Modules
                    </Button>
                    {row.status !== "pending" && (
                      <Tooltip title={blockedReason ?? ""}>
                        <span>
                          <Button
                            size="small"
                            color={row.status === "suspended" ? "success" : "warning"}
                            disabled={!!blockedReason}
                            onClick={() => onOpenStatus(row, row.status === "suspended" ? "active" : "suspended")}
                          >
                            {row.status === "suspended" ? "Activate" : "Suspend"}
                          </Button>
                        </span>
                      </Tooltip>
                    )}
                    <Tooltip title={blockedReason ?? ""}>
                      <span>
                        <Button size="small" onClick={() => onImpersonate(row)} disabled={!!blockedReason}>
                          View as
                        </Button>
                      </span>
                    </Tooltip>
                  </Stack>
                </TableCell>
              </TableRow>
            ))}
            {filteredRows.length === 0 && (
              <TableRow>
                <TableCell colSpan={9} align="center" sx={{ color: "text.secondary", py: 3 }}>
                  {rows.length === 0 ? "No companies yet." : "No companies match these filters."}
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
        <TablePagination
          component="div"
          count={filteredRows.length}
          page={page}
          onPageChange={(_, p) => onPageChange(p)}
          rowsPerPage={rowsPerPage}
          onRowsPerPageChange={(e) => onRowsPerPageChange(Number(e.target.value))}
          rowsPerPageOptions={[10, 25, 50, 100]}
        />
      </TableContainer>
    </Paper>
  );
}

const invitationStatusColor: Record<CompanyAdminInvitation["status"], "default" | "success" | "warning" | "error"> = {
  pending: "warning",
  accepted: "success",
  expired: "default",
  revoked: "error",
};

export function InvitationsTable({
  invitations,
  rows,
  rowActionId,
  onResend,
  onRevoke,
}: {
  invitations: CompanyAdminInvitation[];
  rows: Tenant[];
  rowActionId: string | null;
  onResend: (inv: CompanyAdminInvitation) => void;
  onRevoke: (inv: CompanyAdminInvitation) => void;
}) {
  return (
    <TableContainer>
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Email</TableCell>
            <TableCell>Company</TableCell>
            <TableCell>Status</TableCell>
            <TableCell>Sent</TableCell>
            <TableCell align="right">Actions</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {invitations.map((inv) => {
            const tenantName = rows.find((t) => t.id === inv.tenant_id)?.name ?? "—";
            return (
              <TableRow key={inv.id} hover>
                <TableCell>{inv.email}</TableCell>
                <TableCell>{tenantName}</TableCell>
                <TableCell>
                  <Chip size="small" label={inv.status} color={invitationStatusColor[inv.status]} />
                </TableCell>
                <TableCell>{new Date(inv.created_at).toLocaleDateString()}</TableCell>
                <TableCell align="right">
                  {(inv.status === "pending" || inv.status === "expired") && (
                    <Stack direction="row" spacing={1} justifyContent="flex-end">
                      <Button size="small" onClick={() => onResend(inv)} disabled={rowActionId === inv.id}>
                        Resend
                      </Button>
                      {inv.status === "pending" && (
                        <Button size="small" color="error" onClick={() => onRevoke(inv)} disabled={rowActionId === inv.id}>
                          Revoke
                        </Button>
                      )}
                    </Stack>
                  )}
                </TableCell>
              </TableRow>
            );
          })}
          {invitations.length === 0 && (
            <TableRow>
              <TableCell colSpan={5} align="center" sx={{ color: "text.secondary", py: 3 }}>
                No company admin invites sent yet.
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </TableContainer>
  );
}
