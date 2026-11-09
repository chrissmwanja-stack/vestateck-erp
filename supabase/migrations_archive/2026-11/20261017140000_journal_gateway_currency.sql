-- Phase A, A3 slice 2c (see docs/insurance-brokerage/ROADMAP.md): a posting
-- gateway that understands currency, and a void that reverses at the original rate.
--
-- Problem (found by test, 17 Oct 2026):
--   * post_journal_entry inserted only account, debit, credit and description, so
--     no module could post a foreign-currency journal through it.
--   * void_journal_entry rebuilt reversal lines from the same four fields, so the
--     currency was lost. Voiding a USD 1,000 sale at 3,700 reversed 1,000 UGX and
--     left the bank account at +3,699,000 UGX instead of zero.
--   * journal_lines_fx_guard always re-resolves the rate for the entry date, so even
--     a reversal that kept the currency would have used the rate of the reversal
--     date, not the original rate, and would not have cancelled the original.
--
-- What changes:
--   1. post_journal_entry accepts an optional 'currency' on each line. A line with
--      no currency is in the functional currency, exactly as before. The rate is
--      still never supplied by a normal caller: a 'fx_rate' in the line is ignored
--      and the approved rate for the entry date is used.
--   2. Reversal mode. void_journal_entry sets the internal setting
--      fin.reversal_of to the id of the entry being voided while it posts the
--      reversal. In that mode, and only then:
--        * post_journal_entry takes the 'fx_rate' and 'is_rounding' of each line;
--        * journal_lines_fx_guard keeps the supplied rate, but only if the entry
--          being reversed has a line in the same currency at exactly that rate
--          (JOURNAL_LINE_RATE otherwise), so the setting cannot be used to choose
--          an arbitrary rate;
--        * a reversed rounding line stays flagged as rounding, so rounding totals
--          net to zero after a void.
--      A reversal therefore carries each line's original currency and rate, and the
--      base amounts of the reversal are the exact negatives of the original.
--   3. void_journal_entry builds its reversal lines with currency, rate and
--      rounding flag. Everything else about it (finance role, reason, closed
--      period, audit event, return value) is unchanged.
--
-- No existing company's postings change: lines with no currency are functional
-- currency at rate 1 and a reversal of such a journal is identical to before.
-- No currency guard is removed in this migration; foreign journals can be posted
-- through the gateway only by callers that pass a currency, and none do yet.

-- =====================================================================
-- A. Line rate guard: honour the original rate in reversal mode only
-- =====================================================================
create or replace function public.journal_lines_fx_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date       date;
  v_functional text;
  v_currency   text;
  v_orig       text := nullif(current_setting('fin.reversal_of', true), '');
begin
  select entry_date into v_date
    from journal_entries
   where id = new.journal_entry_id and tenant_id = new.tenant_id;
  if v_date is null then
    raise exception 'JOURNAL_LINE: entry % does not belong to this company', new.journal_entry_id;
  end if;

  v_functional := fin_ledger_currency(new.tenant_id);
  v_currency   := coalesce(nullif(btrim(new.currency), ''), v_functional);
  new.currency := v_currency;

  if v_currency = v_functional then
    new.fx_rate := 1;
  elsif v_orig is not null then
    -- Reversal: keep the supplied rate only if the entry being reversed used it.
    if not exists (
      select 1 from journal_entry_lines
       where journal_entry_id = v_orig::uuid
         and tenant_id = new.tenant_id
         and currency = v_currency
         and fx_rate = new.fx_rate
    ) then
      raise exception 'JOURNAL_LINE_RATE: a reversal can only use a % rate that the entry being reversed already used', v_currency;
    end if;
  else
    new.fx_rate := (platform_fx_rate(new.tenant_id, v_currency, v_date)).rate;
  end if;
  return new;
end;
$$;
revoke all on function public.journal_lines_fx_guard() from public, anon, authenticated;

-- =====================================================================
-- B. The posting gateway carries currency
-- =====================================================================
create or replace function public.post_journal_entry(
  p_tenant_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb
)
returns journal_entries
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_entry journal_entries%rowtype;
  v_line jsonb;
  v_bad_accounts int;
  v_reversal boolean := nullif(current_setting('fin.reversal_of', true), '') is not null;
  v_rate numeric;
  v_rounding boolean;
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
    -- The rate is set by the line guard from the approved rate table. Only a
    -- reversal (fin.reversal_of set by void_journal_entry) may carry a rate, and
    -- the guard then checks it against the entry being reversed.
    v_rate     := case when v_reversal then coalesce((v_line ->> 'fx_rate')::numeric, 1) else 1 end;
    v_rounding := v_reversal and coalesce((v_line ->> 'is_rounding')::boolean, false);

    if v_rounding then
      perform set_config('fin.rounding_line', 'on', true);
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
      nullif(btrim(v_line ->> 'currency'), ''),
      v_rate
    );

    if v_rounding then
      perform set_config('fin.rounding_line', 'off', true);
    end if;
  end loop;

  return v_entry;
end;
$function$;

-- CREATE OR REPLACE keeps the ACL; restate it so the end state is explicit.
revoke execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb)
  from public, anon, authenticated;

-- =====================================================================
-- C. Void reverses at the original currency and rate
-- =====================================================================
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

  -- Build reversal lines (swap debit/credit), keeping each line's currency, its
  -- original rate and its rounding flag so the base amounts negate exactly.
  select jsonb_agg(
    jsonb_build_object(
      'gl_account_id', jel.gl_account_id,
      'debit', jel.credit,
      'credit', jel.debit,
      'currency', jel.currency,
      'fx_rate', jel.fx_rate,
      'is_rounding', jel.is_rounding,
      'description', 'Reversal of ' || v_entry.id::text || ': ' || coalesce(jel.description, '')
    )
  ) into v_lines
  from journal_entry_lines jel
  where jel.journal_entry_id = v_entry.id;

  -- Allow status update via session variable
  perform set_config('app.allow_journal_void', 'true', true);
  update journal_entries set status = 'void' where id = p_entry_id returning * into v_entry;
  perform set_config('app.allow_journal_void', 'false', true);

  -- Post reversal in reversal mode: the line guard keeps the original rates, but
  -- only rates the entry being reversed already used.
  perform set_config('fin.reversal_of', v_entry.id::text, true);
  select * into v_reversal from post_journal_entry(
    v_entry.tenant_id,
    'manual',
    null,
    current_date,
    'Reversal of ' || v_entry.id::text || ' — ' || v_reason,
    v_lines
  );
  perform set_config('fin.reversal_of', '', true);

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