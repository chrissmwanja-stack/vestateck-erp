import { useCallback, useEffect, useMemo, useState } from 'react';
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
import { useModuleRegistry } from '../../lib/useModuleRegistry';
import { templateItemNames, type TemplateRow } from './platformConfig';
import { friendlyPlatformError } from './usePlatformAdminSession';

interface WizardProps {
  open: boolean;
  onClose: () => void;
  onCreated: () => void;
}

// Short descriptions shown under each module. Names come from the registry;
// a module added later without a hint here still renders, just without one.
const MODULE_HINTS: Record<string, string> = {
  hr: 'Employees, leave, payroll, recruitment',
  legal: 'Contracts, cases, compliance register',
  bd: 'Leads, opportunities, proposals, tenders',
  it: 'Tickets, assets, KB, SLAs',
  pmo: 'Projects, tasks, Gantt, resources',
  procurement: 'Advanced procurement (core procurement is always on)',
  machine_operation: 'Equipment, maintenance, fuel logs',
  sustainability: 'Carbon, energy, waste, initiatives',
  insurance: 'Clients, policies, renewals, commissions',
};

export default function CompanyCreateWizard({ open, onClose, onCreated }: WizardProps) {
  const { entitledModules } = useModuleRegistry();
  const [step, setStep] = useState(0);
  const [name, setName] = useState('');
  const [adminEmail, setAdminEmail] = useState('');
  // Templates are data (industry_templates): the wizard offers whatever is active
  // and starts the module selection from the chosen template's own module items,
  // so a template like Insurance Brokerage is not overwritten by construction defaults.
  const [templates, setTemplates] = useState<TemplateRow[] | null>(null);
  const [templatesError, setTemplatesError] = useState<string | null>(null);
  const [template, setTemplate] = useState('');
  const [modules, setModules] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [successId, setSuccessId] = useState<string | null>(null);
  const [seedWarning, setSeedWarning] = useState<string | null>(null);

  const entitledKeys = useMemo(() => new Set(entitledModules.map((m) => m.key)), [entitledModules]);

  // Module keys a template seeds that a company can actually be granted.
  const modulesOf = useCallback(
    (t: TemplateRow) => new Set(templateItemNames(t, 'module').filter((k) => entitledKeys.has(k))),
    [entitledKeys],
  );

  const reset = useCallback(() => {
    setStep(0);
    setName('');
    setAdminEmail('');
    setTemplates(null);
    setTemplatesError(null);
    setTemplate('');
    setModules(new Set());
    setError(null);
    setSeedWarning(null);
    setSuccessId(null);
  }, []);

  useEffect(() => {
    if (!open) {
      reset();
      return;
    }
    let cancelled = false;
    supabase.rpc('list_industry_templates', { p_include_inactive: false }).then(({ data, error: err }) => {
      if (cancelled) return;
      if (err) {
        setTemplates([]);
        setTemplatesError(friendlyPlatformError(err.message));
        return;
      }
      const list = ((data ?? []) as TemplateRow[]).filter((t) => t.is_active);
      setTemplates(list);
      setTemplatesError(list.length === 0 ? 'No active industry templates are available.' : null);
    });
    return () => {
      cancelled = true;
    };
  }, [open, reset]);

  // Once templates (and the module registry) are in, preselect the default template.
  useEffect(() => {
    if (!templates || templates.length === 0 || template) return;
    if (entitledModules.length === 0) return;
    const initial = templates.find((t) => t.is_default) ?? templates[0];
    setTemplate(initial.key);
    setModules(modulesOf(initial));
  }, [templates, template, entitledModules.length, modulesOf]);

  const selectedTemplate = useMemo(() => templates?.find((t) => t.key === template) ?? null, [templates, template]);

  const selectTemplate = (key: string) => {
    setTemplate(key);
    const t = templates?.find((x) => x.key === key);
    if (t) setModules(modulesOf(t));
  };

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
    if (!template) {
      setError('Choose an industry template.');
      return;
    }
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
            {!error && (
              <Typography variant="body2" color="text.secondary" textAlign="center">
                <b>{name.trim()}</b> is ready. An invite has been sent to <b>{adminEmail.trim()}</b>. They’ll appear as the company admin once they accept.
                {seedWarning ? <><br /><em>{seedWarning}</em></> : null}
              </Typography>
            )}
            {error && <Alert severity="warning">{error}</Alert>}
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
                A fresh tenant is created from the industry template you pick next: its departments, modules, chart of accounts and approval workflow (if the template has one) are seeded, and an invite email goes to the admin. They accept via <code>/accept-invite</code> and land in their own isolated workspace.
              </Typography>
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
              onChange={(e) => selectTemplate(e.target.value)}
              disabled={saving || !templates || templates.length === 0}
              helperText={
                templates === null
                  ? 'Loading templates…'
                  : selectedTemplate
                    ? selectedTemplate.description ?? undefined
                    : undefined
              }
            >
              {(templates ?? []).map((t) => (
                <MenuItem key={t.key} value={t.key}>{t.name}</MenuItem>
              ))}
            </TextField>

            {templatesError && <Alert severity="error">{templatesError}</Alert>}

            {selectedTemplate && (
              <Box sx={{ bgcolor: 'action.hover', borderRadius: 1.5, p: 2 }}>
                <Typography variant="subtitle2" sx={{ mb: 0.5 }}>This template sets up</Typography>
                <Typography variant="body2" color="text.secondary">
                  {selectedTemplate.department_count} departments · {selectedTemplate.module_count} modules
                  {templateItemNames(selectedTemplate, 'gl_account').length > 0
                    ? ` · ${templateItemNames(selectedTemplate, 'gl_account').length} GL accounts`
                    : ''}
                  {' · '}
                  {selectedTemplate.stage_count > 0
                    ? `${selectedTemplate.stage_count}-stage approval pipeline`
                    : 'no approval pipeline'}
                </Typography>
                {selectedTemplate.stage_count > 0 && (
                  <Box component="ol" sx={{ pl: 2.5, mt: 1, mb: 0 }}>
                    {templateItemNames(selectedTemplate, 'workflow_stage').map((st) => (
                      <Typography key={st} component="li" variant="body2" color="text.secondary">{st}</Typography>
                    ))}
                  </Box>
                )}
              </Box>
            )}

            <Divider />

            <Box>
              <Typography variant="subtitle2">Modules for this company</Typography>
              <Typography variant="caption" color="text.secondary">
                Finance is always on. The modules below start from the template; change them if needed. You can change this anytime from <em>Companies → Modules</em>.
              </Typography>
              <FormGroup sx={{ mt: 1.5, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0.5 }}>
                {entitledModules.map((opt) => (
                  <FormControlLabel
                    key={opt.key}
                    control={<Checkbox checked={modules.has(opt.key)} onChange={() => toggle(opt.key)} disabled={saving} />}
                    label={<Box><Typography variant="body2">{opt.name}</Typography><Typography variant="caption" color="text.secondary">{MODULE_HINTS[opt.key]}</Typography></Box>}
                  />
                ))}
              </FormGroup>
              <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1 }}>
                {modules.size} modules selected — {Array.from(modules).join(', ') || 'none (company will only have the always-on modules)'}
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
            <Button onClick={handleCreate} variant="contained" disabled={saving || !canNext || !template}>
              {saving ? <><CircularProgress size={16} sx={{ mr: 1 }} />Creating…</> : 'Create & invite'}
            </Button>
          </>
        )}
      </DialogActions>
    </Dialog>
  );
}