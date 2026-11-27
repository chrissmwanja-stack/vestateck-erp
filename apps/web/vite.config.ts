import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
  },
  build: {
    rolldownOptions: {
      output: {
        // Vite 8 bundles with Rolldown, not Rollup. With the old manualChunks
        // function (and with an explicit 'pdf' group) Rolldown folded Vite's
        // dynamic-import preload helper into the jsPDF chunk, so the entry
        // statically imported all of jsPDF on first load
        // (scripts/check-initial-load.mjs catches this). Fix: pin the helpers to
        // 'vendor' (highest priority; it is loaded eagerly anyway), and keep the
        // PDF libraries out of every group so Rolldown emits them as on-demand
        // chunks of their own. The catch-all vendor group must therefore exclude
        // them. Groups are matched highest priority first.
        //
        // App code is deliberately NOT grouped by hand. Grouping features into
        // finance/procurement/admin chunks created import cycles between those
        // chunks, and a production build then threw "Cannot access 'X' before
        // initialization" at load (blank screen). Rolldown splits the lazy
        // routes on its own and keeps shared modules acyclic.
        codeSplitting: {
          groups: [
            { name: 'vendor', test: /vite[\/](preload-helper|modulepreload-polyfill)/, priority: 100 },
            { name: 'mui', test: /node_modules[\/]@mui/, priority: 50 },
            { name: 'xlsx', test: /node_modules[\/].*(xlsx|sheetjs)/, priority: 50 },
            { name: 'html2canvas', test: /node_modules[\/].*html2canvas/, priority: 50 },
            { name: 'recharts', test: /node_modules[\/].*recharts/, priority: 50 },
            { name: 'router', test: /node_modules[\/].*react-router/, priority: 50 },
            { name: 'vendor', test: /node_modules[\/](?!.*(jspdf|pdf-lib|jspdf-autotable|canvg|fflate|dompurify))/, priority: 10 },
          ],
        },
      },
    },
  },
});