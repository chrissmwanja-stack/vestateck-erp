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

// Operator branding (item 6): platform_settings.branding.primary_color can
// replace Harbor Slate. We derive the light/dark/contrast variants from the
// one hex the operator picked so a custom colour still yields a coherent
// palette. The default colour maps exactly onto the hand-tuned brand ramp.
export const DEFAULT_PRIMARY = brand.harbor[700];

function hexToRgb(hex: string): [number, number, number] {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  const n = parseInt(m ? m[1] : '123B44', 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function rgbToHex([r, g, b]: [number, number, number]): string {
  return `#${[r, g, b].map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('').toUpperCase()}`;
}

function mix(hex: string, target: [number, number, number], amount: number): string {
  const [r, g, b] = hexToRgb(hex);
  return rgbToHex([r + (target[0] - r) * amount, g + (target[1] - g) * amount, b + (target[2] - b) * amount]);
}

// WCAG relative luminance; picks white or near-black text over the colour.
export function contrastTextFor(hex: string): string {
  const [r, g, b] = hexToRgb(hex).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  }) as [number, number, number];
  const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return lum > 0.35 ? '#0A1418' : '#FFFFFF';
}

export interface PrimaryRamp {
  900: string;
  700: string;
  500: string;
  300: string;
  100: string;
}

export function rampFor(primary: string): PrimaryRamp {
  const hex = /^#[0-9a-f]{6}$/i.test(primary) ? primary.toUpperCase() : DEFAULT_PRIMARY;
  if (hex === DEFAULT_PRIMARY.toUpperCase()) return brand.harbor;
  return {
    900: mix(hex, [0, 0, 0], 0.45),
    700: hex,
    500: mix(hex, [255, 255, 255], 0.18),
    300: mix(hex, [255, 255, 255], 0.45),
    100: mix(hex, [255, 255, 255], 0.85),
  };
}

function paletteFor(mode: PaletteMode, harbor: PrimaryRamp): ThemeOptions['palette'] {
  if (mode === 'dark') {
    return {
      mode,
      primary: { main: harbor[300], light: harbor[100], dark: harbor[500], contrastText: contrastTextFor(harbor[300]) },
      secondary: { main: brand.ochre[300], light: brand.ochre[100], dark: brand.ochre[500], contrastText: '#241703' },
      background: { default: '#10171A', paper: '#161F23' },
      text: { primary: '#EAF0F1', secondary: alpha('#EAF0F1', 0.68) },
      divider: alpha('#EAF0F1', 0.12),
    };
  }
  return {
    mode,
    primary: { main: harbor[700], light: harbor[500], dark: harbor[900], contrastText: contrastTextFor(harbor[700]) },
    secondary: { main: brand.ochre[500], light: brand.ochre[300], dark: brand.ochre[700], contrastText: '#241703' },
    background: { default: '#F6F7F8', paper: '#FFFFFF' },
    text: { primary: brand.neutral[800], secondary: brand.neutral[500] },
    divider: brand.neutral[100],
  };
}

export function getTheme(mode: PaletteMode, primary: string = DEFAULT_PRIMARY) {
  const harbor = rampFor(primary);
  const palette = paletteFor(mode, harbor);

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
            backgroundColor: mode === 'dark' ? '#0E1619' : harbor[700],
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