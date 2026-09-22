import { Component, type ErrorInfo, type ReactNode } from 'react';
import { Box, Button, Card, CardContent, Stack, Typography } from '@mui/material';

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
}

/**
 * Catches render-time errors anywhere below it in the tree and shows a
 * "reload / report" card instead of a blank white screen.
 *
 * This only catches errors thrown during React's render/commit/lifecycle
 * phases (per React's error boundary contract) -- it does NOT catch errors
 * inside async callbacks, event handlers, or promise rejections (e.g. an
 * unhandled `supabase.from(...).select()` rejection). Those still need to
 * be caught at the call site and surfaced via useToast().
 *
 * Wrapped around the whole app shell in main.tsx. A single misbehaving
 * screen still brings down everything below the boundary, so in the
 * future this could be pushed down to wrap each route's <Suspense>
 * boundary individually for finer-grained isolation -- not done yet,
 * left as a follow-up.
 */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // eslint-disable-next-line no-console
    console.error('Unhandled render error caught by ErrorBoundary:', error, info.componentStack);
  }

  handleReload = () => {
    window.location.reload();
  };

  handleReport = () => {
    const { error } = this.state;
    const subject = encodeURIComponent(`VestaPortal error: ${error?.message ?? 'unknown'}`);
    const body = encodeURIComponent(
      `Page: ${window.location.href}\nTime: ${new Date().toISOString()}\n\nError:\n${error?.stack ?? error?.message ?? 'unknown'}`
    );
    window.location.href = `mailto:support@vestateck.com?subject=${subject}&body=${body}`;
  };

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;

    return (
      <Box
        sx={{
          minHeight: '100vh',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          p: 3,
          bgcolor: 'background.default',
        }}
      >
        <Card sx={{ maxWidth: 480 }}>
          <CardContent sx={{ p: 4 }}>
            <Typography variant="h6" fontWeight={700} gutterBottom>
              Something went wrong
            </Typography>
            <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
              This screen hit an unexpected error and couldn't continue. Reloading usually
              fixes it. If it keeps happening, send a report and we'll take a look.
            </Typography>
            <Stack direction="row" spacing={1.5}>
              <Button variant="contained" onClick={this.handleReload}>
                Reload
              </Button>
              <Button variant="outlined" onClick={this.handleReport}>
                Report issue
              </Button>
            </Stack>
          </CardContent>
        </Card>
      </Box>
    );
  }
}