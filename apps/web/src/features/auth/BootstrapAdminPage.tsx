import { useEffect, useState } from 'react';
import { Box, Button, Card, CardContent, Stack, TextField, Typography } from '@mui/material';
import Alert from '@mui/material/Alert';
import CircularProgress from '@mui/material/CircularProgress';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';

const bootstrapSchema = z
  .object({
    name: z.string().min(1, 'Name is required'),
    email: z.string().email('Enter a valid email'),
    password: z.string().min(8, 'Password must be at least 8 characters'),
    confirmPassword: z.string().min(1, 'Confirm your password'),
    code: z.string().min(1, 'Bootstrap code is required'),
  })
  .refine((data) => data.password === data.confirmPassword, {
    message: "Passwords don't match",
    path: ['confirmPassword'],
  });

type BootstrapValues = z.infer<typeof bootstrapSchema>;

// One-time claim page for the very first platform admin -- replaces the
// manual `UPDATE app_users SET is_platform_admin = true ...` workflow
// (see onboarding session notes, section 6, "known gaps"). Closes itself
// once a platform admin exists: checks platform_has_admin() on load and
// again server-side (bootstrap-admin edge function) at submit time, so
// there's no window where the check-then-act can be raced from the UI
// alone.
type PageState = 'checking' | 'already-claimed' | 'form' | 'submitting' | 'error';

export default function BootstrapAdminPage() {
  const navigate = useNavigate();
  const [pageState, setPageState] = useState<PageState>('checking');
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const {
    control,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<BootstrapValues>({
    resolver: zodResolver(bootstrapSchema),
    defaultValues: { name: '', email: '', password: '', confirmPassword: '', code: '' },
  });

  useEffect(() => {
    let cancelled = false;
    supabase.rpc('platform_has_admin').then(({ data, error }) => {
      if (cancelled) return;
      if (error) {
        setErrorMessage(error.message);
        setPageState('error');
        return;
      }
      setPageState(data ? 'already-claimed' : 'form');
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const onSubmit = async (values: BootstrapValues) => {
    setErrorMessage(null);
    setPageState('submitting');

    // Reuse an existing session if there already is one (e.g. you signed
    // in via /login separately) rather than re-authenticating.
    const { data: existingSessionData } = await supabase.auth.getSession();
    let session = existingSessionData.session;

    if (!session) {
      // Sign up to get a session. For an email that's already
      // registered, Supabase's signUp() silently returns no session AND
      // NO ERROR (by design, to avoid leaking account existence) --
      // so "no session" is the real signal to fall back to sign-in,
      // not just an explicit error.
      const { data: signUpData, error: signUpError } = await supabase.auth.signUp({
        email: values.email,
        password: values.password,
      });

      session = signUpData.session;

      if (!session) {
        const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
          email: values.email,
          password: values.password,
        });
        if (signInError) {
          setErrorMessage(signUpError?.message ?? signInError.message);
          setPageState('form');
          return;
        }
        session = signInData.session;
      }
    }

    if (!session) {
      setErrorMessage(
        'Account created but no session yet -- if email confirmation is required, confirm and try again.'
      );
      setPageState('form');
      return;
    }

    const { error: claimError } = await supabase.functions.invoke('bootstrap-admin', {
      body: { name: values.name, code: values.code },
    });

    if (claimError) {
      setErrorMessage(claimError.message);
      setPageState('form');
      return;
    }

    navigate('/admin/companies', { replace: true });
  };

  return (
    <Box display="flex" justifyContent="center" alignItems="center" minHeight="70vh">
      <Card sx={{ maxWidth: 440, width: '100%' }} variant="outlined">
        <CardContent>
          <Typography variant="h6" gutterBottom>
            Claim platform admin
          </Typography>

          {pageState === 'checking' && (
            <Box display="flex" alignItems="center" gap={2} sx={{ mt: 2 }}>
              <CircularProgress size={20} />
              <Typography variant="body2" color="text.secondary">
                Checking whether this is still open…
              </Typography>
            </Box>
          )}

          {pageState === 'already-claimed' && (
            <Alert severity="info" sx={{ mt: 2 }}>
              A platform admin already exists. Ask them to invite you from Companies
              console instead.
            </Alert>
          )}

          {pageState === 'error' && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {errorMessage ?? 'Something went wrong.'}
            </Alert>
          )}

          {(pageState === 'form' || pageState === 'submitting') && (
            <>
              <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
                This claims the first platform admin account. It only works once, and
                only with the bootstrap code.
              </Typography>

              <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
                <Stack spacing={2.5}>
                  <Controller
                    name="name"
                    control={control}
                    render={({ field }) => (
                      <TextField
                        {...field}
                        label="Your name"
                        error={!!errors.name}
                        helperText={errors.name?.message}
                        fullWidth
                        disabled={pageState === 'submitting'}
                      />
                    )}
                  />
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
                        disabled={pageState === 'submitting'}
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
                        type="password"
                        autoComplete="new-password"
                        error={!!errors.password}
                        helperText={errors.password?.message}
                        fullWidth
                        disabled={pageState === 'submitting'}
                      />
                    )}
                  />
                  <Controller
                    name="confirmPassword"
                    control={control}
                    render={({ field }) => (
                      <TextField
                        {...field}
                        label="Confirm password"
                        type="password"
                        autoComplete="new-password"
                        error={!!errors.confirmPassword}
                        helperText={errors.confirmPassword?.message}
                        fullWidth
                        disabled={pageState === 'submitting'}
                      />
                    )}
                  />
                  <Controller
                    name="code"
                    control={control}
                    render={({ field }) => (
                      <TextField
                        {...field}
                        label="Bootstrap code"
                        error={!!errors.code}
                        helperText={errors.code?.message}
                        fullWidth
                        disabled={pageState === 'submitting'}
                      />
                    )}
                  />

                  {errorMessage && <Alert severity="error">{errorMessage}</Alert>}

                  <Button
                    type="submit"
                    variant="contained"
                    size="large"
                    disabled={isSubmitting || pageState === 'submitting'}
                  >
                    {pageState === 'submitting' ? 'Claiming…' : 'Claim platform admin'}
                  </Button>
                </Stack>
              </Box>
            </>
          )}
        </CardContent>
      </Card>
    </Box>
  );
}