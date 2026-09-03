import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabaseClient';
import { useSecuritySettings } from '../hooks/useSecuritySettings';
import { useIdleTimeout } from '../hooks/useIdleTimeout';

interface AuthContextValue {
  session: Session | null;
  loading: boolean;
  idleTimedOut: boolean;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [idleTimedOut, setIdleTimedOut] = useState(false);
  const { sessionTimeoutMinutes } = useSecuritySettings();
  // Guards against the interval firing again mid-signOut (signOut is
  // async; the 30s check could otherwise re-fire before the session
  // clears and set idleTimedOut twice / call signOut twice).
  const signingOutRef = useRef(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
      if (newSession) signingOutRef.current = false;
    });

    return () => {
      listener.subscription.unsubscribe();
    };
  }, []);

  const signOut = async () => {
    await supabase.auth.signOut();
  };

  useIdleTimeout(sessionTimeoutMinutes, Boolean(session) && !loading, () => {
    if (signingOutRef.current) return;
    signingOutRef.current = true;
    setIdleTimedOut(true);
    void signOut();
  });

  // Clear the banner flag once a fresh session exists again (new login).
  useEffect(() => {
    if (session) setIdleTimedOut(false);
  }, [session]);

  return (
    <AuthContext.Provider value={{ session, loading, idleTimedOut, signOut }}>{children}</AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within an AuthProvider');
  return ctx;
}