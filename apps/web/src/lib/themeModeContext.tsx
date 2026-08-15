import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { PaletteMode } from '@mui/material';

type ThemeModePreference = 'light' | 'dark' | 'system';

interface ThemeModeContextValue {
  // The user's stored preference (may be 'system').
  preference: ThemeModePreference;
  // The actual light/dark mode to render, with 'system' already resolved.
  resolvedMode: PaletteMode;
  setPreference: (preference: ThemeModePreference) => void;
  toggle: () => void;
}

const STORAGE_KEY = 'vestaportal.theme-mode';

const ThemeModeContext = createContext<ThemeModeContextValue | undefined>(undefined);

function readStoredPreference(): ThemeModePreference {
  if (typeof window === 'undefined') return 'system';
  const stored = window.localStorage.getItem(STORAGE_KEY);
  return stored === 'light' || stored === 'dark' || stored === 'system' ? stored : 'system';
}

function prefersDark(): boolean {
  if (typeof window === 'undefined' || !window.matchMedia) return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

export function ThemeModeProvider({ children }: { children: ReactNode }) {
  const [preference, setPreferenceState] = useState<ThemeModePreference>(readStoredPreference);
  const [systemPrefersDark, setSystemPrefersDark] = useState(prefersDark);

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const listener = (event: MediaQueryListEvent) => setSystemPrefersDark(event.matches);
    media.addEventListener('change', listener);
    return () => media.removeEventListener('change', listener);
  }, []);

  const setPreference = (next: ThemeModePreference) => {
    setPreferenceState(next);
    window.localStorage.setItem(STORAGE_KEY, next);
  };

  // Cycles light -> dark -> light. Deliberately skips 'system' on toggle so
  // the button always does something visible; "match my OS" stays available
  // as an explicit choice wherever settings are surfaced later.
  const toggle = () => {
    const current = preference === 'system' ? (systemPrefersDark ? 'dark' : 'light') : preference;
    setPreference(current === 'dark' ? 'light' : 'dark');
  };

  const resolvedMode: PaletteMode = useMemo(() => {
    if (preference === 'system') return systemPrefersDark ? 'dark' : 'light';
    return preference;
  }, [preference, systemPrefersDark]);

  const value = useMemo(
    () => ({ preference, resolvedMode, setPreference, toggle }),
    [preference, resolvedMode],
  );

  return <ThemeModeContext.Provider value={value}>{children}</ThemeModeContext.Provider>;
}

export function useThemeMode() {
  const ctx = useContext(ThemeModeContext);
  if (!ctx) throw new Error('useThemeMode must be used within a ThemeModeProvider');
  return ctx;
}