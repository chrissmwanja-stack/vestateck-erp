import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { CssBaseline, ThemeProvider } from '@mui/material';
import '@fontsource/inter/400.css';
import '@fontsource/inter/500.css';
import '@fontsource/inter/600.css';
import '@fontsource/manrope/600.css';
import '@fontsource/manrope/700.css';
import App from './App';
import { AuthProvider } from './lib/authContext';
import { ThemeModeProvider, useThemeMode } from './lib/themeModeContext';
import { getTheme } from './theme/theme';

function ThemedApp() {
  const { resolvedMode } = useThemeMode();
  const theme = React.useMemo(() => getTheme(resolvedMode), [resolvedMode]);

  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <BrowserRouter>
        <AuthProvider>
          <App />
        </AuthProvider>
      </BrowserRouter>
    </ThemeProvider>
  );
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ThemeModeProvider>
      <ThemedApp />
    </ThemeModeProvider>
  </React.StrictMode>
);