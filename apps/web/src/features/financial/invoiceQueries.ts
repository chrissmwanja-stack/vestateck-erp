import { supabase } from '../../lib/supabaseClient';
import type { SearchFilters } from './InvoiceSearchFilters';
import type { UnifiedInvoiceRow } from './InvoiceResultsTable';
import { embedOne, type EditState } from './InvoiceEditForm';

// Data access for the Edit Invoice screen: one unified search across
// supplier_invoices and receivable_invoices, and the per-source update.
// Kept out of the component so the payload rules are in one place.

export async function searchInvoices(filters: SearchFilters): Promise<UnifiedInvoiceRow[]> {
  const wantSupplier = filters.source === '' || filters.source === 'supplier';
  const wantReceivable = filters.source === '' || filters.source === 'receivable';

  const results: UnifiedInvoiceRow[] = [];

  if (wantSupplier) {
    let q = supabase
      .from('supplier_invoices')
      .select(
        'id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, description, invoice_type, cost_center_id, organization_id, prf_oif_number, vendor_account_id, vendor_account:accounts!vendor_account_id(name, account_code), organization:organizations!organization_id(company_code, site_name), created_at'
      )
      .order('created_at', { ascending: false });
    if (filters.invoiceNo.trim()) q = q.ilike('invoice_number', `%${filters.invoiceNo.trim()}%`);
    if (filters.prfOifNo.trim()) q = q.ilike('prf_oif_number', `%${filters.prfOifNo.trim()}%`);
    if (filters.dateFrom) q = q.gte('invoice_date', filters.dateFrom);
    if (filters.dateTo) q = q.lte('invoice_date', filters.dateTo);
    if (filters.organizationId) q = q.eq('organization_id', filters.organizationId);
    if (filters.accountId) q = q.eq('vendor_account_id', filters.accountId);
    const { data, error: qErr } = await q;
    if (qErr) throw qErr;
    (data ?? []).forEach((r) => {
      const acct = embedOne(r.vendor_account);
      const org = embedOne(r.organization);
      results.push({
        id: r.id,
        source: 'supplier',
        invoice_number: r.invoice_number,
        invoice_date: r.invoice_date,
        account_id: r.vendor_account_id,
        account_label: acct ? `${acct.account_code} — ${acct.name}` : '—',
        amount_incl_vat: r.amount_incl_vat,
        vat_amount: r.vat_amount,
        currency: r.currency,
        description: r.description,
        status: null,
        invoice_type: r.invoice_type,
        cost_center_id: r.cost_center_id,
        organization_id: r.organization_id,
        organization_label: org ? `${org.company_code} — ${org.site_name}` : '—',
        prf_oif_number: r.prf_oif_number,
      });
    });
  }

  if (wantReceivable) {
    let q = supabase
      .from('receivable_invoices')
      .select(
        'id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, description, status, cost_center_id, organization_id, prf_oif_number, client_account_id, client_account:accounts!client_account_id(name, account_code), organization:organizations!organization_id(company_code, site_name), created_at'
      )
      .order('created_at', { ascending: false });
    if (filters.invoiceNo.trim()) q = q.ilike('invoice_number', `%${filters.invoiceNo.trim()}%`);
    if (filters.prfOifNo.trim()) q = q.ilike('prf_oif_number', `%${filters.prfOifNo.trim()}%`);
    if (filters.dateFrom) q = q.gte('invoice_date', filters.dateFrom);
    if (filters.dateTo) q = q.lte('invoice_date', filters.dateTo);
    if (filters.organizationId) q = q.eq('organization_id', filters.organizationId);
    if (filters.accountId) q = q.eq('client_account_id', filters.accountId);
    const { data, error: qErr } = await q;
    if (qErr) throw qErr;
    (data ?? []).forEach((r) => {
      const acct = embedOne(r.client_account);
      const org = embedOne(r.organization);
      results.push({
        id: r.id,
        source: 'receivable',
        invoice_number: r.invoice_number,
        invoice_date: r.invoice_date,
        account_id: r.client_account_id,
        account_label: acct ? `${acct.account_code} — ${acct.name}` : '—',
        amount_incl_vat: r.amount_incl_vat,
        vat_amount: r.vat_amount,
        currency: r.currency,
        description: r.description,
        status: r.status,
        invoice_type: null,
        cost_center_id: r.cost_center_id,
        organization_id: r.organization_id,
        organization_label: org ? `${org.company_code} — ${org.site_name}` : '—',
        prf_oif_number: r.prf_oif_number,
      });
    });
  }

  results.sort((a, b) => (a.invoice_date < b.invoice_date ? 1 : -1));
  return results;
}

// Returns an error message, or null on success.
//
// organization_id is deliberately never sent: an invoice's organization is
// locked at creation, enforced server-side by lock_supplier_invoice_organization
// and lock_receivable_invoice_organization. `status` is receivable-only.
export async function saveInvoice(row: UnifiedInvoiceRow, edit: EditState, amount: number): Promise<string | null> {
  const common = {
    invoice_number: edit.invoice_number.trim(),
    invoice_date: edit.invoice_date,
    amount_incl_vat: amount,
    vat_amount: Number(edit.vat_amount || 0),
    currency: edit.currency,
    description: edit.description.trim() || null,
    cost_center_id: edit.cost_center_id || null,
  };

  if (row.source === 'supplier') {
    const { error } = await supabase
      .from('supplier_invoices')
      .update({ ...common, vendor_account_id: edit.account_id })
      .eq('id', row.id);
    return error ? error.message ?? 'Could not save changes.' : null;
  }

  const { error } = await supabase
    .from('receivable_invoices')
    .update({ ...common, client_account_id: edit.account_id, status: edit.status })
    .eq('id', row.id);
  return error ? error.message ?? 'Could not save changes.' : null;
}
