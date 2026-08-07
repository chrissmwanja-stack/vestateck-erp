declare module "https://deno.land/std@0.224.0/http/server.ts" {
  export function serve(handler: (req: Request) => Response | Promise<Response>): void;
}

declare module "https://esm.sh/@supabase/supabase-js@2.45.0" {
  export function createClient(url: string, key: string, options?: unknown): any;
}

declare module "https://esm.sh/pdf-lib@1.17.1" {
  export const PDFDocument: {
    create(): Promise<any>;
  };
  export const StandardFonts: {
    Helvetica: string;
    HelveticaBold: string;
  };
  export function rgb(r: number, g: number, b: number): any;
}

declare const Deno: {
  env: {
    get(key: string): string | undefined;
  };
};
