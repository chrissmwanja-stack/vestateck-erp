import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyDocumentsCard from './PolicyDocumentsCard';

// The document store on a policy: lists the registry rows, downloads through a
// signed URL, and uploads a file (hash -> storage -> documents_register), with
// an orphan cleanup if the registry refuses the row.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
const mockUpload = vi.fn();
const mockSignedUrl = vi.fn();
const mockRemove = vi.fn();
const mockInvoke = vi.fn();

vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
    functions: { invoke: (...args: unknown[]) => mockInvoke(...args) },
    storage: {
      from: (_bucket: string) => ({ upload: mockUpload, createSignedUrl: mockSignedUrl, remove: mockRemove }),
    },
  },
}));

function builder(result: () => { data: unknown; error: { message: string } | null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

let docs: { id: string; doc_kind: string; file_name: string; path: string; byte_size: number; created_at: string }[] = [];

beforeEach(() => {
  vi.stubGlobal('open', vi.fn());
  // jsdom has no WebCrypto; the card only needs 32 bytes it can hex-encode.
  vi.stubGlobal('crypto', { subtle: { digest: vi.fn(async () => new ArrayBuffer(32)) } });
  docs = [];
  mockFrom.mockReset();
  mockFrom.mockImplementation(() => builder(() => ({ data: docs, error: null })));
  mockRpc.mockReset();
  mockRpc.mockImplementation((fn: string) => {
    if (fn === 'get_my_tenant_id') return Promise.resolve({ data: 'tenant-1', error: null });
    if (fn === 'documents_register') return Promise.resolve({ data: { id: 'd2' }, error: null });
    return Promise.resolve({ data: null, error: null });
  });
  mockUpload.mockReset();
  mockUpload.mockResolvedValue({ data: { path: 'p' }, error: null });
  mockSignedUrl.mockReset();
  mockRemove.mockReset();
  mockRemove.mockResolvedValue({ data: null, error: null });
  mockInvoke.mockReset();
  mockInvoke.mockResolvedValue({ data: { id: 'd9', kind: 'client_debit_note', path: 'p' }, error: null });
});

describe('PolicyDocumentsCard', () => {
  it('shows the empty state and hides the upload button from non-managers', async () => {
    render(<PolicyDocumentsCard policyId="p1" canManage={false} />);
    expect(await screen.findByText(/no documents yet/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /attach file/i })).not.toBeInTheDocument();
  });

  it('lists registered documents with a friendly kind label and a download link', async () => {
    docs = [{ id: 'd1', doc_kind: 'client_debit_note', file_name: 'debit-note.pdf', path: 'tenant-1/x.pdf', byte_size: 2048, created_at: '2026-10-21T08:00:00Z' }];
    render(<PolicyDocumentsCard policyId="p1" canManage={false} />);
    expect(await screen.findByText('debit-note.pdf')).toBeInTheDocument();
    expect(screen.getByText('Client debit note')).toBeInTheDocument();
    expect(screen.getByText('2.0 KB')).toBeInTheDocument();

    mockSignedUrl.mockResolvedValue({ data: { signedUrl: 'https://signed.example/x' }, error: null });
    await userEvent.click(screen.getByRole('button', { name: /download/i }));
    await waitFor(() => expect(mockSignedUrl).toHaveBeenCalledWith('tenant-1/x.pdf', 300));
  });

  it('uploads: hashes the file, stores it under the tenant folder, registers it, then reloads', async () => {
    const { container } = render(<PolicyDocumentsCard policyId="p1" canManage />);
    await screen.findByText(/no documents yet/i);
    const file = new File(['hello policy'], 'wording.pdf', { type: 'application/pdf' });
    fireEvent.change(container.querySelector('input[type=file]') as HTMLElement, { target: { files: [file] } });

    await waitFor(() => expect(mockUpload).toHaveBeenCalled());
    const [path, blob, opts] = mockUpload.mock.calls[0];
    expect(path).toEqual(expect.stringMatching(/^tenant-1\/insurance\/insurance_policy\/p1\/\d+-wording\.pdf$/));
    expect((blob as File).name).toBe('wording.pdf');
    expect((opts as { contentType: string }).contentType).toBe('application/pdf');
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('documents_register', expect.objectContaining({
      p_entity_type: 'insurance_policy',
      p_entity_id: 'p1',
      p_bucket: 'tenant-documents',
      p_file_name: 'wording.pdf',
      p_byte_size: 12,
      p_doc_kind: 'attachment',
    })));
    // sha-256 of "hello policy"
    const hash = (mockRpc.mock.calls.find((c) => c[0] === 'documents_register') as unknown[])[1] as { p_content_hash: string };
    expect(hash.p_content_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it('removes the stored blob when the registry refuses the row, and shows the error', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'get_my_tenant_id') return Promise.resolve({ data: 'tenant-1', error: null });
      if (fn === 'documents_register') return Promise.resolve({ data: null, error: { message: 'DOCUMENTS_PATH: path must live in the caller tenant folder' } });
      return Promise.resolve({ data: null, error: null });
    });
    const { container } = render(<PolicyDocumentsCard policyId="p1" canManage />);
    await screen.findByText(/no documents yet/i);
    fireEvent.change(container.querySelector('input[type=file]') as HTMLElement, { target: { files: [new File(['x'], 'bad.pdf', { type: 'application/pdf' })] } });

    await waitFor(() => expect(mockRemove).toHaveBeenCalledWith([expect.stringMatching(/bad\.pdf$/)]));
    expect(await screen.findByText(/path must live in the caller tenant folder/i)).toBeInTheDocument();
  });

  it('surfaces a storage upload failure without calling the registry', async () => {
    mockUpload.mockResolvedValue({ data: null, error: { message: 'storage bucket not found' } });
    const { container } = render(<PolicyDocumentsCard policyId="p1" canManage />);
    await screen.findByText(/no documents yet/i);
    fireEvent.change(container.querySelector('input[type=file]') as HTMLElement, { target: { files: [new File(['x'], 'x.pdf', { type: 'application/pdf' })] } });

    expect(await screen.findByText(/storage bucket not found/i)).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalledWith('documents_register', expect.anything());
    expect(mockRemove).not.toHaveBeenCalled();
  });
});

