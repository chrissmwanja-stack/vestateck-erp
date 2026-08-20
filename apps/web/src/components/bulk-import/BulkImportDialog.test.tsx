import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import BulkImportDialog, { type BulkImportConfig } from './BulkImportDialog';

// This sandbox's jsdom doesn't implement Blob.prototype.text (the real
// Chromium/Node one BulkImportDialog relies on via `await file.text()`).
// Polyfill it with FileReader, which jsdom does implement fully, so file
// uploads can actually be exercised here.
if (typeof Blob !== 'undefined' && !Blob.prototype.text) {
  Blob.prototype.text = function (this: Blob) {
    return new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(reader.error);
      reader.onload = () => resolve(String(reader.result));
      reader.readAsText(this);
    });
  };
}

const mockFrom = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
  },
}));

const mockUseAuth = vi.fn();
vi.mock('../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const mockParseCsv = vi.fn();
vi.mock('../../lib/csvParser', () => ({
  parseCsv: (...args: unknown[]) => mockParseCsv(...args),
}));

// Not exercised by any test here (all uploads use .csv filenames), but
// BulkImportDialog imports it unconditionally, and the real xlsxParser
// pulls in the `xlsx` package -- mock it out so this file doesn't need
// that dependency installed to run.
vi.mock('../../lib/xlsxParser', () => ({
  parseXlsx: vi.fn(),
}));

// Real config shape modeled on ImportLeads' bulkImportConfig, trimmed to
// the columns that exercise each validation path (required, enum,
// lookup, dedupe) without the noise of the full BD leads column set.
const config: BulkImportConfig = {
  table: 'bd_leads' as BulkImportConfig['table'],
  entityLabel: 'Leads',
  dedupeColumn: 'email',
  columns: [
    { key: 'company_name', label: 'Company', required: true },
    { key: 'email', label: 'Email' },
    { key: 'status', label: 'Status', enumValues: ['new', 'contacted', 'qualified'] },
  ],
  lookups: [{ csvColumn: 'source', table: 'bd_lead_sources' as BulkImportConfig['table'], matchColumn: 'name', payloadKey: 'source_id', label: 'Source' }],
  sampleRowValues: ['Acme Corp', 'john@acme.com', 'new', 'Referral'],
  buildPayload: (row, resolved, tenant_id) => ({
    tenant_id,
    company_name: row.company_name,
    email: row.email || null,
    status: row.status ? row.status.toLowerCase() : 'new',
    source_id: resolved.source_id || null,
  }),
};

/**
 * Wires the three supabase.from() targets BulkImportDialog actually hits:
 *   - lookup tables (config.lookups[].table) -- plain select, no chaining
 *   - "app_users" -- select().eq().single()
 *   - the import target (config.table) -- insert()
 */
function setupSupabase({
  lookupResults = { bd_lead_sources: { data: [{ id: 'src-1', name: 'Referral' }], error: null } } as Record<string, { data: unknown; error: unknown }>,
  appUserResult = { data: { tenant_id: 'tenant-1' }, error: null } as { data: { tenant_id: string } | null; error: unknown },
  insertImpl,
}: {
  lookupResults?: Record<string, { data: unknown; error: unknown }>;
  appUserResult?: { data: { tenant_id: string } | null; error: unknown };
  insertImpl?: (table: string, payload: Record<string, unknown>) => Promise<{ error: unknown }>;
} = {}) {
  const insertCalls: Array<{ table: string; payload: Record<string, unknown> }> = [];
  mockFrom.mockImplementation((table: string) => {
    if (table === 'app_users') {
      return { select: () => ({ eq: () => ({ single: () => Promise.resolve(appUserResult) }) }) };
    }
    if (table in lookupResults) {
      return { select: () => Promise.resolve(lookupResults[table]) };
    }
    return {
      insert: (payload: Record<string, unknown>) => {
        insertCalls.push({ table, payload });
        return insertImpl ? insertImpl(table, payload) : Promise.resolve({ error: null });
      },
    };
  });
  return { insertCalls };
}

function csvResult(rows: Record<string, string>[]) {
  return { headers: Object.keys(rows[0] ?? {}), rows, rowLineNumbers: rows.map((_, i) => i + 2) };
}

/** Uploads a file (content is irrelevant -- parseCsv is mocked). Dialog
 * content is portaled to document.body, so query baseElement, not the
 * plain render container. */
async function uploadFile(baseElement: HTMLElement, filename = 'leads.csv') {
  const input = baseElement.querySelector('input[type="file"]') as HTMLInputElement;
  const file = new File(['irrelevant, parseCsv is mocked'], filename, { type: 'text/csv' });
  fireEvent.change(input, { target: { files: [file] } });
}

beforeEach(() => {
  mockFrom.mockReset();
  mockParseCsv.mockReset();
  mockUseAuth.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } } });
});

