import { createTheme, type ThemeOptions } from '@mui/material/styles';
import { alpha } from '@mui/material/styles';
import type { PaletteMode } from '@mui/material';

// VestaPortal brand tokens.
//
// Primary "Harbor Slate" is a deep blueprint-teal -- reads as engineering /
// site-plan rather than generic admin-template blue. Accent "Ochre" is a
// warm amber-gold used sparingly for highlights and active states; it's
// intentionally kept out of backgrounds/fills so it never gets confused
// with the app's warning/alert banners (ImpersonationBanner, form Alerts),
// which are already MUI's default orange.
const brand = {
  harbor: {
    900: '#0A2530',
    700: '#123B44',
    500: '#1B5560',
    300: '#4C818B',
    100: '#DCE8EA',
  },
  ochre: {
    700: '#8F5D14',
    500: '#C4872B',
    300: '#E0B368',
    100: '#F6E7CE',
  },
  neutral: {
    950: '#0F1417',
    900: '#161C20',
    800: '#1E2A2E',
    700: '#2C3B40',
    500: '#5B6C71',
    300: '#9AABAE',
    100: '#E4E8E9',
  },
};

const radius = 10;

function paletteFor(mode: PaletteMode): ThemeOptions['palette'] {
  if (mode === 'dark') {
    return {
      mode,
      primary: { main: brand.harbor[300], light: brand.harbor[100], dark: brand.harbor[500], contrastText: '#0A1418' },
      secondary: { main: brand.ochre[300], light: brand.ochre[100], dark: brand.ochre[500], contrastText: '#241703' },
      background: { default: '#10171A', paper: '#161F23' },
      text: { primary: '#EAF0F1', secondary: alpha('#EAF0F1', 0.68) },
      divider: alpha('#EAF0F1', 0.12),
    };
  }
  return {
    mode,
    primary: { main: brand.harbor[700], light: brand.harbor[500], dark: brand.harbor[900], contrastText: '#FFFFFF' },
    secondary: { main: brand.ochre[500], light: brand.ochre[300], dark: brand.ochre[700], contrastText: '#241703' },
    background: { default: '#F6F7F8', paper: '#FFFFFF' },
    text: { primary: brand.neutral[800], secondary: brand.neutral[500] },
    divider: brand.neutral[100],
  };
}

export function getTheme(mode: PaletteMode) {
  const palette = paletteFor(mode);

  return createTheme({
    palette,
    shape: { borderRadius: radius },
    typography: {
      fontFamily: '"Inter", "Helvetica Neue", Arial, sans-serif',
      h1: { fontFamily: '"Manrope", "Inter", sans-serif', fontWeight: 700 },
      h2: { fontFamily: '"Manrope", "Inter", sans-serif', fontWeight: 700 },
      h3: { fontFamily: '"Manrope", "Inter", sans-serif', fontWeight: 700 },
      h4: { fontFamily: '"Manrope", "Inter", sans-serif', fontWeight: 700 },
      h5: { fontFamily: '"Manrope", "Inter", sans-serif', fontWeight: 600 },
      h6: { fontFamily: '"Manrope", "Inter", sans-serif', fontWeight: 600 },
      button: { fontWeight: 600, textTransform: 'none' },
    },
    components: {
      MuiCssBaseline: {
        styleOverrides: {
          body: {
            backgroundColor: palette?.background?.default,
          },
        },
      },
      MuiAppBar: {
        styleOverrides: {
          root: {
            backgroundImage: 'none',
            backgroundColor: mode === 'dark' ? '#0E1619' : brand.harbor[700],
          },
        },
      },
      MuiButton: {
        styleOverrides: {
          root: { borderRadius: radius - 2 },
          contained: { boxShadow: 'none', '&:hover': { boxShadow: 'none' } },
        },
      },
      MuiPaper: {
        styleOverrides: {
          root: { backgroundImage: 'none' },
        },
      },
      MuiCard: {
        styleOverrides: {
          root: {
            borderRadius: radius,
            border: `1px solid ${palette?.divider}`,
            boxShadow: 'none',
          },
        },
      },
      MuiChip: {
        styleOverrides: {
          root: { borderRadius: 6, fontWeight: 500 },
        },
      },
      MuiTableCell: {
        styleOverrides: {
          head: {
            fontWeight: 600,
            color: mode === 'dark' ? brand.neutral[300] : brand.neutral[500],
          },
        },
      },
      MuiTableRow: {
        styleOverrides: {
          root: {
            '&:last-child td': { borderBottom: 0 },
          },
        },
      },
    },
  });
}