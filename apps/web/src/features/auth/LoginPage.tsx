import { useEffect, useState } from 'react';
import {
  Box,
  Button,
  IconButton,
  InputAdornment,
  Paper,
  Stack,
  TextField,
  Typography,
  useMediaQuery,
  useTheme,
} from '@mui/material';
import Alert from '@mui/material/Alert';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { useLocation, useNavigate } from 'react-router-dom';
import {
  MailOutline,
  LockOutlined,
  Visibility,
  VisibilityOff,
  ShoppingCartOutlined,
  AttachMoneyOutlined,
  SupportAgentOutlined,
  GroupsOutlined,
  GavelOutlined,
  ParkOutlined,
} from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';

const loginSchema = z.object({
  email: z.string().email('Enter a valid email address'),
  password: z.string().min(1, 'Password is required'),
});

type LoginFormValues = z.infer<typeof loginSchema>;

// The modules shown on the brand panel are real portals in the product
// (see ModuleTree.tsx) — this is meant to read as "what you're signing
// into", not a decorative pattern.
const MODULES = [
  { label: 'Procurement', icon: ShoppingCartOutlined },
  { label: 'Finance', icon: AttachMoneyOutlined },
  { label: 'IT Support', icon: SupportAgentOutlined },
  { label: 'Human Resources', icon: GroupsOutlined },
  { label: 'Legal & Compliance', icon: GavelOutlined },
  { label: 'Sustainability', icon: ParkOutlined },
];

