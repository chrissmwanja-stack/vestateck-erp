import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
  },
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          // Vendor split — improves long-term caching
          if (id.includes('node_modules')) {
            if (id.includes('@mui')) return 'mui';
            if (id.includes('xlsx') || id.includes('sheetjs')) return 'xlsx';
            if (id.includes('html2canvas')) return 'html2canvas';
            if (id.includes('recharts')) return 'recharts';
            if (id.includes('jspdf') || id.includes('pdf-lib')) return 'pdf';
            if (id.includes('react-router')) return 'router';
            return 'vendor';
          }
          // Portal grouping — Finance, Procurement, etc. loaded on demand but cached as portal
          if (id.includes('features/financial') || id.includes('features/finance')) return 'finance';
          if (
            id.includes('features/procurement') ||
            id.includes('features/requests') ||
            id.includes('features/offers') ||
            id.includes('features/approvals') ||
            id.includes('features/multiplexing')
          )
            return 'procurement';
          if (id.includes('features/it-support')) return 'it-support';
          if (id.includes('modules/portals/hr')) return 'hr';
          if (id.includes('modules/portals/law-compliance')) return 'law';
          if (id.includes('modules/portals/pmo')) return 'pmo';
          if (id.includes('modules/portals/business-development')) return 'bd';
          if (id.includes('modules/portals/machine-operation')) return 'machine';
          if (id.includes('modules/portals/sustainability')) return 'sustainability';
          if (id.includes('features/admin') || id.includes('features/team') || id.includes('features/account')) return 'admin';
          if (id.includes('features/reports')) return 'reports';
        },
      },
    },
  },
});
