import { useEffect, useRef, useState } from 'react';
import { Button, CircularProgress, Stack, Table, TableBody, TableCell, TableHead, TableRow, Typography } from '@mui/material';
import { errorText, rows, rpc, table } from '../../db';
import { supabase } from '../../../../../lib/supabaseClient';
import { ErrorBanner } from '../../shared';

// The document store on a policy: the generated document pack (debit notes,
// risk notes, renewal notices) and hand-uploaded attachments share one
// registry (documents) and one private bucket (tenant-documents). Reads are
// gated server-side (same tenant + insurance/finance/PO role); uploads here
// are manager-only, the server re-checks everything anyway.

export interface StoredDocument {
  id: string;
  doc_kind: string;
  file_name: string;
  path: string;
  byte_size: number;
  created_at: string;
}

const BUCKET = 'tenant-documents';

async function fileBytes(file: File): Promise<ArrayBuffer> {
  if (typeof file.arrayBuffer === 'function') return file.arrayBuffer();
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as ArrayBuffer);
    reader.onerror = () => reject(reader.error ?? new Error('Could not read the file.'));
    reader.readAsArrayBuffer(file);
  });
}

async function sha256Hex(file: File): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', await fileBytes(file));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function formatSize(bytes: number): string {
  return bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} KB`;
}

// Documents come from two sources: the pack (a template version) and plain
// attachments. The kind tells them apart on screen.
const KIND_LABEL: Record<string, string> = {
  attachment: 'Attachment',
  client_debit_note: 'Client debit note',
  insurer_debit_note: 'Insurer debit note',
  risk_note: 'Risk note',
  renewal_notice: 'Renewal notice',
};

export default function PolicyDocumentsCard({ policyId, canManage }: { policyId: string; canManage: boolean }) {
  const [docs, setDocs] = useState<StoredDocument[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  const load = async () => {
    try {
      setDocs(await rows<StoredDocument>(
        table('documents').select('id, doc_kind, file_name, path, byte_size, created_at')
          .eq('entity_type', 'insurance_policy').eq('entity_id', policyId)
          .order('created_at', { ascending: false }).order('id'),
      ));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { void load(); /* eslint-disable-line react-hooks/exhaustive-deps */ }, [policyId]);

  const download = async (doc: StoredDocument) => {
    setError(null);
    try {
      const { data, error: signError } = await supabase.storage.from(BUCKET).createSignedUrl(doc.path, 300);
      if (signError || !data) throw new Error(signError?.message ?? 'Could not create a download link.');
      window.open(data.signedUrl, '_blank');
    } catch (e) {
      setError(errorText(e));
    }
  };

  const upload = async (file: File) => {
    setBusy(true);
    setError(null);
    try {
      const { data: tenantId, error: tenantError } = await supabase.rpc('get_my_tenant_id');
      if (tenantError || !tenantId) throw new Error('Could not resolve the tenant for the storage path.');
      const hash = await sha256Hex(file);
      const path = `${tenantId}/insurance/insurance_policy/${policyId}/${Date.now()}-${file.name}`;
      const { error: uploadError } = await supabase.storage.from(BUCKET).upload(path, file, {
        upsert: false,
        contentType: file.type || 'application/octet-stream',
      });
      // Storage errors are plain objects, not Errors: wrap so the message survives.
      if (uploadError) throw new Error(uploadError.message);
      try {
        await rpc<StoredDocument>('documents_register', {
          p_entity_type: 'insurance_policy',
          p_entity_id: policyId,
          p_bucket: BUCKET,
          p_path: path,
          p_file_name: file.name,
          p_content_hash: hash,
          p_byte_size: file.size,
          p_mime_type: file.type || 'application/octet-stream',
          p_doc_kind: 'attachment',
        });
      } catch (registerError) {
        // The registry refused the row (tenant folder, hash, size): remove the
        // orphan so storage and the registry cannot drift apart.
        await supabase.storage.from(BUCKET).remove([path]);
        throw registerError;
      }
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
      if (fileInput.current) fileInput.current.value = '';
    }
  };

  return (
    <Stack spacing={1} sx={{ mt: 3 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center">
        <Typography variant="h6">Documents</Typography>
        {canManage && (
          <>
            <input
              type="file"
              ref={fileInput}
              hidden
              onChange={(e) => { const f = e.target.files?.[0]; if (f) void upload(f); }}
            />
            <Button variant="outlined" disabled={busy} onClick={() => fileInput.current?.click()}>
              {busy ? 'Uploading…' : 'Attach file'}
            </Button>
          </>
        )}
      </Stack>
      <ErrorBanner message={error} />
      {loading ? (
        <CircularProgress size={24} sx={{ mx: 'auto', my: 2 }} />
      ) : docs.length === 0 ? (
        <Typography variant="body2" color="text.secondary">
          No documents yet. Generated debit notes, risk notes and renewal notices will appear here,
          alongside any files attached to the policy.
        </Typography>
      ) : (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>File</TableCell>
              <TableCell>Type</TableCell>
              <TableCell>Size</TableCell>
              <TableCell>Added</TableCell>
              <TableCell />
            </TableRow>
          </TableHead>
          <TableBody>
            {docs.map((d) => (
              <TableRow key={d.id}>
                <TableCell>{d.file_name}</TableCell>
                <TableCell>{KIND_LABEL[d.doc_kind] ?? d.doc_kind}</TableCell>
                <TableCell>{formatSize(d.byte_size)}</TableCell>
                <TableCell>{new Date(d.created_at).toLocaleDateString()}</TableCell>
                <TableCell align="right">
                  <Button size="small" onClick={() => void download(d)}>Download</Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </Stack>
  );
}
