import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Checkbox,
  FormControlLabel,
  MenuItem,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../../db';
import {
  configurationProblems,
  type FinancialDetails,
  type InsurerShare,
  type PolicyCharge,
} from '../../financialConfiguration';
import { formatMoney } from '../../logic';
import {
  exportReportToExcel,
  exportReportToPdf,
  type ReportExportColumn,
} from '../../../../../lib/reportExport';

interface Props {
  policyId: string;
  onChanged: () => void | Promise<void>;
  onDirtyChange?: (dirty: boolean) => void;
  onDetails?: (details: FinancialDetails) => void;
}
interface InvoiceLine {
  description: string;
  recipient: string;
  base: number;
  vat: string;
  total: number;
}
export default function PolicyFinancialConfiguration({
  policyId,
  onChanged,
  onDirtyChange,
  onDetails,
}: Props) {
  const [details, setDetails] = useState<FinancialDetails | null>(null);
  const [shares, setShares] = useState<InsurerShare[]>([]);
  const [charges, setCharges] = useState<PolicyCharge[]>([]);
  const [insurers, setInsurers] = useState<{ id: string; name: string }[]>([]);
  const [incomeAccounts, setIncomeAccounts] = useState<
    { id: string; account_code: string; name: string }[]
  >([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [dirty, setDirty] = useState(false);
  const load = useCallback(async () => {
    const d = await rpc<FinancialDetails>('ins_policy_financial_details', {
      p_policy_id: policyId,
    });
    if (!d || !Array.isArray(d.shares) || !Array.isArray(d.charges)) return;
    setDetails(d);
    setShares(d.shares);
    setCharges(d.charges);
    setDirty(false);
    if (d.status === 'draft' && d.can_configure) {
      setInsurers(
        await rows<{ id: string; name: string }>(
          table('ins_insurers')
            .select('id,name')
            .eq('is_active', true)
            .order('name'),
        ),
      );
      setIncomeAccounts(
        await rpc<{ id: string; account_code: string; name: string }[]>(
          'ins_policy_charge_income_accounts',
        ),
      );
    }
  }, [policyId]);
  useEffect(() => {
    void load().catch((e) => setError(errorText(e)));
  }, [load]);
  useEffect(() => {
    onDirtyChange?.(dirty);
  }, [dirty, onDirtyChange]);
  useEffect(() => {
    if (details) onDetails?.(details);
  }, [details, onDetails]);
  const editShare = (index: number, change: Partial<InsurerShare>) => {
    setDirty(true);
    setShares((all) =>
      all.map((s, i) => (i === index ? { ...s, ...change } : s)),
    );
  };
  const editCharge = (index: number, change: Partial<PolicyCharge>) => {
    setDirty(true);
    setCharges((all) =>
      all.map((c, i) => (i === index ? { ...c, ...change } : c)),
    );
  };
  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_set_policy_financial_configuration', {
        p_policy_id: policyId,
        p_shares: shares,
        p_charges: charges,
      });
      await load();
      await onChanged();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  if (!details)
    return (
      <Box sx={{ mt: 2 }}>
        {error && (
          <Alert severity="error">
            {error}
            <Button
              onClick={() => void load().catch((e) => setError(errorText(e)))}
            >
              Retry financial details
            </Button>
          </Alert>
        )}
      </Box>
    );
  const editable = details.status === 'draft' && details.can_configure;
  const problems = configurationProblems(shares, charges);
  const money = (n: number | null | undefined) =>
    n == null ? '—' : formatMoney(n, details.currency);
  const name = (id: string | null) =>
    shares.find((s) => s.insurer_id === id)?.insurer_name ||
    insurers.find((s) => s.id === id)?.name ||
    id ||
    'All insurers by share';
  const invoiceLines: InvoiceLine[] = [
    {
      description: 'Policy premium (after discounts/loadings)',
      recipient: 'Participating insurers',
      base: details.gross_premium,
      vat: 'Premium tax treatment outside broker-fee VAT option',
      total: details.gross_premium,
    },
    ...charges.map((c) => ({
      description: c.description,
      recipient:
        c.kind === 'broker_fee' ? 'Broker' : name(c.recipient_insurer_id),
      base: c.amount ?? 0,
      vat:
        c.vat_mode === 'exclusive'
          ? `${c.vat_rate_pct}%: ${money(c.vat_amount)}`
          : 'VAT not calculated — not an exemption declaration',
      total: Number(c.amount ?? 0) + Number(c.vat_amount ?? 0),
    })),
  ];
  const invoiceColumns: ReportExportColumn<InvoiceLine>[] = [
    { header: 'Description', accessor: (r) => r.description },
    { header: 'Recipient', accessor: (r) => r.recipient },
    { header: 'Base amount', accessor: (r) => r.base, align: 'right' },
    { header: 'VAT treatment', accessor: (r) => r.vat },
    { header: 'Line total', accessor: (r) => r.total, align: 'right' },
  ];
  return (
    <Card variant="outlined" sx={{ mt: 3 }}>
      <CardContent>
        <Typography variant="h6">Insurer shares & policy charges</Typography>
        <Alert severity="info" sx={{ my: 1 }}>
          Claims remain lead-insurer-based in v1; per-insurer claim
          contributions are not supported. Shares and charge amounts become
          immutable at bind. Renewals require fresh review and new charge
          amounts.
        </Alert>
        {error && <Alert severity="error">{error}</Alert>}
        {dirty && (
          <Alert severity="warning">
            Unsaved configuration is not used when binding. Save and review it
            first.
          </Alert>
        )}
        {editable && (
          <Typography variant="body2" sx={{ my: 1 }}>
            Leave both lists empty to keep the existing single-insurer workflow.
            Charges require explicit insurer allocation. Premium must already
            include any discounts or loadings.
          </Typography>
        )}
        <Box sx={{ overflowX: 'auto' }}>
          <Table size="small" aria-label="Insurer financial shares">
            <TableHead>
              <TableRow>
                <TableCell>Insurer / lead</TableCell>
                <TableCell>Share % / commission %</TableCell>
                <TableCell>Insurer policy no.</TableCell>
                <TableCell>Allocated premium / pass-through</TableCell>
                <TableCell>Commission / payable</TableCell>
                <TableCell>Review</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {shares.map((s, i) => (
                <TableRow key={s.id || i}>
                  <TableCell>
                    {editable ? (
                      <>
                        <TextField
                          select
                          size="small"
                          label={`Insurer ${i + 1}`}
                          value={s.insurer_id}
                          onChange={(e) =>
                            editShare(i, { insurer_id: e.target.value })
                          }
                          sx={{ minWidth: 160 }}
                          disabled={busy}
                        >
                          {insurers.map((ins) => (
                            <MenuItem key={ins.id} value={ins.id}>
                              {ins.name}
                            </MenuItem>
                          ))}
                        </TextField>
                        <FormControlLabel
                          label="Lead"
                          control={
                            <Checkbox
                              checked={s.is_lead}
                              disabled={busy}
                              onChange={() => {
                                setDirty(true);
                                setShares(
                                  shares.map((x, j) => ({
                                    ...x,
                                    is_lead: j === i,
                                  })),
                                );
                              }}
                            />
                          }
                        />
                      </>
                    ) : (
                      `${s.insurer_name || s.insurer_id}${s.is_lead ? ' (lead)' : ''}`
                    )}
                  </TableCell>
                  <TableCell>
                    {editable ? (
                      <Stack spacing={1}>
                        <TextField
                          size="small"
                          type="number"
                          label="Share %"
                          value={s.share_pct}
                          disabled={busy}
                          onChange={(e) =>
                            editShare(i, { share_pct: Number(e.target.value) })
                          }
                        />
                        <TextField
                          size="small"
                          type="number"
                          label="Commission %"
                          value={s.commission_rate_pct}
                          disabled={busy}
                          onChange={(e) =>
                            editShare(i, {
                              commission_rate_pct: Number(e.target.value),
                            })
                          }
                        />
                      </Stack>
                    ) : (
                      `${s.share_pct}% / ${s.commission_rate_pct}%`
                    )}
                  </TableCell>
                  <TableCell>
                    {editable ? (
                      <TextField
                        size="small"
                        label="Insurer policy reference"
                        value={s.insurer_policy_no || ''}
                        disabled={busy}
                        onChange={(e) =>
                          editShare(i, { insurer_policy_no: e.target.value })
                        }
                      />
                    ) : (
                      s.insurer_policy_no || '—'
                    )}
                  </TableCell>
                  <TableCell>
                    {money(s.premium_amount)} / {money(s.pass_through_amount)}
                  </TableCell>
                  <TableCell>
                    {money(s.commission_amount)} / {money(s.payable_amount)}
                  </TableCell>
                  <TableCell>
                    {editable ? (
                      <>
                        <FormControlLabel
                          label="Reviewed"
                          control={
                            <Checkbox
                              checked={s.reviewed}
                              disabled={busy}
                              onChange={(e) =>
                                editShare(i, { reviewed: e.target.checked })
                              }
                            />
                          }
                        />
                        <Button
                          color="error"
                          disabled={busy}
                          onClick={() => {
                            setDirty(true);
                            setShares(shares.filter((_, j) => j !== i));
                          }}
                        >
                          Remove
                        </Button>
                      </>
                    ) : (
                      'Locked'
                    )}
                  </TableCell>
                </TableRow>
              ))}
              {!shares.length && (
                <TableRow>
                  <TableCell colSpan={6}>
                    Single insurer from policy header; existing accounting path.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </Box>
        {editable && (
          <Button
            disabled={busy}
            onClick={() => {
              setDirty(true);
              setShares([
                ...shares,
                {
                  insurer_id: '',
                  is_lead: shares.length === 0,
                  share_pct: shares.length === 0 ? 100 : 0,
                  commission_rate_pct: 0,
                  insurer_policy_no: null,
                  reviewed: false,
                },
              ]);
            }}
          >
            Add insurer share
          </Button>
        )}
        <Typography variant="subtitle1" sx={{ mt: 2 }}>
          Charge lines
        </Typography>
        {charges.map((c, i) => (
          <Box
            key={c.id || i}
            sx={{
              p: 2,
              my: 1,
              border: '1px solid',
              borderColor: 'divider',
              borderRadius: 1,
            }}
          >
            {editable ? (
              <Stack spacing={1}>
                <Stack direction="row" spacing={1}>
                  <TextField
                    select
                    size="small"
                    label="Charge type"
                    value={c.kind}
                    disabled={busy}
                    onChange={(e) =>
                      editCharge(i, {
                        kind: e.target.value as PolicyCharge['kind'],
                        recipient_mode:
                          e.target.value === 'broker_fee'
                            ? 'broker'
                            : 'all_insurers',
                        recipient_insurer_id: null,
                        vat_mode: 'not_calculated',
                        vat_rate_pct: null,
                      })
                    }
                  >
                    <MenuItem value="insurer_pass_through">
                      Insurer pass-through (non-commissionable)
                    </MenuItem>
                    <MenuItem value="broker_fee">
                      Broker fee (broker income)
                    </MenuItem>
                  </TextField>
                  <TextField
                    size="small"
                    label="Description"
                    value={c.description}
                    disabled={busy}
                    onChange={(e) =>
                      editCharge(i, { description: e.target.value })
                    }
                  />
                  <TextField
                    size="small"
                    type="number"
                    label="Current charge amount"
                    value={c.amount ?? ''}
                    disabled={busy}
                    onChange={(e) =>
                      editCharge(i, {
                        amount:
                          e.target.value === '' ? null : Number(e.target.value),
                      })
                    }
                  />
                </Stack>
                {c.kind === 'insurer_pass_through' ? (
                  <TextField
                    select
                    size="small"
                    label="Charge recipient"
                    value={
                      c.recipient_mode === 'all_insurers'
                        ? 'all'
                        : c.recipient_insurer_id || ''
                    }
                    disabled={busy}
                    onChange={(e) =>
                      editCharge(i, {
                        recipient_mode:
                          e.target.value === 'all'
                            ? 'all_insurers'
                            : 'one_insurer',
                        recipient_insurer_id:
                          e.target.value === 'all' ? null : e.target.value,
                      })
                    }
                  >
                    <MenuItem value="all">
                      All insurers, pro rata by share
                    </MenuItem>
                    {shares
                      .filter((s) => s.insurer_id)
                      .map((s) => (
                        <MenuItem key={s.insurer_id} value={s.insurer_id}>
                          {name(s.insurer_id)}
                        </MenuItem>
                      ))}
                  </TextField>
                ) : (
                  <>
                    <TextField
                      select
                      size="small"
                      label="Broker fee income GL account"
                      value={c.income_gl_account_id || ''}
                      disabled={busy}
                      onChange={(e) =>
                        editCharge(i, { income_gl_account_id: e.target.value })
                      }
                    >
                      {incomeAccounts.map((a) => (
                        <MenuItem key={a.id} value={a.id}>
                          {a.account_code} — {a.name}
                        </MenuItem>
                      ))}
                    </TextField>
                    <Stack direction="row" spacing={1}>
                      <TextField
                        select
                        size="small"
                        label="Broker fee VAT option"
                        value={c.vat_mode}
                        disabled={busy}
                        onChange={(e) =>
                          editCharge(i, {
                            vat_mode: e.target
                              .value as PolicyCharge['vat_mode'],
                            vat_rate_pct: null,
                          })
                        }
                      >
                        <MenuItem value="not_calculated">
                          VAT not calculated
                        </MenuItem>
                        <MenuItem value="exclusive">
                          Add VAT at specified rate
                        </MenuItem>
                      </TextField>
                      {c.vat_mode === 'exclusive' && (
                        <TextField
                          size="small"
                          type="number"
                          label="Applicable VAT rate %"
                          value={c.vat_rate_pct ?? ''}
                          disabled={busy}
                          onChange={(e) =>
                            editCharge(i, {
                              vat_rate_pct:
                                e.target.value === ''
                                  ? null
                                  : Number(e.target.value),
                            })
                          }
                        />
                      )}
                    </Stack>
                  </>
                )}
                <Stack direction="row">
                  <FormControlLabel
                    label="Charge and tax treatment reviewed"
                    control={
                      <Checkbox
                        checked={c.reviewed}
                        disabled={busy}
                        onChange={(e) =>
                          editCharge(i, { reviewed: e.target.checked })
                        }
                      />
                    }
                  />
                  <Button
                    color="error"
                    disabled={busy}
                    onClick={() => {
                      setDirty(true);
                      setCharges(charges.filter((_, j) => j !== i));
                    }}
                  >
                    Remove charge
                  </Button>
                </Stack>
              </Stack>
            ) : (
              <Typography>
                {c.description} · {money(c.amount)} ·{' '}
                {c.kind === 'broker_fee'
                  ? 'Broker fee'
                  : name(c.recipient_insurer_id)}{' '}
                ·{' '}
                {c.vat_mode === 'exclusive'
                  ? `VAT ${c.vat_rate_pct}%: ${money(c.vat_amount)}`
                  : 'VAT not calculated'}
              </Typography>
            )}
          </Box>
        ))}
        {editable && (
          <Button
            disabled={busy}
            onClick={() => {
              setDirty(true);
              setCharges([
                ...charges,
                {
                  kind: 'insurer_pass_through',
                  description: '',
                  amount: null,
                  recipient_mode: 'all_insurers',
                  recipient_insurer_id: null,
                  vat_mode: 'not_calculated',
                  vat_rate_pct: null,
                  income_gl_account_id: null,
                  reviewed: false,
                },
              ]);
            }}
          >
            Add charge line
          </Button>
        )}
        <Alert severity="warning" sx={{ my: 1 }}>
          VAT not calculated does not mean exempt. Confirm treatment and the
          selected income/tax accounts with your accountant and Ugandan tax
          adviser. No statutory VAT rate is assumed. Insurer pass-through
          amounts are entered as supplied by the insurer; separate tax payees
          and statutory levies are outside v1.
        </Alert>
        {editable && (
          <>
            {problems.map((e) => (
              <Typography color="error" key={e}>
                {e}
              </Typography>
            ))}
            <Button
              variant="contained"
              disabled={busy || !dirty || problems.length > 0}
              onClick={() => void save()}
            >
              Save financial configuration
            </Button>
          </>
        )}
        {details.snapshot && (
          <Box sx={{ mt: 2 }}>
            <Typography>
              Bound invoice total: {money(details.snapshot.invoice_total)} ·
              Broker fees: {money(details.snapshot.broker_fee_total)} · Fee VAT
              liability: {money(details.snapshot.vat_total)}
            </Typography>
            <Typography variant="caption">
              Immutable bind journal: {details.snapshot.journal_entry_id}. This
              is the broker's premium/charge statement, not an insurer-issued
              tax invoice.
            </Typography>
            <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
              <Button
                onClick={() =>
                  exportReportToPdf(
                    `premium-statement-${details.policy_no}`,
                    'Premium and charge statement',
                    invoiceColumns,
                    invoiceLines,
                    `${details.policy_no} · ${details.client_name} · ${details.currency} · Total ${money(details.snapshot?.invoice_total)}`,
                  )
                }
              >
                Export premium / charge statement PDF
              </Button>
              <Button
                onClick={() =>
                  exportReportToExcel(
                    `premium-statement-${details.policy_no}`,
                    'Premium and charges',
                    invoiceColumns,
                    invoiceLines,
                  )
                }
              >
                Export statement Excel
              </Button>
            </Stack>
          </Box>
        )}
      </CardContent>
    </Card>
  );
}
