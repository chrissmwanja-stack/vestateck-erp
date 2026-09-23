import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { supabase } from './supabaseClient';
import { setPdfBranding } from './pdfBranding';

// Operator branding (item 6). Read through get_platform_branding() -- a
// SECURITY DEFINER RPC open to anon -- because platform_settings itself is
// platform-admin-only and the login page renders before any session
// exists. Defaults here MUST match the SQL defaults so an offline / failed
// fetch renders the same thing the server would.

export interface Branding {
  platformName: string;
  logoUrl: string;
  primaryColor: string;
  supportEmail: string;
  tagline: string;
}

export const DEFAULT_BRANDING: Branding = {
  platformName: 'VestaPortal',
  logoUrl: '',
  primaryColor: '#1B5560',
  supportEmail: '',
  tagline: 'Multi-department ERP',
};

interface BrandingContextValue extends Branding {
  loading: boolean;
  // Re-fetch after the Settings page saves so the operator sees the change
  // without a reload.
  refresh: () => Promise<void>;
}

const BrandingContext = createContext<BrandingContextValue | undefined>(undefined);

const STORAGE_KEY = 'vestaportal.branding';

function readCached(): Branding | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<Branding>;
    return normaliseBranding(parsed);
  } catch {
    return null;
  }
}

// Same validation as the SQL side, applied again on the client so a stale
// cache or a hand-edited localStorage entry cannot inject markup or a
// bogus colour into styles.
export function normaliseBranding(input: Partial<Branding> | null | undefined): Branding {
  const name = (input?.platformName ?? '').trim();
  const logo = (input?.logoUrl ?? '').trim();
  const color = (input?.primaryColor ?? '').trim();
  const email = (input?.supportEmail ?? '').trim();
  const tagline = (input?.tagline ?? '').trim();
  return {
    platformName: name || DEFAULT_BRANDING.platformName,
    logoUrl: /^https?:\/\//i.test(logo) ? logo : '',
    primaryColor: /^#[0-9a-f]{6}$/i.test(color) ? color.toUpperCase() : DEFAULT_BRANDING.primaryColor,
    supportEmail: /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? email.toLowerCase() : '',
    tagline: tagline || DEFAULT_BRANDING.tagline,
  };
}

interface BrandingRow {
  platform_name: string;
  logo_url: string;
  primary_color: string;
  support_email: string;
  tagline: string;
}

export function rowToBranding(row: BrandingRow | null | undefined): Branding {
  return normaliseBranding({
    platformName: row?.platform_name,
    logoUrl: row?.logo_url,
    primaryColor: row?.primary_color,
    supportEmail: row?.support_email,
    tagline: row?.tagline,
  });
}

export async function fetchBranding(): Promise<Branding | null> {
  const { data, error } = await supabase.rpc('get_platform_branding').single();
  if (error || !data) return null;
  return rowToBranding(data as BrandingRow);
}

export function BrandingProvider({ children }: { children: ReactNode }) {
  const cached = useMemo(readCached, []);
  const [branding, setBranding] = useState<Branding>(cached ?? DEFAULT_BRANDING);
  const [loading, setLoading] = useState(!cached);

  const refresh = useCallback(async () => {
    const next = await fetchBranding();
    if (next) {
      setBranding(next);
      try {
        window.localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      } catch {
        /* storage unavailable: fine, we still have state */
      }
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    if (typeof document !== 'undefined') document.title = branding.platformName;
    setPdfBranding({ platformName: branding.platformName, primaryColor: branding.primaryColor, supportEmail: branding.supportEmail });
  }, [branding.platformName, branding.primaryColor, branding.supportEmail]);

  const value = useMemo(() => ({ ...branding, loading, refresh }), [branding, loading, refresh]);
  return <BrandingContext.Provider value={value}>{children}</BrandingContext.Provider>;
}

export function useBranding(): BrandingContextValue {
  const ctx = useContext(BrandingContext);
  // Tests and isolated renders may not wrap in the provider; fall back to
  // defaults rather than throwing so brand text never blocks a screen.
  if (!ctx) return { ...DEFAULT_BRANDING, loading: false, refresh: async () => {} };
  return ctx;
}
