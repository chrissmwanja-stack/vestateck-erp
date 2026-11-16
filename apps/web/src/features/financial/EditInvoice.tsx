import { useCallback, useEffect, useMemo, useState, FormEvent } from 'react';
import { Box, Typography } from '@mui/material';
import { useInvoiceLookups } from './useInvoiceLookups';
import { InvoiceSearchFilters, emptyFilters, type SearchFilters } from './InvoiceSearchFilters';
import { InvoiceResultsTable, type UnifiedInvoiceRow } from './InvoiceResultsTable';
import { InvoiceEditForm, toEditState, type EditState } from './InvoiceEditForm';
import { saveInvoice, searchInvoices } from './invoiceQueries';

// Unified search + edit screen over supplier_invoices and receivable_invoices.
// This file owns the screen state and orchestration; lookups live in
// useInvoiceLookups, queries/payloads in invoiceQueries, and the three
// visual sections in InvoiceSearchFilters / InvoiceResultsTable / InvoiceEditForm.
//
// organization_id has no setter in the edit form -- an invoice's organization
// is locked at creation (see invoiceQueries.saveInvoice) and is carried in
// EditState only so the read-only display has something to render.

export default function EditInvoice() {
  // Lookup failures are shown next to the edit form, as they always have
  // been. setSaveError is a stable state setter, so passing it is safe.
  const [saveError, setSaveError] = useState<string | null>(null);
  const lookups = useInvoiceLookups(setSaveError);
  const { accounts, searchAccounts, accountCategoryOptions, loadAccountsFor } = lookups;

  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<UnifiedInvoiceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [editCategoryId, setEditCategoryId] = useState('');
  const [editingRow, setEditingRow] = useState<UnifiedInvoiceRow | null>(null);
  const [edit, setEdit] = useState<EditState | null>(null);
  const [saving, setSaving] = useState(false);

  const runSearch = useCallback(async (activeFilters: SearchFilters) => {
    setLoading(true);
    setError(null);
    try {
      setRows(await searchInvoices(activeFilters));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load invoices');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    runSearch(emptyFilters);
  }, [runSearch]);

  // Search bar's Account List: narrowed to whichever Account Type is selected.
  const searchAccountOptions = useMemo(
    () =>
      searchAccounts
        .filter((a) => !filters.categoryId || a.category_id === filters.categoryId)
        .map((a) => ({ id: a.id, label: `${a.account_code} — ${a.name}` })),
    [searchAccounts, filters.categoryId]
  );

  // Edit form's Account picker: narrowed to whichever Account Type is selected there.
  const editAccountOptions = useMemo(
    () =>
      accounts
        .filter((a) => !editCategoryId || a.category_id === editCategoryId)
        .map((a) => ({ id: a.id, label: `${a.account_code} — ${a.name}` })),
    [accounts, editCategoryId]
  );

  function handleClear() {
    setFilters(emptyFilters);
    runSearch(emptyFilters);
  }

  function handleStartEdit(row: UnifiedInvoiceRow) {
    setSaveError(null);
    setEditCategoryId('');
    setEditingRow(row);
    setEdit(toEditState(row));
    loadAccountsFor(row.source);
  }

  function handleCancelEdit() {
    setEditingRow(null);
    setEdit(null);
  }

  async function handleSaveEdit(e: FormEvent) {
    e.preventDefault();
    if (!editingRow || !edit) return;
    setSaveError(null);

    // organization_id is deliberately excluded from this check -- it's
    // locked after creation.
    if (!edit.invoice_number.trim() || !edit.invoice_date || !edit.amount_incl_vat || !edit.account_id) {
      setSaveError('Account, invoice number, date, and amount are required.');
      return;
    }
    const parsedAmount = Number(edit.amount_incl_vat);
    if (Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSaveError('Amount must be a valid number greater than 0.');
      return;
    }

    setSaving(true);
    const failure = await saveInvoice(editingRow, edit, parsedAmount);
    setSaving(false);
    if (failure) {
      setSaveError(failure);
      return;
    }

    handleCancelEdit();
    runSearch(filters);
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 2 }}>
        Edit Invoice
      </Typography>

      <InvoiceSearchFilters
        filters={filters}
        setFilters={setFilters}
        organizationOptions={lookups.organizationOptions}
        accountCategoryOptions={accountCategoryOptions}
        searchAccountOptions={searchAccountOptions}
        loadingOrganizations={lookups.loadingOrganizations}
        loadingSearchAccounts={lookups.loadingSearchAccounts}
        onSearch={runSearch}
        onClear={handleClear}
      />

      {editingRow && edit && (
        <InvoiceEditForm
          editingRow={editingRow}
          edit={edit}
          setEdit={setEdit as (updater: (v: EditState) => EditState) => void}
          editCategoryId={editCategoryId}
          setEditCategoryId={setEditCategoryId}
          accountCategoryOptions={accountCategoryOptions}
          editAccountOptions={editAccountOptions}
          costCenterOptions={lookups.costCenterOptions}
          loadingAccounts={lookups.loadingAccounts}
          loadingCostCenters={lookups.loadingCostCenters}
          saving={saving}
          saveError={saveError}
          onSave={handleSaveEdit}
          onCancel={handleCancelEdit}
        />
      )}

      <InvoiceResultsTable rows={rows} loading={loading} error={error} onEdit={handleStartEdit} />
    </Box>
  );
}
