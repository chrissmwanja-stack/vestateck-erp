import { useCallback, useEffect, useState } from 'react';
import {
  Button, Card, CardContent, Chip, CircularProgress, Stack,
  Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../../db';
import { useInsuranceAccess } from '../../access';
import { EmptyRow, ErrorBanner } from '../../shared';

// Claim document checklist (slice C1): missing -> provided -> verified.
// Members mark documents provided; only managers can verify.

interface DocRow {
  id: string;
  doc_type: string;
  status: 'missing' | 'provided' | 'verified';
  note: string | null;
  updated_at: string;
}

const COMMON_DOCS = ['policy_schedule', 'police_report', 'photos', 'third_party_details', 'repair_estimates', 'medical_report'];

export default function ClaimDocuments({ claimId }: { claimId: string }) {
  const { canManage } = useInsuranceAccess();
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [newType, setNewType] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setDocs(await rows<DocRow>(
        table('ins_claim_documents').select('*').eq('claim_id', claimId).order('doc_type')));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [claimId]);

  useEffect(() => { load(); }, [load]);

  const setStatus = async (docType: string, status: 'missing' | 'provided') => {
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_set_claim_document', { p_claim_id: claimId, p_doc_type: docType, p_status: status });
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const verify = async (docType: string) => {
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_verify_claim_document', { p_claim_id: claimId, p_doc_type: docType });
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const addType = async () => {
    if (!newType.trim()) return;
    await setStatus(newType.trim(), 'missing');
    setNewType('');
  };

  const statusColor = (s: string) => s === 'verified' ? 'success' : s === 'provided' ? 'info' : 'default';

  return (
    <Card sx={{ mt: 2 }}><CardContent>
      <Typography variant="subtitle1" gutterBottom>Document checklist</Typography>
      <ErrorBanner message={error} />
      {loading ? <CircularProgress size={20} /> : (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Document</TableCell><TableCell>Status</TableCell>
              <TableCell>Note</TableCell><TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {docs.length === 0 && <EmptyRow colSpan={4} text="No documents tracked yet." />}
            {docs.map((d) => (
              <TableRow key={d.id}>
                <TableCell>{d.doc_type}</TableCell>
                <TableCell><Chip size="small" label={d.status} color={statusColor(d.status)} /></TableCell>
                <TableCell>{d.note ?? '—'}</TableCell>
                <TableCell align="right">
                  <Stack direction="row" spacing={1} justifyContent="flex-end">
                    {d.status === 'missing' && (
                      <Button size="small" disabled={busy} onClick={() => setStatus(d.doc_type, 'provided')}>Mark provided</Button>
                    )}
                    {d.status === 'provided' && canManage && (
                      <Button size="small" variant="outlined" disabled={busy} onClick={() => verify(d.doc_type)}>Verify</Button>
                    )}
                  </Stack>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
      <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
        <TextField size="small" label="Add document type" value={newType} onChange={(e) => setNewType(e.target.value)} />
        <Button size="small" variant="outlined" disabled={busy || !newType.trim()} onClick={addType}>Add</Button>
        {COMMON_DOCS.filter((c) => !docs.some((d) => d.doc_type === c)).map((c) => (
          <Chip key={c} size="small" label={'+ ' + c} onClick={() => setStatus(c, 'missing')} />
        ))}
      </Stack>
    </CardContent></Card>
  );
}
