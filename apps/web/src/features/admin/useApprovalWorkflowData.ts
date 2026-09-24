import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "../../lib/supabaseClient";

export type AppliesTo = "requests" | "invoices";
export type ScopeType = "department" | "cost_center" | "global";

export interface Stage {
  id: string;
  name: string;
  sequence_order: number;
  approver_role: string;
  threshold_amount: number | null;
  next_stage_low_id: string | null;
  next_stage_high_id: string | null;
  requires_offer_entry: boolean;
  requires_offer_selection: boolean;
  blocks_offer_submitter_approval: boolean;
  is_finance_terminal_stage: boolean;
  is_active: boolean;
  applies_to: AppliesTo;
}

export interface Assignment {
  id: string;
  user_id: string;
  workflow_stage_id: string;
  scope_type: ScopeType;
  scope_id: string | null;
  threshold_max: number | null;
}

export interface TeamMember {
  user_id: string;
  name: string | null;
  email: string;
}

export interface LookupRow {
  id: string;
  name: string;
}

export function useApprovalWorkflowData() {
  const [stages, setStages] = useState<Stage[]>([]);
  const [assignments, setAssignments] = useState<Assignment[]>([]);
  const [members, setMembers] = useState<TeamMember[]>([]);
  const [departments, setDepartments] = useState<LookupRow[]>([]);
  const [costCenters, setCostCenters] = useState<LookupRow[]>([]);

  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError(null);

    const [stagesRes, assignmentsRes, membersRes, deptRes, costCenterRes] = await Promise.all([
      supabase
        .from("workflow_stages")
        .select(
          "id, name, sequence_order, approver_role, threshold_amount, next_stage_low_id, next_stage_high_id, requires_offer_entry, requires_offer_selection, blocks_offer_submitter_approval, is_finance_terminal_stage, is_active, applies_to",
        )
        .order("applies_to")
        .order("sequence_order"),
      supabase.from("approval_assignments").select("id, user_id, workflow_stage_id, scope_type, scope_id, threshold_max"),
      supabase.rpc("get_tenant_team_members"),
      supabase.from("departments").select("id, name").order("name"),
      supabase.from("cost_centers").select("id, name").order("name"),
    ]);

    if (stagesRes.error) setLoadError(stagesRes.error.message);
    else setStages((stagesRes.data ?? []) as Stage[]);

    if (!assignmentsRes.error) setAssignments((assignmentsRes.data ?? []) as Assignment[]);

    if (!membersRes.error) {
      setMembers(
        ((membersRes.data ?? []) as unknown as Array<{ user_id: string; name: string | null; email: string }>).map((m) => ({
          user_id: m.user_id,
          name: m.name,
          email: m.email,
        })),
      );
    }
    if (!deptRes.error) setDepartments((deptRes.data ?? []) as LookupRow[]);
    if (!costCenterRes.error) setCostCenters((costCenterRes.data ?? []) as LookupRow[]);

    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const stageNameById = useMemo(() => new Map(stages.map((s) => [s.id, s.name])), [stages]);
  const memberLabelById = useMemo(() => new Map(members.map((m) => [m.user_id, m.name?.trim() || m.email])), [members]);
  const deptNameById = useMemo(() => new Map(departments.map((d) => [d.id, d.name])), [departments]);
  const costCenterNameById = useMemo(() => new Map(costCenters.map((c) => [c.id, c.name])), [costCenters]);

  return {
    stages,
    assignments,
    members,
    departments,
    costCenters,
    loading,
    loadError,
    load,
    stageNameById,
    memberLabelById,
    deptNameById,
    costCenterNameById,
  };
}
