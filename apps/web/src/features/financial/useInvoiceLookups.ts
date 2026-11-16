import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "../../lib/supabaseClient";
import type { CostCenter } from "@erp-platform/shared";

export interface AccountOption {
  id: string;
  account_code: string;
  name: string;
  category_id: string | null;
}

export interface OrganizationOption {
  id: string;
  company_code: string;
  site_name: string;
}

export interface AccountCategoryOption {
  id: string;
  code: string;
  name: string;
}

export type Source = "supplier" | "receivable";

const messageOf = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

export function useInvoiceLookups(onError: (message: string) => void) {
  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(false);

  const [organizations, setOrganizations] = useState<OrganizationOption[]>([]);
  const [loadingOrganizations, setLoadingOrganizations] = useState(false);

  const [accountCategories, setAccountCategories] = useState<AccountCategoryOption[]>([]);
  const [searchAccounts, setSearchAccounts] = useState<AccountOption[]>([]);
  const [loadingSearchAccounts, setLoadingSearchAccounts] = useState(false);

  const [accounts, setAccounts] = useState<AccountOption[]>([]);
  const [loadingAccounts, setLoadingAccounts] = useState(false);

  const loadCostCenters = useCallback(async () => {
    setLoadingCostCenters(true);
    try {
      const { data, error } = await supabase.from("cost_centers").select("id, tenant_id, name, project_code, budget_amount, created_at").order("name");
      if (error) throw error;
      setCostCenters(data ?? []);
    } catch (e) {
      onError(messageOf(e, 'Failed to load cost centers'));
    } finally {
      setLoadingCostCenters(false);
    }
  }, [onError]);

  const loadOrganizations = useCallback(async () => {
    setLoadingOrganizations(true);
    try {
      const { data, error } = await supabase.from("organizations").select("id, company_code, site_name").eq("is_active", true).order("company_code").order("site_name");
      if (error) throw error;
      setOrganizations(data ?? []);
    } catch (e) {
      onError(messageOf(e, 'Failed to load organizations'));
    } finally {
      setLoadingOrganizations(false);
    }
  }, [onError]);

  const loadAccountCategories = useCallback(async () => {
    try {
      const { data, error } = await supabase.from("account_categories").select("id, code, name").eq("is_active", true).order("name");
      if (error) throw error;
      setAccountCategories(data ?? []);
    } catch (e) {
      onError(messageOf(e, 'Failed to load account categories'));
    }
  }, [onError]);

  const loadSearchAccounts = useCallback(async () => {
    setLoadingSearchAccounts(true);
    try {
      const { data, error } = await supabase.from("accounts").select("id, account_code, name, category_id").eq("is_active", true).order("name");
      if (error) throw error;
      setSearchAccounts(data ?? []);
    } catch (e) {
      onError(messageOf(e, 'Failed to load accounts'));
    } finally {
      setLoadingSearchAccounts(false);
    }
  }, [onError]);

  const loadAccountsFor = useCallback(async (source: Source) => {
    setLoadingAccounts(true);
    try {
      const wantedType = source === "supplier" ? "vendor" : "client";
      const { data, error } = await supabase
        .from("accounts")
        .select("id, account_code, name, category_id")
        .eq("is_active", true)
        .in("account_type", [wantedType, "both"])
        .order("name");
      if (error) throw error;
      setAccounts(data ?? []);
    } catch (e) {
      onError(messageOf(e, 'Failed to load accounts'));
    } finally {
      setLoadingAccounts(false);
    }
  }, [onError]);

  useEffect(() => {
    loadCostCenters();
    loadOrganizations();
    loadAccountCategories();
    loadSearchAccounts();
  }, [loadCostCenters, loadOrganizations, loadAccountCategories, loadSearchAccounts]);

  const costCenterOptions = useMemo(() => costCenters.map((cc) => ({ id: cc.id, label: `${cc.project_code} — ${cc.name}` })), [costCenters]);
  const organizationOptions = useMemo(
    () => organizations.map((o) => ({ id: o.id, label: `${o.company_code} — ${o.site_name}` })),
    [organizations],
  );
  const accountCategoryOptions = useMemo(() => accountCategories.map((c) => ({ id: c.id, label: c.name })), [accountCategories]);

  return {
    costCenters,
    organizations,
    accountCategories,
    searchAccounts,
    accounts,
    loadingCostCenters,
    loadingOrganizations,
    loadingSearchAccounts,
    loadingAccounts,
    costCenterOptions,
    organizationOptions,
    accountCategoryOptions,
    loadAccountsFor,
  };
}
