import { useEffect, useState, SyntheticEvent } from 'react';
import { useSearchParams } from 'react-router-dom';
import {
  Box,
  Tab,
  Tabs,
  Paper,
  TextField,
  Switch,
  FormControlLabel,
  Stack,
  Button,
  Chip,
  Alert,
  Skeleton,
  Typography,
  Divider,
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';
import type { Json } from '@erp-platform/shared';
import { useBranding, normaliseBranding } from '../../lib/brandingContext';
import { contrastTextFor, rampFor } from '../../theme/theme';
import OperatorDigestPanel from './OperatorDigestPanel';
import { describeBlockedReason, usePlatformAdminSession } from './usePlatformAdminSession';

// Mirrors the jsonb shapes documented in the platform_settings migration.
// As of 20260922240000 every one of these is consumed somewhere:
//   branding       -> get_platform_branding(): login, top bar, PDFs, email
//   notifications  -> operator digest (recipients, threshold, on/off)
//   security       -> get_security_settings(): idle timeout, MFA gate
export interface BrandingSettings {
  platform_name: string;
  logo_url: string;
  primary_color: string;
  support_email: string;
  tagline: string;
}

interface NotificationSettings {
  alert_recipients: string[];
  pending_company_threshold_days: number;
  digest_enabled: boolean;
}

interface SecuritySettings {
  session_timeout_minutes: number;
  require_mfa: boolean;
}

const DEFAULT_BRANDING: BrandingSettings = {
  platform_name: 'VestaPortal',
  logo_url: '',
  primary_color: '#1B5560',
  support_email: '',
  tagline: 'Multi-department ERP',
};
const DEFAULT_NOTIFICATIONS: NotificationSettings = { alert_recipients: [], pending_company_threshold_days: 2, digest_enabled: true };
const DEFAULT_SECURITY: SecuritySettings = { session_timeout_minutes: 60, require_mfa: false };

// What the server will accept / what the preview shows. Same rules as
// get_platform_branding(): blank name -> default, colour must be #RRGGBB,
// logo must be http(s), support email must look like an email.
export function brandingProblems(b: BrandingSettings): string[] {
  const problems: string[] = [];
  if (b.primary_color && !/^#[0-9a-f]{6}$/i.test(b.primary_color)) problems.push('Primary colour must be a 6-digit hex value like #1B5560.');
  if (b.logo_url && !/^https?:\/\//i.test(b.logo_url)) problems.push('Logo URL must start with http:// or https://.');
  if (b.support_email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(b.support_email)) problems.push('Support email does not look like an email address.');
  return problems;
}

function BrandPreview({ b }: { b: BrandingSettings }) {
  const n = normaliseBranding({
    platformName: b.platform_name,
    logoUrl: b.logo_url,
    primaryColor: b.primary_color,
    supportEmail: b.support_email,
    tagline: b.tagline,
  });
  const ramp = rampFor(n.primaryColor);
  const text = contrastTextFor(ramp[700]);
  return (
    <Box data-testid="brand-preview">
      <Typography variant="caption" color="text.secondary">
        Preview
      </Typography>
      <Box sx={{ mt: 0.5, borderRadius: 2, overflow: 'hidden', border: 1, borderColor: 'divider' }}>
        <Box sx={{ bgcolor: ramp[700], color: text, px: 2, py: 1, display: 'flex', alignItems: 'center', gap: 1.25 }}>
          {n.logoUrl && <Box component="img" src={n.logoUrl} alt="" sx={{ height: 24, maxWidth: 120, objectFit: 'contain' }} />}
          <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
            {n.platformName}
          </Typography>
        </Box>
        <Box sx={{ p: 2, background: `linear-gradient(155deg, ${ramp[900]} 0%, ${ramp[700]} 62%, ${ramp[500]} 100%)`, color: '#fff' }}>
          <Typography variant="overline" sx={{ opacity: 0.7, letterSpacing: 2 }}>
            {n.tagline}
          </Typography>
          <Typography variant="h6" sx={{ fontWeight: 800 }}>
            {n.platformName}
          </Typography>
          <Typography variant="caption" sx={{ opacity: 0.8 }}>
            Sign in to your {n.platformName} workspace.{n.supportEmail ? ` Help: ${n.supportEmail}` : ''}
          </Typography>
        </Box>
      </Box>
    </Box>
  );
}

// No AdminLayout header duplicated here -- the shared shell (see
// AdminLayout.tsx) already supplies the title + back nav for every
// /admin/* subpage, this component is just the tab content.
const TAB_KEYS = ['branding', 'notifications', 'security'] as const;

export default function AdminSettingsPage() {
  const [searchParams, setSearchParams] = useSearchParams();
  const initialTab = Math.max(0, TAB_KEYS.indexOf((searchParams.get('tab') ?? '') as (typeof TAB_KEYS)[number]));
  const [tab, setTabState] = useState(initialTab);
  const setTab = (next: number) => {
    setTabState(next);
    const p = new URLSearchParams(searchParams);
    if (next === 0) p.delete('tab');
    else p.set('tab', TAB_KEYS[next]);
    setSearchParams(p, { replace: true });
  };
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saveMessage, setSaveMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [branding, setBranding] = useState<BrandingSettings>(DEFAULT_BRANDING);
  const [notifications, setNotifications] = useState<NotificationSettings>(DEFAULT_NOTIFICATIONS);
  const [security, setSecurity] = useState<SecuritySettings>(DEFAULT_SECURITY);
  const [recipientInput, setRecipientInput] = useState('');

  const liveBrand = useBranding();
  const { session: adminSession } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(adminSession);

  useEffect(() => {
    (async () => {
      setLoading(true);
      const { data, error: fetchError } = await supabase
        .from('platform_settings')
        .select('branding, notifications, security')
        .single();

      if (fetchError) {
        setError(fetchError.message);
      } else if (data) {
        setBranding({ ...DEFAULT_BRANDING, ...(data.branding as Partial<BrandingSettings>) });
        setNotifications({ ...DEFAULT_NOTIFICATIONS, ...(data.notifications as Partial<NotificationSettings>) });
        setSecurity({ ...DEFAULT_SECURITY, ...(data.security as Partial<SecuritySettings>) });
      }
      setLoading(false);
    })();
  }, []);

  const handleTabChange = (_: SyntheticEvent, value: number) => setTab(value);

  const problems = brandingProblems(branding);

  const handleSave = async () => {
    if (problems.length) {
      setError(problems.join(' '));
      setTab(0);
      return;
    }
    setSaving(true);
    setSaveMessage(null);
    setError(null);

    const { error: updateError } = await supabase
      .from('platform_settings')
      .update({
        branding: branding as unknown as Json,
        notifications: notifications as unknown as Json,
        security: security as unknown as Json,
        updated_at: new Date().toISOString(),
      })
      .eq('id', true);

    if (updateError) {
      setError(updateError.message);
    } else {
      setSaveMessage('Settings saved.');
      // Pull the new branding into the running app (top bar, theme, PDFs).
      void liveBrand.refresh();
    }
    setSaving(false);
  };

  const addRecipient = () => {
    const email = recipientInput.trim().toLowerCase();
    if (email && !notifications.alert_recipients.includes(email)) {
      setNotifications((prev) => ({ ...prev, alert_recipients: [...prev.alert_recipients, email] }));
    }
    setRecipientInput('');
  };

  const removeRecipient = (email: string) => {
    setNotifications((prev) => ({
      ...prev,
      alert_recipients: prev.alert_recipients.filter((r) => r !== email),
    }));
  };

  if (loading) {
    return <Skeleton variant="rounded" height={300} />;
  }

  return (
    <Box>
      <Stack direction="row" justifyContent="flex-end" sx={{ mb: 2 }}>
        <Button variant="contained" onClick={handleSave} disabled={saving}>
          {saving ? 'Saving…' : 'Save changes'}
        </Button>
      </Stack>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {saveMessage && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setSaveMessage(null)}>
          {saveMessage}
        </Alert>
      )}

      <Paper variant="outlined">
        <Tabs value={tab} onChange={handleTabChange} sx={{ borderBottom: 1, borderColor: 'divider' }}>
          <Tab label="Branding" />
          <Tab label="Notifications" />
          <Tab label="Security & Access" />
        </Tabs>

        <Box sx={{ p: 3 }}>
          {tab === 0 && (
            <Stack direction={{ xs: 'column', md: 'row' }} spacing={4}>
              <Stack spacing={3} sx={{ flex: '0 0 auto', width: { xs: '100%', md: 480 } }}>
                <Alert severity="info" variant="outlined">
                  Shown to <strong>every company</strong> on the login page, the top bar, generated PDFs and emails. Company-specific
                  branding is not a thing yet — this is your brand as the operator.
                </Alert>
                <TextField
                  label="Platform name"
                  value={branding.platform_name}
                  onChange={(e) => setBranding((p) => ({ ...p, platform_name: e.target.value }))}
                  fullWidth
                />
                <TextField
                  label="Tagline"
                  value={branding.tagline}
                  onChange={(e) => setBranding((p) => ({ ...p, tagline: e.target.value }))}
                  helperText="Small line above the name on the login page."
                  fullWidth
                />
                <TextField
                  label="Logo URL"
                  value={branding.logo_url}
                  onChange={(e) => setBranding((p) => ({ ...p, logo_url: e.target.value }))}
                  helperText="https:// link to a PNG/SVG with a transparent background; shown at ~28px high."
                  error={!!branding.logo_url && !/^https?:\/\//i.test(branding.logo_url)}
                  fullWidth
                />
                <Stack direction="row" spacing={2} alignItems="flex-start">
                  <TextField
                    label="Primary colour"
                    type="color"
                    value={/^#[0-9a-f]{6}$/i.test(branding.primary_color) ? branding.primary_color : '#1B5560'}
                    onChange={(e) => setBranding((p) => ({ ...p, primary_color: e.target.value.toUpperCase() }))}
                    sx={{ width: 120 }}
                  />
                  <TextField
                    label="Hex"
                    value={branding.primary_color}
                    onChange={(e) => setBranding((p) => ({ ...p, primary_color: e.target.value }))}
                    error={!!branding.primary_color && !/^#[0-9a-f]{6}$/i.test(branding.primary_color)}
                    sx={{ width: 140 }}
                  />
                  <Button size="small" onClick={() => setBranding((p) => ({ ...p, primary_color: DEFAULT_BRANDING.primary_color }))} sx={{ mt: 1 }}>
                    Reset colour
                  </Button>
                </Stack>
                <TextField
                  label="Support email"
                  value={branding.support_email}
                  onChange={(e) => setBranding((p) => ({ ...p, support_email: e.target.value }))}
                  helperText="Shown on suspended/blocked screens and in the footer of generated PDFs and emails."
                  error={!!branding.support_email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(branding.support_email)}
                  fullWidth
                />
                {problems.length > 0 && (
                  <Alert severity="warning" data-testid="branding-problems">
                    {problems.join(' ')}
                  </Alert>
                )}
              </Stack>
              <Box sx={{ flex: 1, minWidth: 0 }}>
                <BrandPreview b={branding} />
              </Box>
            </Stack>
          )}

          {tab === 1 && (
            <Stack spacing={3}>
              <Stack spacing={3} maxWidth={560}>
                <Box>
                  <Typography variant="subtitle2" gutterBottom>
                    Alert recipients
                  </Typography>
                  <Typography variant="caption" color="text.secondary" display="block" sx={{ mb: 1 }}>
                    Email addresses that receive the daily operator digest. Leave empty to keep it in-app only.
                  </Typography>
                  <TextField
                    label="Add alert recipient email"
                    value={recipientInput}
                    onChange={(e) => setRecipientInput(e.target.value)}
                    onKeyDown={(e) => e.key === 'Enter' && addRecipient()}
                    fullWidth
                  />
                  <Stack direction="row" spacing={1} flexWrap="wrap" sx={{ mt: 1.5 }}>
                    {notifications.alert_recipients.map((email) => (
                      <Chip key={email} label={email} onDelete={() => removeRecipient(email)} sx={{ mb: 1 }} />
                    ))}
                  </Stack>
                </Box>
                <TextField
                  label="Flag pending companies after (days)"
                  type="number"
                  value={notifications.pending_company_threshold_days}
                  onChange={(e) =>
                    setNotifications((p) => ({ ...p, pending_company_threshold_days: Math.max(0, Number(e.target.value) || 0) }))
                  }
                  helperText="Companies still 'pending' after this many days are listed in the digest."
                  sx={{ width: 300 }}
                />
                <FormControlLabel
                  control={
                    <Switch
                      checked={notifications.digest_enabled}
                      onChange={(e) => setNotifications((p) => ({ ...p, digest_enabled: e.target.checked }))}
                    />
                  }
                  label="Send the daily operator digest"
                />
              </Stack>
              <Divider />
              <OperatorDigestPanel canAct={!blockedReason} blockedReason={blockedReason} />
            </Stack>
          )}

          {tab === 2 && (
            <Stack spacing={3} maxWidth={480}>
              <TextField
                label="Session timeout (minutes)"
                type="number"
                value={security.session_timeout_minutes}
                onChange={(e) =>
                  setSecurity((p) => ({ ...p, session_timeout_minutes: Number(e.target.value) }))
                }
                sx={{ width: 260 }}
              />
              <FormControlLabel
                control={
                  <Switch
                    checked={security.require_mfa}
                    onChange={(e) => setSecurity((p) => ({ ...p, require_mfa: e.target.checked }))}
                  />
                }
                label="Require MFA for every user on the platform (all companies)"
              />
              <Alert severity="info">
                Platform admins are handled separately: once a platform admin has enrolled an
                authenticator, privileged actions (suspend, modules, impersonation, thresholds)
                require a session verified with that authenticator regardless of this switch.
                Every such action is recorded in the <strong>Audit log</strong>.
              </Alert>
            </Stack>
          )}
        </Box>
      </Paper>
    </Box>
  );
}
