-- A3 follow-ups F3 + F4, the last two gates before a non-UGX company is enabled.
--
-- F3. Six currency columns still defaulted to 'UGX' (journal_entry_lines,
--     cash_bank_transactions, fin_open_items, fin_bank_accounts,
--     ins_policies, bank_statement_lines). On a USD company that default
--     would silently label unlabelled money as UGX. The gateway now derives an omitted line
--     currency from the tenant's ledger, the defaults are gone, and any
--     writer that omits currency fails loudly instead of guessing. UGX
--     companies behave exactly as before -- their ledger IS UGX.
--
-- F4. Rates are 8-decimal end to end, per the owner's decision. Journal
--     lines (and the guards) already rounded to 8; fx_rates still stored
--     up to 10, so an approved rate could be more precise than anything
--     ever posted with it. Now a rate is rounded to 8 at approval (a
--     before-trigger on fx_rates, every write path) and the invariant is
--     pinned with check constraints on fx_rates, journal_entry_lines and
--     fin_settlements: the stored rate IS the rate that was used. Live
--     data has zero violations (verified before this migration).
--
-- Test: supabase/tests/test_f3_f4_currency_defaults.sql.

-- =============================================================================
-- F3.1 The gateway derives an omitted line currency from the ledger.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.post_journal_entry(p_tenant_id uuid, p_source_type text, p_source_id uuid, p_entry_date date, p_description text, p_lines jsonb)
 RETURNS journal_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_entry journal_entries%rowtype;
  v_line jsonb;
  v_bad_accounts int;
  v_reversal boolean := nullif(current_setting('fin.reversal_of', true), '') is not null;
  v_rate numeric;
  v_rounding boolean;
  v_from text;
begin
  if p_tenant_id is null then
    raise exception 'tenant id is required';
  end if;

  -- When called inside a user session (auth.uid() present), the tenant must be the
  -- caller's effective tenant. get_my_tenant_id() already honours active impersonation.
  -- Service-role / cron contexts have no auth.uid() and are skipped.
  if auth.uid() is not null
     and p_tenant_id is distinct from public.get_my_tenant_id() then
    raise exception 'not authorized to post journals for this tenant'
      using errcode = '42501';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'journal must have at least one line';
  end if;

  -- Every referenced GL account must belong to this tenant.
  select count(*) into v_bad_accounts
  from jsonb_array_elements(p_lines) l
  left join gl_accounts ga
    on ga.id = (l ->> 'gl_account_id')::uuid
   and ga.tenant_id = p_tenant_id
  where ga.id is null;

  if v_bad_accounts > 0 then
    raise exception 'one or more GL accounts do not belong to this tenant'
      using errcode = '42501';
  end if;

  if exists (
    select 1 from accounting_periods
    where tenant_id = p_tenant_id
      and status = 'closed'
      and p_entry_date between period_start and period_end
  ) then
    raise exception 'cannot post to %: this date falls in a closed accounting period', p_entry_date;
  end if;

  insert into journal_entries (tenant_id, entry_date, source_type, source_id, description, posted_by)
  values (p_tenant_id, p_entry_date, p_source_type, p_source_id, p_description, auth.uid())
  returning * into v_entry;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    -- The rate is set by the line guard from the approved rate table. Two internal
    -- exceptions, both checked by the guard against an earlier entry: a reversal
    -- (fin.reversal_of, set by void_journal_entry) and a single line that names the
    -- entry it settles ('rate_from_entry' with 'fx_rate').
    v_from     := nullif(v_line ->> 'rate_from_entry', '');
    v_rate     := case when v_reversal or v_from is not null
                       then coalesce((v_line ->> 'fx_rate')::numeric, 1) else 1 end;
    v_rounding := v_reversal and coalesce((v_line ->> 'is_rounding')::boolean, false);

    if v_rounding then
      perform set_config('fin.rounding_line', 'on', true);
    end if;
    if v_from is not null then
      perform set_config('fin.rate_from', v_from, true);
    end if;

    insert into journal_entry_lines
      (journal_entry_id, tenant_id, gl_account_id, debit, credit, description, currency, fx_rate)
    values (
      v_entry.id,
      p_tenant_id,
      (v_line ->> 'gl_account_id')::uuid,
      coalesce((v_line ->> 'debit')::numeric, 0),
      coalesce((v_line ->> 'credit')::numeric, 0),
      v_line ->> 'description',
      -- F3: an omitted line currency is the company's ledger currency, never a
      -- hard-coded default -- a USD company must not see its functional lines
      -- labelled UGX.
      coalesce(nullif(btrim(v_line ->> 'currency'), ''), fin_ledger_currency(p_tenant_id)),
      v_rate
    );

    if v_rounding then
      perform set_config('fin.rounding_line', 'off', true);
    end if;
    if v_from is not null then
      perform set_config('fin.rate_from', '', true);
    end if;
  end loop;

  return v_entry;
end;
$function$;

-- The gateway stays internal: callers go through the finance wrappers and the
-- posting triggers. Clients must not execute it directly.
revoke all on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb) from public, anon, authenticated;
grant execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb) to service_role;

-- =============================================================================
-- F3.2 No currency column guesses UGX by default.
-- =============================================================================
alter table public.journal_entry_lines    alter column currency drop default;
alter table public.cash_bank_transactions alter column currency drop default;
alter table public.fin_open_items         alter column currency drop default;
alter table public.fin_bank_accounts      alter column currency drop default;
alter table public.ins_policies           alter column currency drop default;
alter table public.bank_statement_lines   alter column currency drop default;

-- =============================================================================
-- F4. A rate is 8 decimals at approval, and the stored rate is the used rate.
-- =============================================================================
create or replace function public.fx_rates_round_rate()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  -- Lines and the guards round to 8; approval rounds the same way, so a
  -- key-in rate with more precision is normalised at the door rather than
  -- stored more precisely than it will ever be used.
  new.rate := round(new.rate, 8);
  return new;
end;
$function$;

drop trigger if exists trg_fx_rates_round_rate on public.fx_rates;
create trigger trg_fx_rates_round_rate
  before insert or update of rate on public.fx_rates
  for each row execute function public.fx_rates_round_rate();

alter table public.fx_rates drop constraint if exists fx_rates_rate_8dp;
alter table public.fx_rates
  add constraint fx_rates_rate_8dp check (rate = round(rate, 8));
alter table public.journal_entry_lines drop constraint if exists journal_entry_lines_fx_rate_8dp;
alter table public.journal_entry_lines
  add constraint journal_entry_lines_fx_rate_8dp check (fx_rate = round(fx_rate, 8));
alter table public.fin_settlements drop constraint if exists fin_settlements_fx_rate_8dp;
alter table public.fin_settlements
  add constraint fin_settlements_fx_rate_8dp check (fx_rate = round(fx_rate, 8));
