import type { SupabaseClient } from '@supabase/supabase-js';
import { supabase } from '../../../lib/supabaseClient';

// The D4d-1 objects (settlement matching, double-entry view, position
// function, fin_bank_accounts) are not in the generated database.types.ts
// yet, so calls that touch them go through this untyped handle. Once the
// types are regenerated these can move back to `supabase`.
export const db = supabase as unknown as SupabaseClient;
