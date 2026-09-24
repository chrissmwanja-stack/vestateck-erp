import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { supabase } from '../../../../lib/supabaseClient';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from '../../usePlatformAdminSession';
import { buildProfilePatch, draftFrom } from './utils';
import type { Analytics, Note, Profile, ProfileDraft, WorkflowStage } from './Types';

// All state + data flow for the Company Detail screen, split out of the
// component so each tab can stay a plain render function. One
// platform-admin-gated RPC (get_tenant_profile) supplies the summary tab;
// get_company_analytics / get_tenant_workflow_stages feed the other two.
export function useCompanyDetail() {
  const { tenantId } = useParams<{ tenantId: string }>();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const tab = searchParams.get('tab') ?? 'summary';
  const setTab = (next: string) => setSearchParams(next === 'summary' ? {} : { tab: next }, { replace: true });

  const { session: adminSession } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(adminSession);

  const [profile, setProfile] = useState<Profile | null>(null);
  const [analytics, setAnalytics] = useState<Analytics | null>(null);
  const [stages, setStages] = useState<WorkflowStage[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  // Profile editing
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<ProfileDraft | null>(null);
  const [savingProfile, setSavingProfile] = useState(false);

  // Lifecycle dialogs
  const [statusDialog, setStatusDialog] = useState<'active' | 'suspended' | null>(null);
  const [readOnlyDialog, setReadOnlyDialog] = useState<boolean | null>(null); // next value
  const [reason, setReason] = useState('');
  const [dialogSaving, setDialogSaving] = useState(false);
  const [impersonateOpen, setImpersonateOpen] = useState(false);

  // Notes
  const [notes, setNotes] = useState<Note[] | null>(null);
  const [noteDraft, setNoteDraft] = useState('');
  const [noteSaving, setNoteSaving] = useState(false);

  // Threshold drafts keyed by stage id.
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [savingStageId, setSavingStageId] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);

  const loadProfile = useCallback(async () => {
    if (!tenantId) return null;
    const { data, error: err } = await supabase.rpc('get_tenant_profile', { p_tenant_id: tenantId });
    if (err) throw new Error(friendlyPlatformError(err.message));
    return data as unknown as Profile | null;
  }, [tenantId]);

  const load = useCallback(async () => {
    if (!tenantId) return;
    setLoading(true);
    setError(null);
    try {
      const [p, { data: analyticsData, error: analyticsErr }, { data: stagesData, error: stagesErr }] =
        await Promise.all([
          loadProfile(),
          supabase.rpc('get_company_analytics', { p_tenant_id: tenantId }),
          supabase.rpc('get_tenant_workflow_stages', { p_tenant_id: tenantId }),
        ]);
      if (analyticsErr || stagesErr) {
        throw new Error(analyticsErr?.message ?? stagesErr?.message ?? 'Failed to load company.');
      }
      if (!p) {
        setError('Company not found.');
        setLoading(false);
        return;
      }
      const stageRows = (stagesData as unknown as WorkflowStage[]) ?? [];
      setProfile(p);
      setDraft(draftFrom(p.tenant));
      setAnalytics(analyticsData as unknown as Analytics);
      setStages(stageRows);
      setDrafts(
        Object.fromEntries(
          stageRows.filter((s) => s.threshold_amount !== null).map((s) => [s.id, String(s.threshold_amount)])
        )
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load company.');
    }
    setLoading(false);
  }, [tenantId, loadProfile]);

  const refreshProfile = useCallback(async () => {
    try {
      const p = await loadProfile();
      if (p) {
        setProfile(p);
        setDraft(draftFrom(p.tenant));
      }
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Failed to refresh.');
    }
  }, [loadProfile]);

  const loadNotes = useCallback(async () => {
    if (!tenantId) return;
    const { data, error: err } = await supabase
      .from('tenant_notes')
      .select('id, body, author_email, created_at')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false })
      .limit(200);
    if (err) {
      setActionError(err.message);
      return;
    }
    setNotes((data as Note[]) ?? []);
  }, [tenantId]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    if (tab === 'notes' && notes === null) loadNotes();
  }, [tab, notes, loadNotes]);

  const patch = useMemo(() => (profile && draft ? buildProfilePatch(profile.tenant, draft) : {}), [profile, draft]);
  const dirty = Object.keys(patch).length > 0;

  const saveProfile = async () => {
    if (!tenantId || !dirty) return;
    setSavingProfile(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('update_tenant_profile', { p_tenant_id: tenantId, p_patch: patch });
    setSavingProfile(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNotice('Profile saved.');
    setEditing(false);
    await refreshProfile();
  };

  const confirmStatus = async () => {
    if (!tenantId || !statusDialog) return;
    setDialogSaving(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('set_tenant_status', {
      p_tenant_id: tenantId,
      p_status: statusDialog,
      p_reason: reason.trim() || null,
    });
    setDialogSaving(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNotice(statusDialog === 'suspended' ? 'Company suspended.' : 'Company reactivated.');
    setStatusDialog(null);
    setReason('');
    await refreshProfile();
  };

  const confirmReadOnly = async () => {
    if (!tenantId || readOnlyDialog === null) return;
    setDialogSaving(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('set_tenant_read_only', {
      p_tenant_id: tenantId,
      p_read_only: readOnlyDialog,
      p_reason: reason.trim() || null,
    });
    setDialogSaving(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNotice(readOnlyDialog ? 'Company is now read-only.' : 'Read-only mode lifted.');
    setReadOnlyDialog(null);
    setReason('');
    await refreshProfile();
  };

  const addNote = async () => {
    if (!tenantId || noteDraft.trim().length === 0) return;
    setNoteSaving(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('add_tenant_note', { p_tenant_id: tenantId, p_body: noteDraft.trim() });
    setNoteSaving(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNoteDraft('');
    await loadNotes();
    setProfile((p) => (p ? { ...p, notes_count: p.notes_count + 1 } : p));
  };

  const saveThreshold = useCallback(
    async (stageId: string) => {
      const raw = drafts[stageId];
      const parsed = Number(raw);
      if (raw === '' || Number.isNaN(parsed) || parsed < 0) {
        setSaveError('Threshold must be a non-negative number.');
        return;
      }
      setSavingStageId(stageId);
      setSaveError(null);
      const { error: rpcError } = await supabase.rpc('update_workflow_stage_threshold', {
        p_stage_id: stageId,
        p_threshold_amount: parsed,
      });
      if (rpcError) {
        setSaveError(friendlyPlatformError(rpcError.message));
        setSavingStageId(null);
        return;
      }
      setStages((prev) => prev.map((s) => (s.id === stageId ? { ...s, threshold_amount: parsed } : s)));
      setSavingStageId(null);
    },
    [drafts]
  );

  return {
    navigate,
    tab,
    setTab,
    blockedReason,
    profile,
    analytics,
    stages,
    loading,
    error,
    notice,
    setNotice,
    actionError,
    setActionError,
    editing,
    setEditing,
    draft,
    setDraft,
    savingProfile,
    dirty,
    saveProfile,
    statusDialog,
    setStatusDialog,
    readOnlyDialog,
    setReadOnlyDialog,
    reason,
    setReason,
    dialogSaving,
    confirmStatus,
    confirmReadOnly,
    impersonateOpen,
    setImpersonateOpen,
    notes,
    noteDraft,
    setNoteDraft,
    noteSaving,
    addNote,
    drafts,
    setDrafts,
    savingStageId,
    saveError,
    setSaveError,
    saveThreshold,
  };
}

export type CompanyDetailState = ReturnType<typeof useCompanyDetail>;