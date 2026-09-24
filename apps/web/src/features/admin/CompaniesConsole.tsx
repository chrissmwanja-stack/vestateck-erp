import { useEffect, useState } from "react";
import { Alert, Box, Button, InputAdornment, MenuItem, Paper, Stack, TextField, Typography, CircularProgress } from "@mui/material";
import { Add as AddIcon, Download as DownloadIcon, Search as SearchIcon } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import CompanyCreateWizard from "./CompanyCreateWizard";
import { companiesToCsv, downloadCsv, EMPTY_FILTERS, PLAN_LABELS, type CompanyFilters, type Tenant } from "./companiesList";
import { STAGE_LABELS, STAGE_ORDER } from "./platformHealth";
import { supabase } from "../../lib/supabaseClient";
import { resendInvite, revokeInvite } from "../team/inviteActions";
import ImpersonationReasonDialog from "./ImpersonationReasonDialog";
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from "./usePlatformAdminSession";
import { useCompaniesData, type CompanyAdminInvitation } from "./useCompaniesData";
import { useCompanyFilters } from "./useCompanyFilters";
import { CompaniesTable, InvitationsTable } from "./CompaniesTable";
import { RevokeInviteDialog } from "./RevokeInviteDialog";
import { SuspendReactivateDialog } from "./SuspendReactivateDialog";
import { ModulesDialog, MODULE_OPTIONS } from "./ModulesDialog";

function usePlatformAdminAccess() {
  const [isPlatformAdmin, setIsPlatformAdmin] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;
    const fetchAccess = async (userId: string | undefined) => {
      if (!userId) {
        if (!cancelled) setIsPlatformAdmin(false);
        return;
      }
      const { data, error } = await supabase.from("app_users").select("is_platform_admin").eq("id", userId).maybeSingle();
      if (cancelled) return;
      setIsPlatformAdmin(error ? false : Boolean(data?.is_platform_admin));
    };
    supabase.auth.getSession().then(({ data: sessionData }) => {
      if (!cancelled) fetchAccess(sessionData.session?.user.id);
    });
    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (cancelled) return;
      setIsPlatformAdmin(null);
      fetchAccess(session?.user.id);
    });
    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
    };
  }, []);
  return isPlatformAdmin;
}

