import { useCallback, useEffect, useMemo, useState } from 'react';
import { Box, CircularProgress, Tab, Tabs } from '@mui/material';
import { allRows, errorText, rows, table } from '../../db';
import { useMyModuleAccess } from '../../../../../features/navigation/useMyModuleAccess';
import { supabase } from '../../../../../lib/supabaseClient';
import { localIsoDate } from '../../fx';
import type { ApprovalAssignment, ParamDefinition, RegulatoryParameter } from '../../regulatory';
import { ErrorBanner, PageHeader } from '../../shared';
import ApproversPanel from './regulatory/ApproversPanel';
import ParametersPanel from './regulatory/ParametersPanel';

export interface PersonRow {
  id: string;
  name: string;
  email: string;
}

// Regulatory rules: the values that control remittance deadlines, levies, tax rates and
// approval limits. Nothing here is a constant in code. A value is proposed as a draft,
// then approved by someone who has been assigned to that responsibility (never by role,
// never by the person who proposed it). The server decides every rule; this screen only
// shows each person what they may do and reports the server's refusal in plain words.
export default function RegulatoryRules() {
  const access = useMyModuleAccess();
  const [userId, setUserId] = useState<string | null>(null);
  const [tenantId, setTenantId] = useState<string | null>(null);
  const [defs, setDefs] = useState<ParamDefinition[]>([]);
  const [params, setParams] = useState<RegulatoryParameter[]>([]);
  const [assignments, setAssignments] = useState<ApprovalAssignment[]>([]);
  const [people, setPeople] = useState<PersonRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<'parameters' | 'approvers'>('parameters');
  const today = localIsoDate();

  const isCompanyAdmin = Boolean(access?.isCompanyAdmin || access?.isPlatformAdmin);
  const insuranceRoles = access?.rolesByModule.get('insurance') ?? new Set<string>();
  // Draft rights on the server: company admin, finance (role 'finance') or the Insurance Admin.
  const canDraft = isCompanyAdmin || Boolean(access?.canAccessFinance) || insuranceRoles.has('admin');

  const load = useCallback(async () => {
    try {
      const [d, p, a, u] = await Promise.all([
        rows<ParamDefinition>(table('regulatory_parameter_definitions').select('*').order('category', { ascending: true }).order('key', { ascending: true })),
        allRows<RegulatoryParameter>(() => table('regulatory_parameters').select('*').order('created_at', { ascending: false }).order('id')),
        allRows<ApprovalAssignment>(() => table('regulatory_approval_assignments').select('*').order('assigned_at', { ascending: false }).order('id')),
        rows<PersonRow>(table('app_users').select('id, name, email').order('name', { ascending: true })),
      ]);
      setDefs(d);
      setParams(p);
      setAssignments(a);
      setPeople(u);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await supabase.auth.getUser();
      const uid = data.user?.id ?? null;
      if (cancelled) return;
      setUserId(uid);
      if (uid) {
        const { data: me } = await table('app_users').select('tenant_id').eq('id', uid).maybeSingle();
        if (!cancelled) setTenantId((me as { tenant_id: string } | null)?.tenant_id ?? null);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const defByKey = useMemo(() => new Map(defs.map((d) => [d.key, d])), [defs]);

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <PageHeader
        title="Regulatory rules"
        subtitle="Deadlines, levies, tax rates and approval limits. Values are proposed, then approved by an assigned approver. Nothing is built into the code."
      />
      <ErrorBanner message={error} />
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <>
          <Tabs value={tab} onChange={(_, v) => setTab(v)} sx={{ mb: 2 }}>
            <Tab value="parameters" label="Values" />
            <Tab value="approvers" label="Approvers" />
          </Tabs>
          {tab === 'parameters' ? (
            <ParametersPanel
              defs={defs}
              defByKey={defByKey}
              params={params}
              assignments={assignments}
              people={people}
              userId={userId}
              tenantId={tenantId}
              canDraft={canDraft}
              isCompanyAdmin={isCompanyAdmin}
              today={today}
              onChanged={load}
              onError={setError}
            />
          ) : (
            <ApproversPanel
              defs={defs}
              assignments={assignments}
              people={people}
              isCompanyAdmin={isCompanyAdmin}
              today={today}
              onChanged={load}
              onError={setError}
            />
          )}
        </>
      )}
    </Box>
  );
}
