import { createClient } from '@supabase/supabase-js';
import type { Database } from '@erp-platform/shared';

const supabaseUrl = (import.meta.env.VITE_SUPABASE_URL as string) || 'https://placeholder.supabase.co';
const supabaseAnonKey = (import.meta.env.VITE_SUPABASE_ANON_KEY as string) || 'placeholder-anon-key';

if (!import.meta.env.VITE_SUPABASE_URL || !import.meta.env.VITE_SUPABASE_ANON_KEY) {
  // eslint-disable-next-line no-console
  console.warn(
    'Supabase env vars are not set — using placeholder values so the app can still render. ' +
      'Copy .env.example to .env and fill in real values once a Supabase project exists. ' +
      'Any data calls will fail until then.'
  );
}

export const supabase = createClient<Database>(supabaseUrl, supabaseAnonKey);