export default function CompaniesConsole() {
  const isPlatformAdmin = usePlatformAdminAccess();
  const navigate = useNavigate();
  const { rows, loading, error, setError, invitations, loadingInvites, actionError, setActionError, actionNotice, setActionNotice, load, loadInvitations } =
    useCompaniesData();

  const [wizardOpen, setWizardOpen] = useState(false);
  const [rowActionId, setRowActionId] = useState<string | null>(null);
  const [revokeTarget, setRevokeTarget] = useState<CompanyAdminInvitation | null>(null);
  const [impersonateTarget, setImpersonateTarget] = useState<Tenant | null>(null);
  const { session: adminSession } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(adminSession);

  const { filters, setFilters, sortKey, sortDir, page, setPage, rowsPerPage, setRowsPerPage, filteredRows, pagedRows, toggleSort } = useCompanyFilters(rows);

  const [modulesTarget, setModulesTarget] = useState<Tenant | null>(null);
  const [moduleSelection, setModuleSelection] = useState<Set<string>>(new Set());
  const [modulesLoading, setModulesLoading] = useState(false);
  const [modulesSaving, setModulesSaving] = useState(false);
  const [modulesError, setModulesError] = useState<string | null>(null);

  const [statusTarget, setStatusTarget] = useState<{ tenant: Tenant; next: "active" | "suspended" } | null>(null);
  const [statusSaving, setStatusSaving] = useState(false);
  const [statusReason, setStatusReason] = useState("");

  useEffect(() => {
    load();
    loadInvitations();
  }, [load, loadInvitations]);

  const handleResend = async (invitation: CompanyAdminInvitation) => {
    setActionError(null);
    setActionNotice(null);
    setRowActionId(invitation.id);
    const { error } = await resendInvite(invitation.id);
    setRowActionId(null);
    if (error) {
      setActionError(error);
      return;
    }
    setActionNotice(`Invite resent to ${invitation.email}.`);
    loadInvitations();
  };

  const confirmRevoke = async () => {
    if (!revokeTarget) return;
    setActionError(null);
    setActionNotice(null);
    setRowActionId(revokeTarget.id);
    const { error } = await revokeInvite(revokeTarget.id);
    setRowActionId(null);
    const email = revokeTarget.email;
    setRevokeTarget(null);
    if (error) {
      setActionError(error);
      return;
    }
    setActionNotice(`Invite for ${email} revoked.`);
    loadInvitations();
  };

  const handleImpersonate = (tenant: Tenant) => {
    setActionError(null);
    setImpersonateTarget(tenant);
  };

  const openModules = async (tenant: Tenant) => {
    setModulesError(null);
    setModulesTarget(tenant);
    setModulesLoading(true);
    const { data, error } = await supabase.rpc("get_tenant_modules", { p_tenant_id: tenant.id });
    setModulesLoading(false);
    if (error) {
      setModulesError(error.message);
      setModuleSelection(new Set());
      return;
    }
    setModuleSelection(new Set((data ?? []) as string[]));
  };

  const closeModules = () => {
    if (!modulesSaving) setModulesTarget(null);
  };

  const toggleModule = (module: string) => {
    setModuleSelection((prev) => {
      const next = new Set(prev);
      if (next.has(module)) next.delete(module);
      else next.add(module);
      return next;
    });
  };

  const saveModules = async () => {
    if (!modulesTarget) return;
    setModulesError(null);
    setModulesSaving(true);
    const { error } = await supabase.rpc("set_tenant_modules", {
      p_tenant_id: modulesTarget.id,
      p_modules: Array.from(moduleSelection),
    });
    setModulesSaving(false);
    if (error) {
      setModulesError(error.message);
      return;
    }
    setActionNotice(`Modules updated for ${modulesTarget.name}.`);
    setModulesTarget(null);
  };

  const confirmStatusChange = async () => {
    if (!statusTarget) return;
    setActionError(null);
    setActionNotice(null);
    setStatusSaving(true);
    const { error } = await supabase.rpc("set_tenant_status", {
      p_tenant_id: statusTarget.tenant.id,
      p_status: statusTarget.next,
      p_reason: statusReason.trim() || null,
    });
    setStatusSaving(false);
    if (error) {
      setActionError(friendlyPlatformError(error.message));
      return;
    }
    setActionNotice(`${statusTarget.tenant.name} ${statusTarget.next === "suspended" ? "suspended" : "reactivated"}.`);
    setStatusTarget(null);
    setStatusReason("");
    load();
  };

  if (isPlatformAdmin === false) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600, mx: "auto", mt: 4 }}>
        The Companies console is only available to platform admins.
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1100 }}>
      <Stack
        direction={{ xs: "column", sm: "row" }}
        justifyContent="space-between"
        alignItems={{ xs: "flex-start", sm: "flex-end" }}
        spacing={2}
        sx={{ mb: 3 }}
      >
        <Box>
          <Typography variant="h4">Companies</Typography>
          <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5, maxWidth: 560 }}>
            Every customer company on the platform. Click a name for its profile, plan, seats and lifecycle controls; use "View as" to step into its
            workspace for support.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<AddIcon />} onClick={() => setWizardOpen(true)} sx={{ flexShrink: 0 }}>
          New company
        </Button>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {actionError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setActionError(null)}>
          {actionError}
        </Alert>
      )}

      {!loading && rows.length > 0 && (
        <Stack direction="row" spacing={2} flexWrap="wrap" sx={{ mb: 4 }}>
          {[
            { label: "Companies onboarded", value: rows.length },
            { label: "Active", value: rows.filter((r) => r.status === "active").length },
            { label: "Pending", value: rows.filter((r) => r.status === "pending").length },
            { label: "Total members", value: rows.reduce((sum, r) => sum + (r.member_count ?? 0), 0) },
            { label: "Requests (30d)", value: rows.reduce((sum, r) => sum + (r.request_count_30d ?? 0), 0) },
          ].map((stat) => (
            <Paper
              key={stat.label}
              variant="outlined"
              sx={{ px: 2.5, py: 1.75, minWidth: 150, borderTop: (theme) => `3px solid ${theme.palette.secondary.main}` }}
            >
              <Typography variant="h4" sx={{ color: "secondary.main", lineHeight: 1.1 }}>
                {stat.value}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {stat.label}
              </Typography>
            </Paper>
          ))}
        </Stack>
      )}

      <Stack direction={{ xs: "column", md: "row" }} spacing={1.5} alignItems={{ md: "center" }} sx={{ mb: 1.5 }} useFlexGap flexWrap="wrap">
        <TextField
          size="small"
          placeholder="Search name or contact email"
          value={filters.q}
          onChange={(e) => setFilters((f) => ({ ...f, q: e.target.value }))}
          InputProps={{ startAdornment: <InputAdornment position="start"><SearchIcon fontSize="small" /></InputAdornment> }}
          sx={{ minWidth: 260 }}
          inputProps={{ "aria-label": "Search companies" }}
        />
        <TextField
          select
          size="small"
          label="Status"
          value={filters.status}
          onChange={(e) => setFilters((f) => ({ ...f, status: e.target.value as CompanyFilters["status"] }))}
          sx={{ minWidth: 130 }}
        >
          <MenuItem value="">Any status</MenuItem>
          <MenuItem value="active">Active</MenuItem>
          <MenuItem value="pending">Pending</MenuItem>
          <MenuItem value="suspended">Suspended</MenuItem>
        </TextField>
        <TextField
          select
          size="small"
          label="Plan"
          value={filters.plan}
          onChange={(e) => setFilters((f) => ({ ...f, plan: e.target.value }))}
          sx={{ minWidth: 130 }}
        >
          <MenuItem value="">Any plan</MenuItem>
          {Object.entries(PLAN_LABELS).map(([v, l]) => (
            <MenuItem key={v} value={v}>
              {l}
            </MenuItem>
          ))}
        </TextField>
        <TextField
          select
          size="small"
          label="Subscription"
          value={filters.subscription}
          onChange={(e) => setFilters((f) => ({ ...f, subscription: e.target.value }))}
          sx={{ minWidth: 150 }}
        >
          <MenuItem value="">Any</MenuItem>
          <MenuItem value="trialing">Trialing</MenuItem>
          <MenuItem value="active">Active (paid)</MenuItem>
          <MenuItem value="past_due">Past due</MenuItem>
          <MenuItem value="cancelled">Cancelled</MenuItem>
        </TextField>
        <TextField
          select
          size="small"
          label="Needs attention"
          value={filters.flag}
          onChange={(e) => setFilters((f) => ({ ...f, flag: e.target.value as CompanyFilters["flag"] }))}
          sx={{ minWidth: 190 }}
        >
          <MenuItem value="">Everything</MenuItem>
          <MenuItem value="trial_ending">Trial ending ≤ 14 days</MenuItem>
          <MenuItem value="quiet">Quiet 30+ days</MenuItem>
          <MenuItem value="stalled">Stalled in setup 7+ days</MenuItem>
          <MenuItem value="read_only">In read-only mode</MenuItem>
          <MenuItem value="seats_full">Seats full</MenuItem>
        </TextField>
        <TextField
          select
          size="small"
          label="Onboarding"
          value={filters.stage}
          onChange={(e) => setFilters((f) => ({ ...f, stage: e.target.value }))}
          sx={{ minWidth: 170 }}
        >
          <MenuItem value="">Any stage</MenuItem>
          {STAGE_ORDER.map((k) => (
            <MenuItem key={k} value={k}>
              {STAGE_LABELS[k]}
            </MenuItem>
          ))}
        </TextField>
        <Box sx={{ flex: 1 }} />
        <Typography variant="body2" color="text.secondary">
          {filteredRows.length === rows.length ? `${rows.length} companies` : `${filteredRows.length} of ${rows.length}`}
        </Typography>
        {(filters.q || filters.status || filters.plan || filters.subscription || filters.flag || filters.stage) && (
          <Button size="small" onClick={() => setFilters(EMPTY_FILTERS)}>
            Clear
          </Button>
        )}
        <Button
          size="small"
          startIcon={<DownloadIcon />}
          disabled={filteredRows.length === 0}
          onClick={() => downloadCsv(`companies-${new Date().toISOString().slice(0, 10)}.csv`, companiesToCsv(filteredRows))}
        >
          Export CSV
        </Button>
      </Stack>

      {loading ? (
        <Box display="flex" justifyContent="center" py={4}>
          <CircularProgress size={24} />
        </Box>
      ) : (
        <CompaniesTable
          pagedRows={pagedRows}
          filteredRows={filteredRows}
          rows={rows}
          sortKey={sortKey}
          sortDir={sortDir}
          page={page}
          rowsPerPage={rowsPerPage}
          onToggleSort={toggleSort}
          onPageChange={setPage}
          onRowsPerPageChange={setRowsPerPage}
          onOpenModules={openModules}
          onOpenStatus={(t, n) => {
            setStatusReason("");
            setStatusTarget({ tenant: t, next: n });
          }}
          onImpersonate={handleImpersonate}
          blockedReason={blockedReason}
          moduleCount={MODULE_OPTIONS.length}
        />
      )}

      <Typography variant="h6" sx={{ mt: 4, mb: 1 }}>
        First-admin invites
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Company admin invites sent from this console, across every tenant.
      </Typography>

      {actionNotice && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setActionNotice(null)}>
          {actionNotice}
        </Alert>
      )}

      <Paper variant="outlined">
        {loadingInvites ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <InvitationsTable
            invitations={invitations}
            rows={rows}
            rowActionId={rowActionId}
            onResend={handleResend}
            onRevoke={setRevokeTarget}
          />
        )}
      </Paper>

      <CompanyCreateWizard
        open={wizardOpen}
        onClose={() => setWizardOpen(false)}
        onCreated={() => {
          load();
          loadInvitations();
        }}
      />

      <RevokeInviteDialog target={revokeTarget} rowActionId={rowActionId} onClose={() => setRevokeTarget(null)} onConfirm={confirmRevoke} />

      <SuspendReactivateDialog
        target={statusTarget}
        saving={statusSaving}
        reason={statusReason}
        setReason={setStatusReason}
        onClose={() => setStatusTarget(null)}
        onConfirm={confirmStatusChange}
      />

      <ImpersonationReasonDialog
        open={!!impersonateTarget}
        tenant={impersonateTarget}
        onClose={() => setImpersonateTarget(null)}
        onStarted={() => {
          setImpersonateTarget(null);
          navigate("/requests/new");
        }}
      />

      <ModulesDialog
        target={modulesTarget}
        selection={moduleSelection}
        loading={modulesLoading}
        saving={modulesSaving}
        error={modulesError}
        onClose={closeModules}
        onToggle={toggleModule}
        onSave={saveModules}
      />
    </Box>
  );
}
