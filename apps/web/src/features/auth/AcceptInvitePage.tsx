import { useEffect, useState } from 'react';
import { Box, Button, Card, CardContent, Stack, TextField, Typography } from '@mui/material';
import Alert from '@mui/material/Alert';
import CircularProgress from '@mui/material/CircularProgress';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';

const setPasswordSchema = z
  .object({
    password: z.string().min(8, 'Password must be at least 8 characters'),
    confirmPassword: z.string().min(1, 'Confirm your password'),
  })
  .refine((data) => data.password === data.confirmPassword, {
    message: "Passwords don't match",
    path: ['confirmPassword'],
  });

type SetPasswordValues = z.infer<typeof setPasswordSchema>;

// The invite link from the accept-invite email lands here. Supabase's JS
// client auto-detects the access/refresh tokens in the URL fragment on
// load (detectSessionInUrl, on by default) and turns them into a real
// session — that's what lets an invited person set a password without
// having one already. This page just waits for that session, collects a
// password, and then calls the accept-invite edge function to turn the
// pending invitations row into real app_users / staff_roles rows.
type PageState = 'checking-link' | 'invalid-link' | 'set-password' | 'finishing' | 'error';

export default function AcceptInvitePage() {
  const navigate = useNavigate();
  const [pageState, setPageState] = useState<PageState>('checking-link');
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const {
    control,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<SetPasswordValues>({
    resolver: zodResolver(setPasswordSchema),
    defaultValues: { password: '', confirmPassword: '' },
  });

  useEffect(() => {
    let cancelled = false;

    // Supabase parses the invite link's tokens asynchronously. Check for
    // an existing session first (fast path if it already resolved),
    // then also listen for the SIGNED_IN event the token exchange fires.
    supabase.auth.getSession().then(({ data }) => {
      if (cancelled) return;
      if (data.session) {
        setPageState('set-password');
      }
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((event, session) => {
      if (cancelled) return;
      if (event === 'SIGNED_IN' && session) {
        setPageState('set-password');
      }
    });

    // If nothing resolves the link within a few seconds, it's expired,
    // already used, or was opened without its token fragment.
    const timeout = setTimeout(() => {
      if (cancelled) return;
      setPageState((current) => (current === 'checking-link' ? 'invalid-link' : current));
    }, 5000);

    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
      clearTimeout(timeout);
    };
  }, []);

  const onSubmit = async (values: SetPasswordValues) => {
    setErrorMessage(null);

    const { error: passwordError } = await supabase.auth.updateUser({
      password: values.password,
    });
    if (passwordError) {
      setErrorMessage(passwordError.message);
      return;
    }

    setPageState('finishing');

    const { data: acceptResult, error: acceptError } = await supabase.functions.invoke(
      'accept-invite'
    );
    if (acceptError) {
      setErrorMessage(acceptError.message);
      setPageState('set-password');
      return;
    }

    // Company admins land on the setup checklist (departments -> positions
    // -> invite team) since they're the ones bootstrapping a brand-new
    // tenant. Everyone else goes straight into the app, same as a normal
    // login.
    const destination =
      acceptResult?.role_bundle === 'company_admin' ? '/setup' : '/requests/new';
    navigate(destination, { replace: true });
  };

  return (
    <Box display="flex" justifyContent="center" alignItems="center" minHeight="70vh">
      <Card sx={{ maxWidth: 420, width: '100%' }} variant="outlined">
        <CardContent>
          <Typography variant="h6" gutterBottom>
            Accept your invite
          </Typography>

          {pageState === 'checking-link' && (
            <Box display="flex" alignItems="center" gap={2} sx={{ mt: 2 }}>
              <CircularProgress size={20} />
              <Typography variant="body2" color="text.secondary">
                Verifying your invite link…
              </Typography>
            </Box>
          )}

          {pageState === 'invalid-link' && (
            <Alert severity="error" sx={{ mt: 2 }}>
              This invite link is invalid or has expired. Ask whoever invited you to send a new
              one.
            </Alert>
          )}

          {(pageState === 'set-password' || pageState === 'finishing') && (
            <>
              <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
                Set a password to finish joining your organization.
              </Typography>

              <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
                <Stack spacing={2.5}>
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
                        disabled={pageState === 'finishing'}
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
                        disabled={pageState === 'finishing'}
                      />
                    )}
                  />

                  {errorMessage && <Alert severity="error">{errorMessage}</Alert>}

                  <Button
                    type="submit"
                    variant="contained"
                    size="large"
                    disabled={isSubmitting || pageState === 'finishing'}
                  >
                    {pageState === 'finishing' ? 'Setting up your account…' : 'Set password & continue'}
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