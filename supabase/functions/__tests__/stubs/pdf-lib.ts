// Test stand-in for https://esm.sh/pdf-lib@1.17.1.
// Records every line drawn onto the page in fake.pdfLines so tests can assert
// on document content, and saves a fixed byte string (fake.pdfBytes).
import type { FakeSupabase } from '../harness';

function fake(): FakeSupabase {
  const f = (globalThis as { __edge?: { fake?: FakeSupabase } }).__edge?.fake;
  if (!f) throw new Error('edge harness not initialised: call loadHandler() first');
  return f;
}

export const StandardFonts = { Helvetica: 'Helvetica', HelveticaBold: 'Helvetica-Bold' };

export function rgb(r: number, g: number, b: number) {
  return { r, g, b };
}

export const PDFDocument = {
  async create() {
    const f = fake();
    f.pdfLines = [];
    return {
      addPage: (_size?: [number, number]) => ({
        drawText: (text: string) => {
          f.pdfLines.push(text);
        },
      }),
      embedFont: async (font: string) => font,
      save: async () => f.pdfBytes,
    };
  },
};
