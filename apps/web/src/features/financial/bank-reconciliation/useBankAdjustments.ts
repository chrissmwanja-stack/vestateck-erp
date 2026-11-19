import { useCallback, useEffect, useState } from 'react';
import { db } from './db';
import type { AdjustmentEventRow, GlAccountOption, UnusualAccountRow, UsualAccountRow } from './types';

// Reads for the bank adjustment screens, one place per server RPC so the
// components stay presentational. Everything here goes through the untyped
// `db` handle because the D4e objects are not in the generated types yet.

export interface AdjustmentsData {
  glAccounts: GlAccountOption[];
  canSelfApprove: boolean;
  me: string | null;
  loading: boolean;
  error: string | null;
  reload: () => Promise<void>;
}

/** The GL account list, the one-person-exception setting and the caller. */
export function useAdjustmentLookups(): AdjustmentsData {
  const [glAccounts, setGlAccounts] = useState<GlAccountOption[]>([]);
  const [canSelfApprove, setCanSelfApprove] = useState(false);
  const [me, setMe] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [gl, selfApprove, user] = await Promise.all([
      db
        .from('gl_accounts')
        .select('id, account_code, name, is_header, is_control_account')
        .eq('is_active', true)
        .order('account_code'),
      db.rpc('bank_adjustment_can_self_approve'),
      db.auth.getUser(),
    ]);
    if (gl.error) {
      setError(gl.error.message ?? 'Could not load the chart of accounts.');
      setLoading(false);
      return;
    }
    setGlAccounts((gl.data ?? []) as GlAccountOption[]);
    // A failed permission read is "no", never "yes".
    setCanSelfApprove(!selfApprove.error && selfApprove.data === true);
    setMe(user.data?.user?.id ?? null);
    setLoading(false);
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  return { glAccounts, canSelfApprove, me, loading, error, reload };
}

/** The audit trail of one adjustment, newest read last. */
export function useAdjustmentHistory(adjustmentId: string | null) {
  const [events, setEvents] = useState<AdjustmentEventRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!adjustmentId) {
      setEvents([]);
      return;
    }
    setLoading(true);
    setError(null);
    const { data, error: err } = await db.rpc('bank_adjustment_history', { p_adjustment_id: adjustmentId });
    setLoading(false);
    if (err) {
      setError(err.message ?? 'Could not load the history of this adjustment.');
      return;
    }
    setEvents((data ?? []) as AdjustmentEventRow[]);
  }, [adjustmentId]);

  useEffect(() => {
    reload();
  }, [reload]);

  return { events, loading, error, reload };
}

/** Unusual account usage: posted adjustments outside the usual-accounts list. */
export function useUnusualAccounts(days: number | null) {
  const [rows, setRows] = useState<UnusualAccountRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await db.rpc('bank_adjustment_unusual_account_usage', { p_days: days });
    setLoading(false);
    if (err) {
      setError(err.message ?? 'Could not load unusual account usage.');
      return;
    }
    setRows((data ?? []) as UnusualAccountRow[]);
  }, [days]);

  useEffect(() => {
    reload();
  }, [reload]);

  return { rows, loading, error, reload };
}

/** The usual-accounts list the unusual-account report is measured against. */
export function useUsualAccounts() {
  const [rows, setRows] = useState<UsualAccountRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await db.rpc('bank_adjustment_list_usual_accounts');
    setLoading(false);
    if (err) {
      setError(err.message ?? 'Could not load the usual accounts.');
      return;
    }
    setRows((data ?? []) as UsualAccountRow[]);
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  return { rows, loading, error, reload };
}
