import { useEffect, useState } from 'react';
import { supabase } from '../../../lib/supabaseClient';

export function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc('is_finance_team_member', { p_role: 'finance' }).then(({ data, error }) =>
      setIsFinance(error ? false : Boolean(data))
    );
  }, []);
  return isFinance;
}