describe('PolicyDocumentsCard generation', () => {
  it('offers the pack only to managers, and invokes the function with the policy and kind', async () => {
    const noManager = render(<PolicyDocumentsCard policyId="p1" canManage={false} />);
    expect(await noManager.findByText(/no documents yet/i)).toBeInTheDocument();
    expect(noManager.queryByRole('button', { name: /client debit note/i })).not.toBeInTheDocument();
    noManager.unmount();

    const { container } = render(<PolicyDocumentsCard policyId="p1" canManage />);
    await screen.findByText(/no documents yet/i);
    await userEvent.click(screen.getByRole('button', { name: /client debit note/i }));
    await waitFor(() => expect(mockInvoke).toHaveBeenCalledWith('generate-ins-doc', {
      body: { policy_id: 'p1', kind: 'client_debit_note' },
    }));
    // the registry is re-read after generation
    await waitFor(() => expect(mockFrom.mock.calls.filter(([t]) => t === 'documents').length).toBeGreaterThan(1));
    void container;
  });

  it('surfaces the function error detail from the response body', async () => {
    // functions.invoke resolves with a FunctionsHttpError whose .context holds the response body.
    mockInvoke.mockResolvedValue({
      data: null,
      error: { message: 'FunctionsHttpError', context: { clone: () => ({ json: async () => ({ error: 'You are not authorized to document this policy' }) }) } },
    });
    render(<PolicyDocumentsCard policyId="p1" canManage />);
    await screen.findByText(/no documents yet/i);
    await userEvent.click(screen.getByRole('button', { name: /renewal notice/i }));
    expect(await screen.findByText(/not authorized to document this policy/i)).toBeInTheDocument();
  });

  it('keeps the pack disabled while another document is generating', async () => {
    let resolveFn: (v: unknown) => void = () => {};
    mockInvoke.mockReturnValue(new Promise((resolve) => { resolveFn = resolve; }));
    render(<PolicyDocumentsCard policyId="p1" canManage />);
    await screen.findByText(/no documents yet/i);
    await userEvent.click(screen.getByRole('button', { name: /risk note/i }));
    await waitFor(() => expect(screen.getByRole('button', { name: /generating/i })).toBeDisabled());
    resolveFn({ data: { id: 'd9' }, error: null });
    await waitFor(() => expect(screen.getByRole('button', { name: /^risk note$/i })).toBeEnabled());
  });
});