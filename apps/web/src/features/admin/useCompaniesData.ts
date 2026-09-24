import { useCallback, useState } from "react";
import { supabase } from "../../lib/supabaseClient";
import type { Tenant } from "./companiesList";

export interface CompanyAdminInvitation {
  id: string;
  tenant_id: string;
  email: string;
  status: "pending" | "accepted" | "expired" | "revoked";
  created_at: string;
}

export function useCompaniesData() {
  const [rows, setRows] = useState<Tenant[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [invitations, setInvitations] = useState<CompanyAdminInvitation[]>([]);
  const [loadingInvites, setLoadingInvites] = useState(true);
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionNotice, setActionNotice] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase.rpc("get_companies_overview");
    if (err) setError(err.message);
    else
      setRows(
        ((data ?? []) as any[]).map((r) => ({
          id: r.tenant_id,
          name: r.name,
          status: r.status,
          created_at: r.created_at,
          member_count: r.member_count,
          module_count: r.module_count,
          request_count_30d: r.request_count_30d,
          pending_request_count: r.pending_request_count,
          plan: r.plan,
          subscription_status: r.subscription_status,
          seat_limit: r.seat_limit,
          trial_ends_at: r.trial_ends_at,
          read_only: r.read_only,
          contact_email: r.contact_email,
          last_activity_at: r.last_activity_at,
        })) as Tenant[],
      );
    setLoading(false);
  }, []);

  const loadInvitations = useCallback(async () => {
    setLoadingInvites(true);
    const { data, error: err } = await supabase
      .from("invitations")
      .select("id, tenant_id, email, status, created_at")
      .eq("role_bundle", "company_admin")
      .order("created_at", { ascending: false });
    if (err) setActionError(err.message);
    else setInvitations((data ?? []) as CompanyAdminInvitation[]);
    setLoadingInvites(false);
  }, []);

  return {
    rows,
    loading,
    error,
    setError,
    invitations,
    loadingInvites,
    actionError,
    setActionError,
    actionNotice,
    setActionNotice,
    load,
    loadInvitations,
  };
}