describe('BulkImportDialog -- validation', () => {
  it('flags a missing required field and still counts the valid rows separately', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(
      csvResult([
        { company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Referral' },
        { company_name: '', email: 'b@beta.com', status: 'new', source: 'Referral' },
      ]),
    );

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());
    expect(screen.getByText('1 with errors')).toBeInTheDocument();
    expect(screen.getByText('Company is required')).toBeInTheDocument();
  });

  it('accepts an enum value case-insensitively', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'NEW', source: 'Referral' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());
    expect(screen.queryByText(/must be one of/)).not.toBeInTheDocument();
  });

  it('rejects an enum value outside the allowed set, listing the allowed values', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'bogus', source: 'Referral' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('1 with errors')).toBeInTheDocument());
    expect(screen.getByText('Status must be one of: new, contacted, qualified')).toBeInTheDocument();
  });

  it('resolves a lookup column against the preloaded table, case-insensitively and trimmed', async () => {
    const { insertCalls } = setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: '  referral  ' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);
    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Import 1 rows/ }));

    await waitFor(() => expect(insertCalls).toHaveLength(1));
    expect(insertCalls[0].payload).toMatchObject({ source_id: 'src-1' });
  });

  it('flags an unmatched lookup value instead of silently dropping it', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Cold Call' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('1 with errors')).toBeInTheDocument());
    expect(screen.getByText(/Source "Cold Call" not found/)).toBeInTheDocument();
  });

  it('flags a duplicate value in the dedupe column within the same file', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(
      csvResult([
        { company_name: 'Acme Corp', email: 'dup@acme.com', status: 'new', source: 'Referral' },
        { company_name: 'Acme Corp 2', email: 'DUP@acme.com', status: 'new', source: 'Referral' },
      ]),
    );

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());
    expect(screen.getByText('1 with errors')).toBeInTheDocument();
    expect(screen.getByText('Duplicate email within this file')).toBeInTheDocument();
  });

  it('shows a fatal error and no table when the file has no data rows', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('No data rows found in the file.')).toBeInTheDocument());
    expect(screen.queryByText(/ready to import/)).not.toBeInTheDocument();
  });

  it('surfaces a lookup table load failure as a fatal error and never gets to per-row validation', async () => {
    setupSupabase({ lookupResults: { bd_lead_sources: { data: null, error: { message: 'RLS denied' } } } });
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Referral' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('Could not load Source list: RLS denied')).toBeInTheDocument());
    expect(screen.queryByText(/ready to import/)).not.toBeInTheDocument();
  });
});

describe('BulkImportDialog -- import execution', () => {
  it('imports valid rows, stamping tenant_id from app_users and reporting per-row success', async () => {
    const { insertCalls } = setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Referral' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);
    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Import 1 rows/ }));

    await waitFor(() => expect(screen.getByText('Imported 1 of 1 rows.')).toBeInTheDocument());
    expect(insertCalls[0].payload).toMatchObject({ tenant_id: 'tenant-1', company_name: 'Acme Corp' });
  });

  it('reports invalid rows in the final tally too, without ever inserting them', async () => {
    const { insertCalls } = setupSupabase();
    mockParseCsv.mockReturnValue(
      csvResult([
        { company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Referral' },
        { company_name: '', email: 'b@beta.com', status: 'new', source: 'Referral' },
      ]),
    );

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);
    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Import 1 rows/ }));

    // Total tally covers the full 2-row file (1 inserted + 1 pre-validation
    // failure), even though only the valid row ever reaches insert().
    await waitFor(() => expect(screen.getByText('Imported 1 of 2 rows. 1 failed.')).toBeInTheDocument());
    expect(insertCalls).toHaveLength(1);
  });

  it('attributes a per-row insert failure to that row without aborting the rest of the batch', async () => {
    const { insertCalls } = setupSupabase({
      insertImpl: (_table, payload) =>
        payload.company_name === 'Bad Co' ? Promise.resolve({ error: { message: 'duplicate key' } }) : Promise.resolve({ error: null }),
    });
    mockParseCsv.mockReturnValue(
      csvResult([
        { company_name: 'Good Co', email: 'good@acme.com', status: 'new', source: 'Referral' },
        { company_name: 'Bad Co', email: 'bad@acme.com', status: 'new', source: 'Referral' },
      ]),
    );

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);
    await waitFor(() => expect(screen.getByText('2 ready to import')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Import 2 rows/ }));

    await waitFor(() => expect(screen.getByText('Imported 1 of 2 rows. 1 failed.')).toBeInTheDocument());
    expect(insertCalls).toHaveLength(2); // both rows were attempted -- one bad row doesn't block the other
    expect(screen.getByText('duplicate key')).toBeInTheDocument();
  });

  it('calls onImported once the batch finishes', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Referral' }]));
    const onImported = vi.fn();

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={onImported} config={config} />);
    await uploadFile(baseElement);
    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Import 1 rows/ }));

    await waitFor(() => expect(onImported).toHaveBeenCalledTimes(1));
  });

  it('blocks import with a session error when there is no session, and inserts nothing', async () => {
    mockUseAuth.mockReturnValue({ session: null });
    const { insertCalls } = setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Referral' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);
    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Import 1 rows/ }));

    await waitFor(() =>
      expect(screen.getByText('Could not determine your session. Please refresh and try again.')).toBeInTheDocument(),
    );
    expect(insertCalls).toHaveLength(0);
  });

  it('blocks import when the app_users tenant lookup fails, and inserts nothing', async () => {
    const { insertCalls } = setupSupabase({ appUserResult: { data: null, error: { message: 'not found' } } });
    mockParseCsv.mockReturnValue(csvResult([{ company_name: 'Acme Corp', email: 'a@acme.com', status: 'new', source: 'Referral' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);
    await waitFor(() => expect(screen.getByText('1 ready to import')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Import 1 rows/ }));

    await waitFor(() =>
      expect(screen.getByText('Could not determine your organization. Please refresh and try again.')).toBeInTheDocument(),
    );
    expect(insertCalls).toHaveLength(0);
  });
});

describe('BulkImportDialog -- import button state', () => {
  it('disables the import button when every row is invalid', async () => {
    setupSupabase();
    mockParseCsv.mockReturnValue(csvResult([{ company_name: '', email: 'a@acme.com', status: 'new', source: 'Referral' }]));

    const { baseElement } = render(<BulkImportDialog open onClose={() => {}} onImported={() => {}} config={config} />);
    await uploadFile(baseElement);

    await waitFor(() => expect(screen.getByText('1 with errors')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /Import 0 rows/ })).toBeDisabled();
  });
});