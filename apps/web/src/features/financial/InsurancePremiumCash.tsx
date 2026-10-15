import { useCallback, useEffect, useRef, useState } from 'react';
import { Alert, Box, Button, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography } from '@mui/material';
import { useSearchParams } from 'react-router-dom';
import { errorText, rpc } from '../../modules/portals/insurance/db';
import type { PolicyCashPolicy } from '../../modules/portals/insurance/policyCash';
import PolicyCashPanel from '../../modules/portals/insurance/pages/policies/PolicyCashPanel';

/** Finance route: does not require an Insurance staff role. RPCs are Finance-only. */
export default function InsurancePremiumCash() {
  const [params, setParams] = useSearchParams();
  const selected = params.get('policy') ?? '';
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState('');
  const [offset, setOffset] = useState(0);
  const [policies, setPolicies] = useState<PolicyCashPolicy[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const generation = useRef(0);
  const load = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true);
    try {
      const list = await rpc<PolicyCashPolicy[]>('ins_policy_cash_policies', { p_search: filter, p_offset: offset });
      if (current !== generation.current) return;
      setPolicies(list); setError(null);
    } catch (e) { if (current === generation.current) { setPolicies([]); setError(errorText(e)); } }
    finally { if (current === generation.current) setLoading(false); }
  }, [filter, offset]);
  useEffect(() => { void load(); return () => { generation.current++; }; }, [load]);

  return <Box sx={{ p: 3 }}>
    <Typography variant="h5" gutterBottom>Insurance premium cash</Typography>
    <Typography sx={{ mb: 2 }}>Prepare premium receipts and insurer remittances, or review another Finance user's pending requests. Insurance staff can view status from the policy; they cannot post cash through Insurance permissions.</Typography>
    {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
    <Stack direction="row" spacing={1} component="form" onSubmit={(e) => { e.preventDefault(); setOffset(0); setFilter(search); }}>
      <TextField size="small" label="Find policy, client or insurer" value={search} onChange={(e) => setSearch(e.target.value)} />
      <Button type="submit" disabled={loading}>Search</Button><Button onClick={() => void load()} disabled={loading}>Refresh policies</Button>
    </Stack>
    <Box sx={{ overflowX: 'auto' }}><Table size="small" aria-label="Premium cash policies">
      <TableHead><TableRow><TableCell>Policy</TableCell><TableCell>Client</TableCell><TableCell>Insurer</TableCell><TableCell>Status</TableCell><TableCell /></TableRow></TableHead>
      <TableBody>{policies.map((p) => <TableRow key={p.id} selected={selected === p.id}>
        <TableCell>{p.policy_no}</TableCell><TableCell>{p.client_name}</TableCell><TableCell>{p.insurer_name}</TableCell><TableCell>{p.status}</TableCell>
        <TableCell><Button onClick={() => setParams({ policy: p.id })}>View cash workflow</Button></TableCell>
      </TableRow>)}{!loading && policies.length === 0 && <TableRow><TableCell colSpan={5}>No bound policies found.</TableCell></TableRow>}</TableBody>
    </Table></Box>
    <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
      <Button disabled={loading || offset === 0} onClick={() => setOffset((v) => Math.max(v - 50, 0))}>Previous</Button>
      <Button disabled={loading || policies.length < 50} onClick={() => setOffset((v) => v + 50)}>Next</Button>
    </Stack>
    {selected ? <PolicyCashPanel key={selected} policyId={selected} mode="finance" /> : <Alert severity="info" sx={{ mt: 2 }}>Select a policy to prepare cash or review pending approvals.</Alert>}
  </Box>;
}
