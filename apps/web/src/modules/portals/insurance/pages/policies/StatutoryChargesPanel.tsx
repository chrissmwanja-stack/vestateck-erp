import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import { errorText, rpc } from '../../db';
import type { FinancialDetails } from '../../financialConfiguration';
import { statutoryLines, statutoryProblems } from '../../financialConfiguration';
import { formatMoney } from '../../logic';

interface Props {
  policyId: string;
  /** Called after a successful action so the policy page reloads its figures. */
  onChanged: () => void | Promise<void>;
  /** True while the draft's financial configuration has unsaved edits. */
  dirty?: boolean;
}

/**
 * Statutory charges on one policy: what the catalogue priced, whether the manager
 * has acknowledged it, and the two actions that change that.
 *
 * The figures come from the policy screen's existing
 * `ins_policy_financial_details` call (extended in 20261120010000), so this panel
 * fetches nothing of its own on load.
 *
 * Deliberately not behind a role check of its own: the two RPCs assert
 * `can_manage_insurance()`, and a disabled button with no explanation is worse than
 * a refusal that says why.
 */
export default function StatutoryChargesPanel({ policyId, onChanged, dirty }: Props) {
  const [details, setDetails] = useState<FinancialDetails | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [lastPriced, setLastPriced] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const d = await rpc<FinancialDetails>('ins_policy_financial_details', {
        p_policy_id: policyId,
      });
      if (!d) return;
      setDetails(d);
    } catch (e) {
      setError(errorText(e));
    }
  }, [policyId]);

  useEffect(() => {
    void load();
  }, [load]);

  const isDraft = details?.status === 'draft';
  const lines = statutoryLines(details?.charges ?? []);
  const problems = details ? statutoryProblems(details) : [];
  const enforcement = details?.statutory?.enforcement ?? details?.enforcement ?? 'advisory';
  const acknowledged = Boolean(details?.statutory?.acknowledged);
  const pricedTotal = details?.statutory?.priced_total ?? 0;
  const ackTotal = details?.statutory?.acknowledged_total ?? null;

  async function run(action: 'price' | 'acknowledge') {
    setError(null);
    setBusy(true);
    setLastPriced(null);
    try {
      if (action === 'price') {
        const out = await rpc<{ total: number; lines: unknown[] }>(
          'ins_apply_statutory_charges',
          { p_policy_id: policyId },
        );
        setLastPriced(
          out ? `Priced ${out.lines?.length ?? 0} charge(s) totalling ${out.total}` : 'Priced.',
        );
      } else {
        await rpc('ins_acknowledge_statutory_charges', { p_policy_id: policyId });
        setLastPriced('Acknowledged.');
      }
      await load();
      await onChanged();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  if (!details) {
    return error ? (
      <Alert severity="error" sx={{ mt: 3 }}>
        {error}
      </Alert>
    ) : null;
  }

  // Nothing priced, nothing to acknowledge, enforcement off: the panel is noise.
  // Hiding it is not the same as hiding a problem -- `problems` is empty in exactly
  // this case, because bind will not be refused.
  if (lines.length === 0 && !pricedTotal && enforcement !== 'required' && !isDraft) {
    return null;
  }

  return (
    <Box sx={{ mt: 3 }}>
      <Stack direction="row" alignItems="center" spacing={1} sx={{ mb: 1 }}>
        <Typography variant="h6">Statutory charges</Typography>
        <Chip
          size="small"
          label={enforcement === 'required' ? 'Enforcement on' : 'Advisory'}
          color={enforcement === 'required' ? 'warning' : 'default'}
          variant="outlined"
        />
        {acknowledged ? (
          <Chip size="small" color="success" label="Acknowledged" />
        ) : pricedTotal > 0 ? (
          <Chip size="small" color="warning" label="Not acknowledged" />
        ) : (
          <Chip size="small" label="Not priced" />
        )}
      </Stack>

      <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
        These are levies and taxes collected on the policy on behalf of a third party. They are
        not the brokerage&apos;s income, and they carry no brokerage VAT.
        {enforcement === 'required'
          ? ' This company requires them to be priced and acknowledged before a policy can bind.'
          : ' This company does not refuse a bind for want of them.'}
      </Typography>

      <Card variant="outlined">
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Charge</TableCell>
                <TableCell>Class</TableCell>
                <TableCell>Recipient</TableCell>
                <TableCell>Version</TableCell>
                <TableCell align="right">Amount</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {lines.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5}>
                    <Typography variant="body2" color="text.secondary" sx={{ py: 1 }}>
                      No statutory charges priced for this policy.
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                lines.map((c) => (
                  <TableRow key={c.id ?? c.description}>
                    <TableCell>{c.description}</TableCell>
                    <TableCell>
                      <Typography variant="caption" color="text.secondary">
                        {(c.charge_class ?? '').replace(/_/g, ' ')}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="caption">{c.recipient_name ?? '—'}</Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="caption" sx={{ fontFamily: 'monospace' }}>
                        {c.catalogue_version ?? '—'}
                      </Typography>
                    </TableCell>
                    <TableCell align="right">
                      {formatMoney(Number(c.amount ?? 0), details.currency)}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Stack direction="row" spacing={2} sx={{ mt: 1 }} alignItems="center">
        <Typography variant="body2">
          Total billed: <strong>{formatMoney(pricedTotal, details.currency)}</strong>
          {ackTotal !== null && ackTotal !== pricedTotal && (
            <> · acknowledged {formatMoney(ackTotal, details.currency)}</>
          )}
        </Typography>
      </Stack>

      {problems.length > 0 && (
        <Alert severity="warning" sx={{ mt: 1 }}>
          {problems.map((p) => (
            <div key={p}>{p}</div>
          ))}
        </Alert>
      )}

      {dirty && (
        <Alert severity="info" sx={{ mt: 1 }}>
          Save the financial configuration first. Pricing reads the premium and shares as they are
          stored, not as they appear on screen.
        </Alert>
      )}

      {error && (
        <Alert severity="error" sx={{ mt: 1 }}>
          {error}
        </Alert>
      )}
      {lastPriced && !error && (
        <Alert severity="success" sx={{ mt: 1 }}>
          {lastPriced}
        </Alert>
      )}

      {isDraft && (
        <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
          <Button
            variant="outlined"
            size="small"
            disabled={busy || dirty}
            onClick={() => void run('price')}
          >
            Price statutory charges
          </Button>
          <Button
            variant="contained"
            size="small"
            disabled={busy || dirty || pricedTotal <= 0}
            onClick={() => void run('acknowledge')}
          >
            Acknowledge
          </Button>
        </Stack>
      )}
    </Box>
  );
}
