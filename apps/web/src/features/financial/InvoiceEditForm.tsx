import { FormEvent } from "react";
import { Alert, Autocomplete, Box, Button, Card, CardContent, CircularProgress, MenuItem, Stack, TextField, Typography } from "@mui/material";
import type { UnifiedInvoiceRow } from "./InvoiceResultsTable";

export interface EditState {
  invoice_number: string;
  invoice_date: string;
  account_id: string;
  amount_incl_vat: string;
  vat_amount: string;
  currency: string;
  description: string;
  status: string;
  cost_center_id: string;
  organization_id: string;
}

export function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export function toEditState(row: UnifiedInvoiceRow): EditState {
  return {
    invoice_number: row.invoice_number,
    invoice_date: row.invoice_date,
    account_id: row.account_id ?? "",
    amount_incl_vat: String(row.amount_incl_vat),
    vat_amount: String(row.vat_amount),
    currency: row.currency,
    description: row.description ?? "",
    status: row.status ?? "open",
    cost_center_id: row.cost_center_id ?? "",
    organization_id: row.organization_id ?? "",
  };
}

export function InvoiceEditForm({
  editingRow,
  edit,
  setEdit,
  editCategoryId,
  setEditCategoryId,
  accountCategoryOptions,
  editAccountOptions,
  costCenterOptions,
  loadingAccounts,
  loadingCostCenters,
  saving,
  saveError,
  onSave,
  onCancel,
}: {
  editingRow: UnifiedInvoiceRow;
  edit: EditState;
  setEdit: (updater: (v: EditState) => EditState) => void;
  editCategoryId: string;
  setEditCategoryId: (v: string) => void;
  accountCategoryOptions: { id: string; label: string }[];
  editAccountOptions: { id: string; label: string }[];
  costCenterOptions: { id: string; label: string }[];
  loadingAccounts: boolean;
  loadingCostCenters: boolean;
  saving: boolean;
  saveError: string | null;
  onSave: (e: FormEvent) => void;
  onCancel: () => void;
}) {
  return (
    <Card sx={{ mb: 3 }} variant="outlined">
      <CardContent>
        <Typography variant="h6" gutterBottom>
          Edit {editingRow.source === "supplier" ? "Supplier" : "Receivable"} Invoice — {editingRow.invoice_number}
        </Typography>
        <Box component="form" onSubmit={onSave} noValidate>
          <Stack spacing={2.5}>
            <TextField
              label="PRF / OIF No"
              fullWidth
              value={editingRow.prf_oif_number}
              disabled
              helperText="Assigned automatically when the invoice was created — not editable"
            />
            <TextField
              label="Organization"
              fullWidth
              value={editingRow.organization_label}
              disabled
              helperText="An invoice cannot be moved to a different organization — void and re-enter it under the correct organization instead"
            />
            <TextField
              label="Invoice No"
              required
              fullWidth
              value={edit.invoice_number}
              onChange={(e) => setEdit((v) => ({ ...v, invoice_number: e.target.value }))}
            />
            <Stack direction={{ xs: "column", sm: "row" }} spacing={2}>
              <TextField
                select
                label="Account Type"
                sx={{ flex: 1 }}
                value={editCategoryId}
                onChange={(e) => {
                  setEditCategoryId(e.target.value);
                  setEdit((v) => ({ ...v, account_id: "" }));
                }}
              >
                <MenuItem value="">All</MenuItem>
                {accountCategoryOptions.map((c) => (
                  <MenuItem key={c.id} value={c.id}>
                    {c.label}
                  </MenuItem>
                ))}
              </TextField>
              <Autocomplete
                sx={{ flex: 2 }}
                options={editAccountOptions}
                loading={loadingAccounts}
                onChange={(_, option) => setEdit((v) => ({ ...v, account_id: option?.id ?? "" }))}
                value={editAccountOptions.find((o) => o.id === edit.account_id) ?? null}
                isOptionEqualToValue={(option, value) => option.id === value.id}
                renderInput={(params) => (
                  <TextField
                    {...params}
                    label={editingRow.source === "supplier" ? "Vendor Account" : "Client Account"}
                    required
                    InputProps={{
                      ...params.InputProps,
                      endAdornment: (
                        <>
                          {loadingAccounts ? <CircularProgress color="inherit" size={16} /> : null}
                          {params.InputProps.endAdornment}
                        </>
                      ),
                    }}
                  />
                )}
              />
            </Stack>

            <Autocomplete
              options={costCenterOptions}
              loading={loadingCostCenters}
              onChange={(_, option) => setEdit((v) => ({ ...v, cost_center_id: option?.id ?? "" }))}
              value={costCenterOptions.find((o) => o.id === edit.cost_center_id) ?? null}
              isOptionEqualToValue={(option, value) => option.id === value.id}
              renderInput={(params) => (
                <TextField
                  {...params}
                  label="Cost Center"
                  InputProps={{
                    ...params.InputProps,
                    endAdornment: (
                      <>
                        {loadingCostCenters ? <CircularProgress color="inherit" size={16} /> : null}
                        {params.InputProps.endAdornment}
                      </>
                    ),
                  }}
                />
              )}
            />

            <Stack direction={{ xs: "column", sm: "row" }} spacing={2}>
              <TextField
                label="Invoice Date"
                type="date"
                required
                sx={{ flex: 1 }}
                InputLabelProps={{ shrink: true }}
                value={edit.invoice_date}
                onChange={(e) => setEdit((v) => ({ ...v, invoice_date: e.target.value }))}
              />
              <TextField
                label="Amount (incl. VAT)"
                type="number"
                required
                sx={{ flex: 1 }}
                value={edit.amount_incl_vat}
                onChange={(e) => setEdit((v) => ({ ...v, amount_incl_vat: e.target.value }))}
              />
            </Stack>

            <Stack direction={{ xs: "column", sm: "row" }} spacing={2}>
              <TextField
                label="VAT Amount"
                type="number"
                sx={{ flex: 1 }}
                value={edit.vat_amount}
                onChange={(e) => setEdit((v) => ({ ...v, vat_amount: e.target.value }))}
              />
              <TextField select label="Currency" sx={{ flex: 1 }} value={edit.currency} onChange={(e) => setEdit((v) => ({ ...v, currency: e.target.value }))}>
                <MenuItem value="UGX">UGX</MenuItem>
                <MenuItem value="USD">USD</MenuItem>
                <MenuItem value="EUR">EUR</MenuItem>
              </TextField>
              {editingRow.source === "receivable" && (
                <TextField select label="Status" sx={{ flex: 1 }} value={edit.status} onChange={(e) => setEdit((v) => ({ ...v, status: e.target.value }))}>
                  <MenuItem value="open">Open</MenuItem>
                  <MenuItem value="paid">Paid</MenuItem>
                </TextField>
              )}
            </Stack>

            <TextField label="Description" fullWidth value={edit.description} onChange={(e) => setEdit((v) => ({ ...v, description: e.target.value }))} />

            {saveError && <Alert severity="error">{saveError}</Alert>}

            <Stack direction="row" spacing={1}>
              <Button type="submit" variant="contained" disabled={saving}>
                {saving ? "Saving…" : "Save"}
              </Button>
              <Button variant="outlined" onClick={onCancel} disabled={saving}>
                Cancel
              </Button>
            </Stack>
          </Stack>
        </Box>
      </CardContent>
    </Card>
  );
}
