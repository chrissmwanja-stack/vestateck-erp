import { useCallback, useEffect, useState } from 'react';
import { Alert, AlertTitle, Button, Collapse, Link, Stack } from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

// App-wide banner for platform announcements (20260923090000). Mounted
// next to ImpersonationBanner in App.tsx so every signed-in user sees the
// operator's notices -- platform-wide or aimed at their company -- in one
// predictable place.
//
// get_active_announcements() already applies the window, the targeting
// and this user's dismissals server-side; the component just renders what
// comes back. Critical notices come back non-dismissible; anything else
// can be dismissed per user (persisted, so it stays gone across devices).
// Polled every 5 minutes so a newly published notice reaches open tabs
// without a reload, which is the whole point of a maintenance warning.

export interface ActiveAnnouncement {
  id: string;
  title: string;
  body: string;
  severity: string;
  starts_at: string;
  ends_at: string | null;
  dismissible: boolean;
  link_url: string | null;
  link_label: string | null;
  is_global: boolean;
}

const POLL_MS = 5 * 60_000;

function severityOf(s: string): 'info' | 'warning' | 'error' {
  return s === 'critical' ? 'error' : s === 'warning' ? 'warning' : 'info';
}

export default function AnnouncementBanner() {
  const [items, setItems] = useState<ActiveAnnouncement[]>([]);
  const [hidden, setHidden] = useState<Set<string>>(new Set()); // optimistic

  const refresh = useCallback(async () => {
    const { data, error } = await supabase.rpc('get_active_announcements');
    if (error) return; // silent: a banner must never break the app
    setItems((data ?? []) as ActiveAnnouncement[]);
  }, []);

  useEffect(() => {
    void refresh();
    const id = window.setInterval(() => void refresh(), POLL_MS);
    return () => window.clearInterval(id);
  }, [refresh]);

  const dismiss = async (id: string) => {
    setHidden((prev) => new Set(prev).add(id));
    const { error } = await supabase.rpc('dismiss_announcement', { p_id: id });
    if (error) {
      setHidden((prev) => {
        const n = new Set(prev);
        n.delete(id);
        return n;
      });
    }
  };

  const visible = items.filter((a) => !hidden.has(a.id));
  if (visible.length === 0) return null;

  return (
    <Stack spacing={0} data-testid="announcement-banner">
      {visible.map((a) => (
        <Collapse key={a.id} in appear>
          <Alert
            severity={severityOf(a.severity)}
            variant="filled"
            square
            onClose={a.dismissible ? () => void dismiss(a.id) : undefined}
            action={
              a.link_url ? (
                <Stack direction="row" spacing={1} alignItems="center">
                  <Button
                    color="inherit"
                    size="small"
                    component={Link}
                    href={a.link_url}
                    target={a.link_url.startsWith('/') ? undefined : '_blank'}
                    rel="noopener"
                  >
                    {a.link_label || 'More'}
                  </Button>
                  {a.dismissible && (
                    <Button color="inherit" size="small" onClick={() => void dismiss(a.id)}>
                      Dismiss
                    </Button>
                  )}
                </Stack>
              ) : undefined
            }
            sx={{ borderRadius: 0, py: 0.25, alignItems: 'center' }}
          >
            <AlertTitle sx={{ mb: 0, fontWeight: 700, fontSize: '0.9rem' }}>
              {a.title}
              {!a.is_global && (
                <span style={{ fontWeight: 400, opacity: 0.85 }}> · for your company</span>
              )}
            </AlertTitle>
            <span style={{ fontSize: '0.85rem' }}>{a.body}</span>
          </Alert>
        </Collapse>
      ))}
    </Stack>
  );
}
