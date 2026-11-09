-- Harden financial immutability — item 4
-- Journal entries are append-only from client perspective (RLS has only SELECT policy),
-- but service_role/owner could still UPDATE/DELETE. Add trigger-level immutability.
-- Also prevent subledger amount mutation after posting.

-- 1. Immutable journal_entries and journal_entry_lines for every role
create or replace function public.prevent_journal_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Allow INSERT via post_journal_entry() only; block UPDATE/DELETE for everyone
  -- including table owner. Voiding must go through void_journal_entry() RPC which
  -- inserts reversal and marks original as void via SECURITY DEFINER bypass of this trigger? 
  -- Actually this trigger blocks even that — so void_journal_entry will need to be
  -- SECURITY DEFINER and temporarily disable trigger or use a flag.
  -- For now, block all UPDATE/DELETE unconditionally — reversal pattern to be added in follow-up.
  -- Exception: allow status change from posted -> void only via void_journal_entry() which sets a session variable.
  if tg_op = 'UPDATE' then
    -- Allow only status transition posted->void when session variable allows it
    if old.status = 'posted' and new.status = 'void' and current_setting('app.allow_journal_void', true) = 'true' then
      return new;
    end if;
    raise exception 'JOURNAL_IMMUTABLE: journal entries are immutable, create a reversal entry instead (attempted % on %)', tg_op, old.id
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'JOURNAL_IMMUTABLE: journal entries cannot be deleted (attempted delete on %)', old.id
      using errcode = 'restrict_violation';
  end if;
  return null;
end;
$$;

revoke execute on function public.prevent_journal_mutation() from public;

drop trigger if exists no_update_journal_entries on public.journal_entries;
create trigger no_update_journal_entries
  before update or delete on public.journal_entries
  for each row execute function public.prevent_journal_mutation();

drop trigger if exists no_update_journal_entry_lines on public.journal_entry_lines;
create trigger no_update_journal_entry_lines
  before update or delete on public.journal_entry_lines
  for each row execute function public.prevent_journal_mutation();

-- 2. Prevent subledger amount mutation after journal posted
create or replace function public.prevent_posted_invoice_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_journal boolean;
begin
  if tg_op = 'UPDATE' then
    -- Only care about amount field changes
    if tg_table_name = 'supplier_invoices' then
      if new.amount_incl_vat is distinct from old.amount_incl_vat
         or new.vat_amount is distinct from old.vat_amount
         or new.wht_amount is distinct from old.wht_amount then
        select exists(select 1 from journal_entries where source_type='supplier_invoice' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_INVOICE_IMMUTABLE: cannot change amount of posted supplier invoice % — create a credit note reversal', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'receivable_invoices' then
      if new.amount_incl_vat is distinct from old.amount_incl_vat
         or new.vat_amount is distinct from old.vat_amount then
        select exists(select 1 from journal_entries where source_type='receivable_invoice' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_INVOICE_IMMUTABLE: cannot change amount of posted receivable invoice %', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    elsif tg_table_name = 'cash_bank_transactions' then
      if new.amount is distinct from old.amount then
        select exists(select 1 from journal_entries where source_type='cash_bank_transaction' and source_id=old.id)
          into v_has_journal;
        if v_has_journal then
          raise exception 'POSTED_TRANSACTION_IMMUTABLE: cannot change amount of posted cash/bank transaction %', old.id
            using errcode = 'restrict_violation';
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.prevent_posted_invoice_update() from public;

drop trigger if exists trg_prevent_posted_supplier_invoice_update on public.supplier_invoices;
create trigger trg_prevent_posted_supplier_invoice_update
  before update on public.supplier_invoices
  for each row execute function public.prevent_posted_invoice_update();

drop trigger if exists trg_prevent_posted_receivable_invoice_update on public.receivable_invoices;
create trigger trg_prevent_posted_receivable_invoice_update
  before update on public.receivable_invoices
  for each row execute function public.prevent_posted_invoice_update();

drop trigger if exists trg_prevent_posted_cash_bank_update on public.cash_bank_transactions;
create trigger trg_prevent_posted_cash_bank_update
  before update on public.cash_bank_transactions
  for each row execute function public.prevent_posted_invoice_update();

-- 3. Void RPC with reversal (proper pattern)
create or replace function public.void_journal_entry(p_entry_id uuid, p_reason text)
returns public.journal_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry journal_entries%rowtype;
  v_reversal journal_entries%rowtype;
  v_lines jsonb;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'A reason (at least 5 characters) is required to void a journal entry';
  end if;

  if not is_finance_team_member('finance') then
    raise exception 'not authorized to void journal entries';
  end if;

  select * into v_entry from journal_entries where id = p_entry_id for update;
  if not found then
    raise exception 'journal entry not found';
  end if;
  if v_entry.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this journal entry';
  end if;
  if v_entry.status = 'void' then
    return v_entry;
  end if;

  -- Check closed period for reversal date (today)
  if exists (
    select 1 from accounting_periods
    where tenant_id = v_entry.tenant_id
      and status = 'closed'
      and current_date between period_start and period_end
  ) then
    raise exception 'cannot void in closed period - current date % is in closed period', current_date;
  end if;

  -- Build reversal lines (swap debit/credit)
  select jsonb_agg(
    jsonb_build_object(
      'gl_account_id', jel.gl_account_id,
      'debit', jel.credit,
      'credit', jel.debit,
      'description', 'Reversal of ' || v_entry.id::text || ': ' || coalesce(jel.description, '')
    )
  ) into v_lines
  from journal_entry_lines jel
  where jel.journal_entry_id = v_entry.id;

  -- Allow status update via session variable
  perform set_config('app.allow_journal_void', 'true', true);
  update journal_entries set status = 'void' where id = p_entry_id returning * into v_entry;
  perform set_config('app.allow_journal_void', 'false', true);

  -- Post reversal
  select * into v_reversal from post_journal_entry(
    v_entry.tenant_id,
    'manual',
    null,
    current_date,
    'Reversal of ' || v_entry.id::text || ' — ' || v_reason,
    v_lines
  );

  perform log_platform_event(
    'journal.void', v_entry.tenant_id, 'journal_entry', p_entry_id::text, v_reason,
    jsonb_build_object('original_entry', v_entry.id, 'original_status', 'posted'),
    jsonb_build_object('reversal_entry', v_reversal.id, 'reason', v_reason)
  );

  return v_reversal;
end;
$$;

revoke execute on function public.void_journal_entry(uuid, text) from public;
grant execute on function public.void_journal_entry(uuid, text) to authenticated;

comment on function public.void_journal_entry(uuid, text) is
  'Voids a posted journal entry by marking original as void and posting reversal with swapped debit/credit. Requires reason, finance role, open period. Enforces immutability pattern.';
