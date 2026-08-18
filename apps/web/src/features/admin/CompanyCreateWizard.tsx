import { useCallback, useEffect, useState } from 'react';
import {
  Box,
  Button,
  Checkbox,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  FormGroup,
  MenuItem,
  Step,
  StepLabel,
  Stepper,
  Stack,
  TextField,
  Typography,
  Alert,
  Divider,
} from '@mui/material';
import { CheckCircle, Business } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

type IndustryTemplate = 'general' | 'construction';

interface WizardProps {
  open: boolean;
  onClose: () => void;
  onCreated: () => void;
}

const INDUSTRY_TEMPLATES: { value: IndustryTemplate; label: string; description: string }[] = [
  {
    value: 'general',
    label: 'General',
    description: '8 departments: IT, Finance, Procurement & Logistics, HR, Law & Compliance, BD, PMO, Admin.',
  },
  {
    value: 'construction',
    label: 'Construction',
    description: 'General + Machine Operations and Sustainability & Business Excellence (10 departments).',
  },
];

const MODULE_OPTIONS: { value: string; label: string; hint: string }[] = [
  { value: 'hr', label: 'HR', hint: 'Employees, leave, payroll, recruitment' },
  { value: 'legal', label: 'Law & Compliance', hint: 'Contracts, cases, compliance register' },
  { value: 'bd', label: 'Business Development', hint: 'Leads, opportunities, proposals, tenders' },
  { value: 'it', label: 'IT Support', hint: 'Tickets, assets, KB, SLAs' },
  { value: 'pmo', label: 'PMO', hint: 'Projects, tasks, Gantt, resources' },
  { value: 'procurement', label: 'Purchasing Extras', hint: 'Advanced procurement (core procurement is always on)' },
  { value: 'machine_operation', label: 'Machine Operation', hint: 'Equipment, maintenance, fuel logs' },
  { value: 'sustainability', label: 'Sustainability', hint: 'Carbon, energy, waste, initiatives' },
];

const APPROVAL_PIPELINE = [
  'Cost Control Engineer',
  'Cost Control Manager',
  'Procurement: Offer Entry',
  'Control Chief/Manager (splits by amount)',
  'Finance (if under 5M) or PM → Deputy GM → Finance (if over)',
];

