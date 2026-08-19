import { useEffect, useState, SyntheticEvent } from 'react';
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
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';
import type { Json } from '@erp-platform/shared';

// Mirrors the jsonb shapes documented in the platform_settings migration.
interface BrandingSettings {
  platform_name: string;
  logo_url: string;
  primary_color: string;
}

interface NotificationSettings {
  alert_recipients: string[];
  pending_company_threshold_days: number;
}

interface SecuritySettings {
  session_timeout_minutes: number;
  require_mfa: boolean;
}

const DEFAULT_BRANDING: BrandingSettings = { platform_name: 'VestaPortal', logo_url: '', primary_color: '#1B5560' };
const DEFAULT_NOTIFICATIONS: NotificationSettings = { alert_recipients: [], pending_company_threshold_days: 2 };
const DEFAULT_SECURITY: SecuritySettings = { session_timeout_minutes: 60, require_mfa: false };

// No AdminLayout header duplicated here -- the shared shell (see
// AdminLayout.tsx) already supplies the title + back nav for every
// /admin/* subpage, this component is just the tab content.
export default function AdminSettingsPage() {
  const [tab, setTab] = useState(0);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saveMessage, setSaveMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [branding, setBranding] = useState<BrandingSettings>(DEFAULT_BRANDING);
  const [notifications, setNotifications] = useState<NotificationSettings>(DEFAULT_NOTIFICATIONS);
  const [security, setSecurity] = useState<SecuritySettings>(DEFAULT_SECURITY);
  const [recipientInput, setRecipientInput] = useState('');

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

  const handleSave = async () => {
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
    }
    setSaving(false);
  };

  const addRecipient = () => {
    const email = recipientInput.trim();
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
            <Stack spacing={3} maxWidth={480}>
              <TextField
                label="Platform name"
                value={branding.platform_name}
                onChange={(e) => setBranding((p) => ({ ...p, platform_name: e.target.value }))}
                fullWidth
              />
              <TextField
                label="Logo URL"
                value={branding.logo_url}
                onChange={(e) => setBranding((p) => ({ ...p, logo_url: e.target.value }))}
                fullWidth
              />
              <TextField
                label="Primary color"
                type="color"
                value={branding.primary_color}
                onChange={(e) => setBranding((p) => ({ ...p, primary_color: e.target.value }))}
                sx={{ width: 160 }}
              />
            </Stack>
          )}

          {tab === 1 && (
            <Stack spacing={3} maxWidth={480}>
              <Box>
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
                  setNotifications((p) => ({ ...p, pending_company_threshold_days: Number(e.target.value) }))
                }
                sx={{ width: 260 }}
              />
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
                label="Require MFA for platform admins"
              />
            </Stack>
          )}
        </Box>
      </Paper>
    </Box>
  );
}
