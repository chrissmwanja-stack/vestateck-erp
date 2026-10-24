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
          // App code is deliberately NOT grouped by hand. Grouping features into
          // finance/procurement/admin chunks created import cycles between those
          // chunks, and a production build then threw "Cannot access 'X' before
          // initialization" at load (blank screen). Rollup splits the lazy routes
          // on its own and keeps shared modules acyclic.
        },
      },
    },
  },
});