export default function LoginPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const theme = useTheme();
  const isCompact = useMediaQuery(theme.breakpoints.down('md'));
  const { idleTimedOut } = useAuth();
  const [loginError, setLoginError] = useState<string | null>(null);
  const [showPassword, setShowPassword] = useState(false);

  // Supabase's real MFA login flow: a session exists at aal1 right after
  // password sign-in even when a verified TOTP factor exists -- the
  // caller has to separately challenge+verify to reach aal2. This also
  // covers the case where RequireAuth redirects back here for a session
  // that's already password-authenticated but never completed that step
  // (e.g. another tab), so we check on mount too, not just post-submit.
  const [view, setView] = useState<'password' | 'mfaChallenge'>('password');
  const [mfaFactorId, setMfaFactorId] = useState<string | null>(null);
  const [mfaChallengeId, setMfaChallengeId] = useState<string | null>(null);
  const [mfaCode, setMfaCode] = useState('');
  const [mfaVerifying, setMfaVerifying] = useState(false);
  const [mfaError, setMfaError] = useState<string | null>(null);

  const goToApp = () => {
    const from = (location.state as { from?: Location })?.from?.pathname ?? '/requests/new';
    navigate(from, { replace: true });
  };

  // Shared by both the post-submit path and the on-mount check: if the
  // current session needs aal2, find its verified factor, open a
  // challenge, and show the code-entry view instead of navigating in.
  const checkAalAndProceed = async () => {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal?.currentLevel === 'aal1' && aal?.nextLevel === 'aal2') {
      const { data: factorData, error: factorErr } = await supabase.auth.mfa.listFactors();
      const factor = factorData?.totp.find((f) => f.status === 'verified');
      if (factorErr || !factor) {
        setLoginError('Could not start the authenticator check. Try signing in again.');
        return;
      }
      const { data: challenge, error: challengeErr } = await supabase.auth.mfa.challenge({
        factorId: factor.id,
      });
      if (challengeErr || !challenge) {
        setLoginError(challengeErr?.message ?? 'Could not start the authenticator check.');
        return;
      }
      setMfaFactorId(factor.id);
      setMfaChallengeId(challenge.id);
      setView('mfaChallenge');
      return;
    }
    goToApp();
  };

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) checkAalAndProceed();
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const {
    control,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<LoginFormValues>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: '', password: '' },
  });

  const onSubmit = async (values: LoginFormValues) => {
    setLoginError(null);
    const { error } = await supabase.auth.signInWithPassword({
      email: values.email,
      password: values.password,
    });

    if (error) {
      setLoginError(error.message);
      return;
    }

    await checkAalAndProceed();
  };

  const verifyMfaCode = async () => {
    if (!mfaFactorId || !mfaChallengeId || mfaCode.trim().length !== 6) {
      setMfaError('Enter the 6-digit code from your authenticator app.');
      return;
    }
    setMfaVerifying(true);
    setMfaError(null);
    const { error } = await supabase.auth.mfa.verify({
      factorId: mfaFactorId,
      challengeId: mfaChallengeId,
      code: mfaCode.trim(),
    });
    setMfaVerifying(false);
    if (error) {
      setMfaError(error.message);
      return;
    }
    goToApp();
  };

  return (
    <Box display="flex" justifyContent="center" alignItems="center" sx={{ minHeight: { xs: 'auto', md: '78vh' }, py: { xs: 4, md: 0 } }}>
      <Paper
        elevation={0}
        sx={{
          maxWidth: 920,
          width: '100%',
          borderRadius: 4,
          overflow: 'hidden',
          display: 'flex',
          flexDirection: { xs: 'column', md: 'row' },
          border: '1px solid',
          borderColor: 'divider',
          boxShadow: '0 24px 60px -24px rgba(11, 31, 58, 0.35)',
        }}
      >
        {/* Brand panel */}
        <Box
          sx={{
            flexBasis: { xs: 'auto', md: '44%' },
            flexShrink: 0,
            position: 'relative',
            px: { xs: 3, md: 5 },
            py: { xs: 4, md: 6 },
            background: 'linear-gradient(155deg, #0A2530 0%, #123B44 62%, #1B5560 100%)',
            color: '#fff',
            display: 'flex',
            flexDirection: 'column',
            gap: 5,
            overflow: 'hidden',
            justifyContent: 'center',
            minHeight: { md: 460 },
          }}
        >
          {/* faint grid texture */}
          <Box
            aria-hidden
            sx={{
              position: 'absolute',
              inset: 0,
              opacity: 0.5,
              backgroundImage:
                'linear-gradient(rgba(255,255,255,0.06) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.06) 1px, transparent 1px)',
              backgroundSize: '28px 28px',
              maskImage: 'radial-gradient(ellipse at top left, black 0%, transparent 72%)',
            }}
          />

          <Box sx={{ position: 'relative' }}>
            <Typography
              variant="overline"
              sx={{ color: 'rgba(255,255,255,0.6)', letterSpacing: 2, fontWeight: 600 }}
            >
              Multi-department ERP
            </Typography>
            <Typography variant="h4" sx={{ fontWeight: 800, letterSpacing: -0.5, lineHeight: 1.15, mt: 0.5 }}>
              VestaPortal
            </Typography>
            {!isCompact && (
              <Typography variant="body2" sx={{ color: 'rgba(255,255,255,0.72)', mt: 1.5, maxWidth: 320 }}>
                One workspace for procurement, finance, approvals, and every team that keeps the
                business running.
              </Typography>
            )}
          </Box>

          {!isCompact && (
            <Box sx={{ position: 'relative', display: 'flex', flexWrap: 'wrap', gap: 1 }}>
              {MODULES.map(({ label, icon: Icon }, i) => (
                <Box
                  key={label}
                  sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 0.75,
                    px: 1.25,
                    py: 0.75,
                    borderRadius: 2,
                    bgcolor: 'rgba(255,255,255,0.07)',
                    border: '1px solid rgba(255,255,255,0.14)',
                    transform: i % 2 === 1 ? 'translateY(6px)' : 'none',
                  }}
                >
                  <Icon sx={{ fontSize: 16, color: '#E0B368' }} />
                  <Typography variant="caption" sx={{ color: 'rgba(255,255,255,0.88)', fontWeight: 500 }}>
                    {label}
                  </Typography>
                </Box>
              ))}
            </Box>
          )}
        </Box>

        {/* Form panel */}
        <Box sx={{ flex: 1, px: { xs: 3, sm: 5 }, py: { xs: 4, sm: 6 }, bgcolor: 'background.paper' }}>
          <Typography variant="h5" sx={{ fontWeight: 700 }}>
            {view === 'mfaChallenge' ? 'Enter your authenticator code' : 'Welcome back'}
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5, mb: 4 }}>
            {view === 'mfaChallenge'
              ? 'Open your authenticator app and enter the 6-digit code.'
              : 'Sign in to your VestaPortal workspace.'}
          </Typography>

          {view === 'password' && idleTimedOut && (
            <Alert severity="info" sx={{ mb: 2.5 }}>
              You were signed out after a period of inactivity. Sign in again to continue.
            </Alert>
          )}

          {view === 'password' ? (
            <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
              <Stack spacing={2.5}>
                <Controller
                  name="email"
                  control={control}
                  render={({ field }) => (
                    <TextField
                      {...field}
                      label="Email"
                      type="email"
                      autoComplete="email"
                      error={!!errors.email}
                      helperText={errors.email?.message}
                      fullWidth
                      InputProps={{
                        startAdornment: (
                          <InputAdornment position="start">
                            <MailOutline fontSize="small" sx={{ color: 'text.disabled' }} />
                          </InputAdornment>
                        ),
                      }}
                    />
                  )}
                />
                <Controller
                  name="password"
                  control={control}
                  render={({ field }) => (
                    <TextField
                      {...field}
                      label="Password"
                      type={showPassword ? 'text' : 'password'}
                      autoComplete="current-password"
                      error={!!errors.password}
                      helperText={errors.password?.message}
                      fullWidth
                      InputProps={{
                        startAdornment: (
                          <InputAdornment position="start">
                            <LockOutlined fontSize="small" sx={{ color: 'text.disabled' }} />
                          </InputAdornment>
                        ),
                        endAdornment: (
                          <InputAdornment position="end">
                            <IconButton
                              aria-label={showPassword ? 'Hide password' : 'Show password'}
                              onClick={() => setShowPassword((v) => !v)}
                              edge="end"
                              size="small"
                            >
                              {showPassword ? <VisibilityOff fontSize="small" /> : <Visibility fontSize="small" />}
                            </IconButton>
                          </InputAdornment>
                        ),
                      }}
                    />
                  )}
                />

                {loginError && <Alert severity="error">{loginError}</Alert>}

                <Button type="submit" variant="contained" size="large" disabled={isSubmitting} sx={{ py: 1.25 }}>
                  {isSubmitting ? 'Signing in…' : 'Sign in'}
                </Button>
              </Stack>
            </Box>
          ) : (
            <Stack spacing={2.5}>
              <TextField
                label="6-digit code"
                value={mfaCode}
                onChange={(e) => setMfaCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
                placeholder="123456"
                inputProps={{ inputMode: 'numeric', maxLength: 6 }}
                autoFocus
                fullWidth
              />
              {mfaError && <Alert severity="error">{mfaError}</Alert>}
              <Button
                variant="contained"
                size="large"
                onClick={verifyMfaCode}
                disabled={mfaVerifying}
                sx={{ py: 1.25 }}
              >
                {mfaVerifying ? 'Verifying…' : 'Verify'}
              </Button>
              <Button
                onClick={() => {
                  supabase.auth.signOut();
                  setView('password');
                }}
              >
                Sign in as someone else
              </Button>
            </Stack>
          )}

          <Box
            sx={{
              mt: 4,
              p: 1.5,
              borderRadius: 2,
              bgcolor: 'action.hover',
              border: '1px dashed',
              borderColor: 'divider',
            }}
          >
            <Typography variant="caption" color="text.secondary">
              Need help? Contact your company admin or support@erp.com
            </Typography>
          </Box>
        </Box>
      </Paper>
    </Box>
  );
}