export default function CompanyCreateWizard({ open, onClose, onCreated }: WizardProps) {
  const [step, setStep] = useState(0);
  const [name, setName] = useState('');
  const [adminEmail, setAdminEmail] = useState('');
  const [template, setTemplate] = useState<IndustryTemplate>('general');
  const [modules, setModules] = useState<Set<string>>(new Set(['hr', 'legal', 'bd', 'it', 'pmo', 'procurement']));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [successId, setSuccessId] = useState<string | null>(null);
  const [seedWarning, setSeedWarning] = useState<string | null>(null);

  const reset = useCallback(() => {
    setStep(0);
    setName('');
    setAdminEmail('');
    setTemplate('general');
    setModules(new Set(['hr', 'legal', 'bd', 'it', 'pmo', 'procurement']));
    setError(null);
    setSeedWarning(null);
    setSuccessId(null);
  }, []);

  useEffect(() => {
    if (!open) reset();
  }, [open, reset]);

  const toggle = (v: string) => {
    setModules((prev) => {
      const n = new Set(prev);
      if (n.has(v)) n.delete(v);
      else n.add(v);
      return n;
    });
  };

  const canNext = name.trim().length > 1 && adminEmail.trim().includes('@');
  const isValidEmail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.trim());

  const handleCreate = async () => {
    if (!name.trim() || !isValidEmail(adminEmail)) {
      setError('Company name and a valid admin email are required.');
      return;
    }
    setSaving(true);
    setError(null);
    setSeedWarning(null);

    const { data: tenantResult, error: tenantError } = await supabase.functions.invoke('create-tenant', {
      body: { name: name.trim(), industry_template: template },
    });
    if (tenantError) {
      setSaving(false);
      setError(tenantError.message);
      return;
    }
    const tenantId = tenantResult?.tenant?.id as string | undefined;
    if (!tenantId) {
      setSaving(false);
      setError('Tenant created but no ID returned — check Edge Function logs.');
      return;
    }
    if (tenantResult?.seed_warning) {
      setSeedWarning(tenantResult.seed_warning as string);
    }

    // Set modules if not the default full set — the backfill row in tenant_modules
    // already comes from seed_tenant_defaults (template-dependent). Overwrite with
    // the wizard's selection.
    const desired = Array.from(modules);
    if (desired.length > 0) {
      const { error: modErr } = await supabase.rpc('set_tenant_modules', {
        p_tenant_id: tenantId,
        p_modules: desired,
      });
      if (modErr) {
        // Non-fatal — company exists, modules can be fixed from Companies → Modules
        setSeedWarning((prev) => (prev ? prev + ' | ' : '') + `Modules not fully applied: ${modErr.message}`);
      }
    }

    // Invite first admin (company_admin bundle)
    const { error: inviteErr } = await supabase.functions.invoke('invite-user', {
      body: {
        tenant_id: tenantId,
        role_bundle: 'company_admin',
        email: adminEmail.trim(),
      },
    });
    // invite-user expects { tenant_id, role_bundle, email } — but our current
    // edge function also handles modules_and_roles/finance_role; for company_admin
    // it ignores modules. We send minimal body and let it expand to all modules + finance.
    if (inviteErr) {
      setSaving(false);
      setError(`Company created (${name.trim()}) but inviting admin failed: ${inviteErr.message}. You can resend from Companies → Invites.`);
      setSuccessId(tenantId);
      onCreated();
      return;
    }

    setSaving(false);
    setSuccessId(tenantId);
    onCreated();
  };

  return (
    <Dialog open={open} onClose={saving ? undefined : onClose} maxWidth="md" fullWidth>
      <DialogTitle sx={{ display: 'flex', alignItems: 'center', gap: 1, pb: 0 }}>
        <Business color="primary" />
        <span>New Company</span>
        <Chip label={`${step + 1} / 2`} size="small" sx={{ ml: 'auto' }} />
      </DialogTitle>

      <Box sx={{ px: 3, pt: 2 }}>
        <Stepper activeStep={step} alternativeLabel>
          <Step><StepLabel>Company & Admin</StepLabel></Step>
          <Step><StepLabel>Industry & Modules</StepLabel></Step>
        </Stepper>
      </Box>

      <DialogContent sx={{ pt: 3 }}>
        {successId ? (
          <Stack spacing={2} alignItems="center" sx={{ py: 2 }}>
            <CheckCircle color="success" sx={{ fontSize: 48 }} />
            <Typography variant="h6">Company created</Typography>
            <Typography variant="body2" color="text.secondary" textAlign="center">
              <b>{name.trim()}</b> is ready. An invite has been sent to <b>{adminEmail.trim()}</b>. They’ll appear as the company admin once they accept.
              {seedWarning ? <><br /><em>{seedWarning}</em></> : null}
            </Typography>
            <Alert severity="info">Tip: find them instantly in <b>Companies → {name.trim()}</b> or the Platform Dashboard’s recent list.</Alert>
          </Stack>
        ) : step === 0 ? (
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              label="Company name"
              placeholder="e.g. Nile Construction Co."
              fullWidth
              value={name}
              onChange={(e) => setName(e.target.value)}
              disabled={saving}
              autoFocus
            />
            <TextField
              label="First admin email"
              type="email"
              placeholder="admin@company.com"
              fullWidth
              value={adminEmail}
              onChange={(e) => setAdminEmail(e.target.value)}
              disabled={saving}
              helperText="This person becomes the company's Company Admin — they can invite the rest of the team and will have Finance access automatically."
              error={adminEmail.length > 0 && !isValidEmail(adminEmail)}
            />

            <Box sx={{ bgcolor: 'action.hover', borderRadius: 1.5, p: 2 }}>
              <Typography variant="subtitle2" sx={{ mb: 0.5 }}>What happens on create</Typography>
              <Typography variant="body2" color="text.secondary">
                A fresh tenant is created with a 7-stage approval pipeline, departments for the chosen industry, and an invite email. The new admin accepts via <code>/accept-invite</code> and lands in their own isolated workspace.
              </Typography>
              <Box component="ol" sx={{ pl: 2.5, mt: 1, mb: 0 }}>
                {APPROVAL_PIPELINE.map((s) => (
                  <Typography key={s} component="li" variant="body2" color="text.secondary">{s}</Typography>
                ))}
              </Box>
            </Box>

            {error && <Alert severity="error">{error}</Alert>}
            {seedWarning && <Alert severity="warning">{seedWarning}</Alert>}
          </Stack>
        ) : (
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              select
              label="Industry template"
              fullWidth
              value={template}
              onChange={(e) => setTemplate(e.target.value as IndustryTemplate)}
              disabled={saving}
              helperText={INDUSTRY_TEMPLATES.find((t) => t.value === template)?.description}
            >
              {INDUSTRY_TEMPLATES.map((t) => (
                <MenuItem key={t.value} value={t.value}>{t.label} — {t.description}</MenuItem>
              ))}
            </TextField>

            <Divider />

            <Box>
              <Typography variant="subtitle2">Modules for this company</Typography>
              <Typography variant="caption" color="text.secondary">
                Finance + core Procurement are always on. Tick the rest. You can change this anytime from <em>Companies → Modules</em>.
              </Typography>
              <FormGroup sx={{ mt: 1.5, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0.5 }}>
                {MODULE_OPTIONS.map((opt) => (
                  <FormControlLabel
                    key={opt.value}
                    control={<Checkbox checked={modules.has(opt.value)} onChange={() => toggle(opt.value)} disabled={saving} />}
                    label={<Box><Typography variant="body2">{opt.label}</Typography><Typography variant="caption" color="text.secondary">{opt.hint}</Typography></Box>}
                  />
                ))}
              </FormGroup>
              <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1 }}>
                {modules.size} modules selected — {Array.from(modules).join(', ') || 'none (company will only have Finance + Procurement)'}
              </Typography>
            </Box>

            {error && <Alert severity="error">{error}</Alert>}
            {seedWarning && <Alert severity="warning">{seedWarning}</Alert>}
          </Stack>
        )}
      </DialogContent>

      <DialogActions sx={{ px: 3, pb: 2 }}>
        {successId ? (
          <Button onClick={onClose} variant="contained">Done</Button>
        ) : step === 0 ? (
          <>
            <Button onClick={onClose} disabled={saving}>Cancel</Button>
            <Button onClick={() => setStep(1)} variant="contained" disabled={!canNext || !isValidEmail(adminEmail)}>Next</Button>
          </>
        ) : (
          <>
            <Button onClick={() => setStep(0)} disabled={saving}>Back</Button>
            <Button onClick={onClose} disabled={saving}>Cancel</Button>
            <Button onClick={handleCreate} variant="contained" disabled={saving || !canNext}>
              {saving ? <><CircularProgress size={16} sx={{ mr: 1 }} />Creating…</> : 'Create & invite'}
            </Button>
          </>
        )}
      </DialogActions>
    </Dialog>
  );
}