-- =====================================================================
-- Insurance: per-insurer remittance detail in the in-force import
-- =====================================================================
--
-- What this is for, in plain terms
--
--   When a broker takes over a book from another system, some policies are
--   placed with more than one insurer (co-insured). For those, the broker owes
--   each insurer its own share of the premium, and it may have paid them at
--   different times, or paid one and not the other.
--
--   The import has only ever recorded money paid to insurers at the level of
--   the policy -- "we paid 800 against policy P". When P is co-insured, the
--   opening position had to guess how that 800 split between insurers. The
--   guess is proportional: each insurer's share of the total payable, with the
--   last one taking the rounding remainder. `IN_FORCE_IMPORT.md` step 5 states
--   this and says that per-insurer detail in the template would remove it.
--
--   The guess costs money. If insurer A was paid in full and insurer B nothing,
--   a proportional split reports both as half paid. The payable still owed to
--   each insurer is then wrong per insurer, and so is the commission
--   recognised at cut-over, because a share's commission counts as earned only
--   when that share is fully remitted. On a book with one insurer settled and
--   another open, the opening position is materially wrong.
--
-- What changes
--
--   1. A remittance may name the insurer it was paid to (and the share it
--      belongs to is resolved and stored).
--   2. When it does, that insurer's share gets it and no other share does. The
--      proportional split is not used at all for that policy.
--   3. A policy's remittance history is either all named or all policy-level.
--      Mixing the two is refused by name, because the two mean different
--      things and the honest split of an unknown amount against a partly-known
--      history cannot be computed without inventing one.
--
--   Policy-level history keeps working exactly as before, including the
--   proportional split, so every existing import reproduces. That matters: the
--   approximation is still legitimate where the source system genuinely does
--   not know which insurer was paid, and refusing that history would strand
--   brokers whose legacy data is simply coarser. The opening position now also
--   reports how many remittances named an insurer, so a reviewer can tell which
--   batch was split and which was exact.
--
-- New refusals (all by name, with the figures)
--
--   INS_IMPORT_HISTORY_INSURER      a receipt (client money) named an insurer
--   INS_IMPORT_REMITTANCE_INSURER   the insurer is not on the policy
--   INS_IMPORT_REMITTANCE_MIXED     named and policy-level history on one policy
--   INS_IMPORT_REMITTANCES_EXCEED_PAYABLE  over-remits that insurer's share
--
-- Idempotent: the columns, the constraint and the index are added only if
-- absent, and every function is create-or-replace on the same signature.

-- ---------------------------------------------------------------------
-- 1. A remittance may carry the insurer it was paid to
-- ---------------------------------------------------------------------
alter table public.ins_import_remittances
  add column if not exists insurer_id uuid references public.ins_insurers(id),
  add column if not exists insurer_share_id uuid references public.ins_policy_insurer_shares(id);

comment on column public.ins_import_remittances.insurer_id is
  'The insurer this remittance was paid to, when the source system records it. Null means the legacy record is policy-level and the opening position may only split it proportionally.';
comment on column public.ins_import_remittances.insurer_share_id is
  'The share the named insurer holds on this policy, resolved when the row was written so the opening position does not re-resolve it after a share changes.';

-- A share without an insurer is meaningless. An insurer without a share is
-- legitimate: a single-insurer policy records no share row at all -- the policy
-- itself is the share -- and naming its insurer must still be allowed, because
-- the all-or-nothing rule below counts named remittances and a single-insurer
-- policy is the commonest case of all.
alter table public.ins_import_remittances
  drop constraint if exists ins_import_remittances_insurer_pair_chk;
alter table public.ins_import_remittances
  add constraint ins_import_remittances_insurer_pair_chk
  check (insurer_share_id is null or insurer_id is not null);

create index if not exists ins_import_remittances_share_idx
  on public.ins_import_remittances (insurer_share_id)
  where insurer_share_id is not null;


-- ---------------------------------------------------------------------
-- One predicate decides "does this policy's remittance history name insurers?"
-- ---------------------------------------------------------------------
-- Shared by the writer and the posting function so the two can never disagree
-- about what a policy's history is. Returns 'none' (policy-level only),
-- 'all' (every remittance names an insurer) or 'mixed' (a data error).
create or replace function public.ins_import_remittance_detail_state(
  p_tenant_id uuid, p_batch_id uuid, p_policy_id uuid)
returns text
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
  select case
           when count(*) = 0 then 'none'
           when count(*) filter (where insurer_id is null) = 0 then 'all'
           when count(*) filter (where insurer_id is not null) = 0 then 'none'
           else 'mixed'
         end
    from public.ins_import_remittances
   where tenant_id = p_tenant_id and batch_id = p_batch_id and policy_id = p_policy_id;
$function$;

-- Also owner-only: it is the predicate behind the writer's rule, not a client API.
revoke all on function public.ins_import_remittance_detail_state(uuid, uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- History writer: the detail arrives here
-- ---------------------------------------------------------------------
create or replace function public.ins_import_history_add(
  p_batch_id uuid, p_policy_id uuid, p_kind text, p_date date, p_reference text, p_amount numeric,
  p_insurer_id uuid)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  b         public.ins_import_batches;
  v_policy  public.ins_policies;
  v_ref     text := nullif(btrim(coalesce(p_reference, '')), '');
  v_have    numeric;
  v_cap     numeric;
  v_exists  boolean;
  v_n_shares integer;
  v_share   uuid;
  v_state   text;
begin
  if p_kind not in ('receipt', 'remittance') then
    raise exception 'INS_IMPORT_HISTORY_KIND: % is neither a receipt nor a remittance', p_kind;
  end if;

  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;

  -- The opening position is posted: history is frozen with it.
  if exists (select 1 from public.journal_entries
              where tenant_id = v_tenant and source_type = 'ins_import_opening'
                and source_id = p_batch_id) then
    raise exception 'INS_IMPORT_OPENING_POSTED: the opening position is posted; history can no longer change';
  end if;

  if p_date is null then
    raise exception 'INS_IMPORT_HISTORY_DATE: every % needs a date', p_kind;
  end if;
  if p_date > b.cut_over_date then
    raise exception 'INS_IMPORT_HISTORY_AFTER_CUTOFF: % dated % is after the cut-over date %',
      p_kind, p_date, b.cut_over_date;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_IMPORT_HISTORY_AMOUNT: every % needs an amount above zero', p_kind;
  end if;

  select * into v_policy from public.ins_policies
   where tenant_id = v_tenant and id = p_policy_id and import_batch_id = p_batch_id;
  if not found then
    raise exception 'INS_IMPORT_POLICY_NOT_IN_BATCH: policy % is not in this batch', p_policy_id;
  end if;

  if p_kind = 'receipt' then
    if p_insurer_id is not null then
      raise exception 'INS_IMPORT_HISTORY_INSURER: a receipt is client money and cannot name an insurer; only a remittance can';
    end if;

    select exists (select 1 from public.ins_import_receipts x
                    where x.tenant_id = v_tenant and x.batch_id = p_batch_id
                      and x.policy_id = v_policy.id and x.receipt_date = p_date
                      and x.amount = p_amount and x.reference is not distinct from v_ref)
      into v_exists;
    if v_exists then return 'duplicate'; end if;

    select coalesce(sum(x.amount), 0) into v_have
      from public.ins_import_receipts x
     where x.tenant_id = v_tenant and x.batch_id = p_batch_id and x.policy_id = v_policy.id;
    v_cap := v_policy.gross_premium;
    if v_have + p_amount > v_cap then
      raise exception 'INS_IMPORT_RECEIPTS_EXCEED_PREMIUM: receipts for policy % would total % against a gross premium of %',
        v_policy.policy_no, v_have + p_amount, v_cap;
    end if;

    insert into public.ins_import_receipts
      (tenant_id, batch_id, policy_id, receipt_date, reference, amount)
    values (v_tenant, p_batch_id, v_policy.id, p_date, v_ref, p_amount);
  else
    select count(*) into v_n_shares
      from public.ins_policy_insurer_shares s
     where s.tenant_id = v_tenant and s.policy_id = v_policy.id;

    -- Resolve the named insurer to the share it holds. A single-insurer policy
    -- records no share row, so there the policy's own insurer is the answer.
    if p_insurer_id is not null then
      select s.id into v_share
        from public.ins_policy_insurer_shares s
       where s.tenant_id = v_tenant and s.policy_id = v_policy.id
         and s.insurer_id = p_insurer_id;

      if v_share is null
         and not (v_n_shares = 0 and p_insurer_id = v_policy.insurer_id) then
        raise exception 'INS_IMPORT_REMITTANCE_INSURER: insurer % is not on policy %; a remittance can only name an insurer that participates in the policy',
          p_insurer_id, v_policy.policy_no;
      end if;
    end if;

    -- All or nothing. A policy-level remittance means "we do not know which
    -- insurer"; a named one means "we do". Both together is a data error, and
    -- the honest split of an unknown amount against a partly-known history
    -- cannot be computed without inventing one -- so refuse by name.
    v_state := public.ins_import_remittance_detail_state(v_tenant, p_batch_id, v_policy.id);
    if p_insurer_id is null and v_state = 'all' then
      raise exception 'INS_IMPORT_REMITTANCE_MIXED: every remittance for policy % so far names its insurer, but this one does not. Name the insurer the % was paid to, or record none of them with detail',
        v_policy.policy_no, p_amount;
    end if;
    if p_insurer_id is not null and v_state = 'none'
       and exists (select 1 from public.ins_import_remittances x
                    where x.tenant_id = v_tenant and x.batch_id = p_batch_id
                      and x.policy_id = v_policy.id) then
      raise exception 'INS_IMPORT_REMITTANCE_MIXED: policy % already has policy-level remittances; this one names insurer %. Record every remittance for the policy with the same level of detail',
        v_policy.policy_no, p_insurer_id;
    end if;

    select exists (select 1 from public.ins_import_remittances x
                    where x.tenant_id = v_tenant and x.batch_id = p_batch_id
                      and x.policy_id = v_policy.id and x.remit_date = p_date
                      and x.amount = p_amount and x.reference is not distinct from v_ref
                      and x.insurer_id is not distinct from p_insurer_id)
      into v_exists;
    if v_exists then return 'duplicate'; end if;

    if p_insurer_id is null then
      -- Policy-level: the whole policy's net premium is the cap, as before.
      select coalesce(sum(x.amount), 0) into v_have
        from public.ins_import_remittances x
       where x.tenant_id = v_tenant and x.batch_id = p_batch_id and x.policy_id = v_policy.id;
      v_cap := round(v_policy.gross_premium - coalesce(v_policy.commission_amount, 0), 2);
      if v_have + p_amount > v_cap then
        raise exception 'INS_IMPORT_REMITTANCES_EXCEED_PAYABLE: remittances for policy % would total % against a net premium of %',
          v_policy.policy_no, v_have + p_amount, v_cap;
      end if;
    else
      -- Named: capped by THAT insurer's payable. This is the whole point -- an
      -- insurer paid in full cannot be over-paid because another is unpaid.
      select coalesce(sum(x.amount), 0) into v_have
        from public.ins_import_remittances x
       where x.tenant_id = v_tenant and x.batch_id = p_batch_id
         and x.policy_id = v_policy.id and x.insurer_id = p_insurer_id;

      if v_share is null then
        v_cap := round(v_policy.gross_premium - coalesce(v_policy.commission_amount, 0), 2);
      else
        select round(s.payable_amount, 2) into v_cap
          from public.ins_policy_insurer_shares s where s.id = v_share;
      end if;

      if v_have + p_amount > v_cap then
        raise exception 'INS_IMPORT_REMITTANCES_EXCEED_PAYABLE: remittances to insurer % on policy % would total % against that insurer''s payable of %',
          p_insurer_id, v_policy.policy_no, v_have + p_amount, v_cap;
      end if;
    end if;

    insert into public.ins_import_remittances
      (tenant_id, batch_id, policy_id, remit_date, reference, amount, insurer_id, insurer_share_id)
    values (v_tenant, p_batch_id, v_policy.id, p_date, v_ref, p_amount, p_insurer_id, v_share);
  end if;

  return 'recorded';
end
$function$;

-- Owner-only, like every other history helper: clients go through
-- ins_import_record_history, which is where the permission check lives.
revoke all on function public.ins_import_history_add(uuid, uuid, text, date, text, numeric, uuid)
  from public, anon, authenticated;

-- The six-argument signature stays exactly as it was, so anything that calls it
-- keeps working and simply records policy-level history.
create or replace function public.ins_import_history_add(
  p_batch_id uuid, p_policy_id uuid, p_kind text, p_date date, p_reference text, p_amount numeric)
returns text
language sql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
  select public.ins_import_history_add(p_batch_id, p_policy_id, p_kind, p_date, p_reference, p_amount, null);
$function$;

revoke all on function public.ins_import_history_add(uuid, uuid, text, date, text, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. The request API can carry the detail
-- ---------------------------------------------------------------------
create or replace function public.ins_import_record_history(p_batch_id uuid, p_receipts jsonb, p_remittances jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  b          public.ins_import_batches;
  r          jsonb;
  v_outcome  text;
  v_rec      integer := 0;
  v_rec_skip integer := 0;
  v_rem      integer := 0;
  v_rem_skip integer := 0;
  v_named    integer := 0;
  v_ins      uuid;
  v_code     text;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if b.status <> 'committed' then
    raise exception 'INS_IMPORT_NOT_COMMITTED: commit the policies before recording their payment history';
  end if;

  set local ins.via_rpc = 'on';

  for r in select * from jsonb_array_elements(coalesce(p_receipts, '[]'::jsonb)) loop
    -- A receipt is money from the client, so there is no insurer to name. Say so
    -- rather than dropping the field: a caller that sent one believes it means
    -- something, and silently ignoring it would hide a mixed-up template.
    if nullif(btrim(coalesce(r ->> 'insurer_id', r ->> 'insurer', r ->> 'insurer_code', '')), '') is not null then
      raise exception 'INS_IMPORT_HISTORY_INSURER: a receipt is client money and cannot name an insurer; only a remittance can';
    end if;

    v_outcome := public.ins_import_history_add(
      p_batch_id, (r ->> 'policy_id')::uuid, 'receipt',
      (r ->> 'receipt_date')::date, r ->> 'reference', (r ->> 'amount')::numeric);
    if v_outcome = 'recorded' then v_rec := v_rec + 1; else v_rec_skip := v_rec_skip + 1; end if;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_remittances, '[]'::jsonb)) loop
    -- The insurer may be an id (from the wizard) or a code or name (from a
    -- spreadsheet), because a spreadsheet holds the code the client typed.
    v_ins  := null;
    v_code := nullif(btrim(coalesce(r ->> 'insurer', r ->> 'insurer_code', '')), '');
    if nullif(btrim(coalesce(r ->> 'insurer_id', '')), '') is not null then
      v_ins := (r ->> 'insurer_id')::uuid;
    elsif v_code is not null then
      select i.id into v_ins from public.ins_insurers i
       where i.tenant_id = v_tenant
         and (upper(i.code) = upper(v_code) or lower(i.name) = lower(v_code))
       order by (upper(i.code) = upper(v_code)) desc, i.code
       limit 1;
      if v_ins is null then
        raise exception 'INS_IMPORT_REMITTANCE_INSURER: no insurer on this company matches %', v_code;
      end if;
    end if;

    v_outcome := public.ins_import_history_add(
      p_batch_id, (r ->> 'policy_id')::uuid, 'remittance',
      (r ->> 'remit_date')::date, r ->> 'reference', (r ->> 'amount')::numeric, v_ins);
    if v_outcome = 'recorded' then v_rem := v_rem + 1; else v_rem_skip := v_rem_skip + 1; end if;
    if v_ins is not null then v_named := v_named + 1; end if;
  end loop;

  reset ins.via_rpc;

  return jsonb_build_object(
    'batch_id', p_batch_id,
    'receipts_recorded', v_rec,
    'receipts_already_present', v_rec_skip,
    'remittances_recorded', v_rem,
    'remittances_already_present', v_rem_skip,
    'remittances_naming_an_insurer', v_named);
end
$function$;

revoke all on function public.ins_import_record_history(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.ins_import_record_history(uuid, jsonb, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The opening position uses the detail when the history has it
-- ---------------------------------------------------------------------
-- Unchanged in every respect except the per-share remittance figure below:
-- where the history names insurers, this share gets that insurer's payments;
-- where it does not, the documented proportional split applies as before.
create or replace function public.ins_import_post_opening_position(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
declare
  v_tenant      uuid := public.get_my_tenant_id();
  b             public.ins_import_batches;
  v_existing    uuid;
  v_je          public.journal_entries;
  v_lines       jsonb := '[]'::jsonb;
  v_items       jsonb := '[]'::jsonb;
  v_desc        text;
  v_ar_gl       uuid; v_pay_gl uuid; v_unearned_gl uuid; v_clearing_gl uuid; v_retained_gl uuid;
  v_bank_gl     uuid;
  v_ar_acc      uuid; v_ins_acc uuid;
  pol           record;
  sh            record;
  v_receipts    numeric;
  v_remits      numeric;
  v_named       numeric;
  v_ar_out      numeric;
  v_share_rows  integer;
  v_i           integer;
  v_total_pay   numeric;
  v_alloc       numeric;
  v_share_remit numeric;
  v_pay_out     numeric;
  v_comm        numeric;
  v_earned      boolean;
  ccy           record;
  v_net_float   numeric;
  v_bad         numeric;
  it            jsonb;
  v_ar_total    numeric := 0;
  v_pay_total   numeric := 0;
  v_def_total   numeric := 0;
  v_earn_total  numeric := 0;
  v_bank_recorded numeric;
  v_bank_total  numeric := 0;
  v_bank_by_ccy jsonb := '{}'::jsonb;
  v_clear_by_ccy jsonb := '{}'::jsonb;
  v_n_items     integer := 0;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if b.status <> 'committed' then
    raise exception 'INS_IMPORT_NOT_COMMITTED: commit policies before posting the opening position';
  end if;

  -- Idempotency: the journal is the marker. Re-running is a no-op, and
  -- history written first can no longer suppress the post. The advisory
  -- lock makes two concurrent attempts serialise here, so the second one
  -- reads the first one's journal instead of tripping the source unique
  -- index (which stays as the last-resort guard).
  perform pg_advisory_xact_lock(hashtextextended('ins_import_opening:' || p_batch_id::text, 0));
  select id into v_existing from public.journal_entries
   where tenant_id = v_tenant and source_type = 'ins_import_opening'
     and source_id = p_batch_id;
  if v_existing is not null then
    return jsonb_build_object('already_posted', true, 'batch_id', p_batch_id,
                              'journal_entry_id', v_existing);
  end if;

  v_ar_gl       := public.get_posting_account(v_tenant, 'ar_control');
  v_pay_gl      := public.get_posting_account(v_tenant, 'insurer_payable');
  v_unearned_gl := public.get_posting_account(v_tenant, 'unearned_commission');
  v_clearing_gl := public.get_posting_account(v_tenant, 'opening_balance_clearing');
  v_retained_gl := public.get_posting_account(v_tenant, 'retained_earnings');
  if v_ar_gl is null or v_pay_gl is null or v_unearned_gl is null
     or v_clearing_gl is null or v_retained_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: chart needs ar_control, insurer_payable, unearned_commission, opening_balance_clearing and retained_earnings';
  end if;
  -- Leg 4 is optional: the client-money bank account is only required when the
  -- batch's control totals actually record a bank balance for a currency.
  v_bank_gl := public.get_posting_account(v_tenant, 'client_money_bank');

  set local ins.via_rpc = 'on';

  -- Clearing: receipts minus remittances per currency, on one side only.
  for ccy in
    select x.currency, sum(x.rec) - sum(x.rem) as net
      from (
        select p.currency, r.amount as rec, 0::numeric as rem
          from public.ins_import_receipts r
          join public.ins_policies p on p.id = r.policy_id
         where r.tenant_id = v_tenant and r.batch_id = p_batch_id
        union all
        select p.currency, 0::numeric, m.amount
          from public.ins_import_remittances m
          join public.ins_policies p on p.id = m.policy_id
         where m.tenant_id = v_tenant and m.batch_id = p_batch_id
        union all
        select p.currency, 0::numeric, 0::numeric
          from public.ins_policies p
         where p.tenant_id = v_tenant and p.import_batch_id = p_batch_id
      ) x
     group by x.currency
     order by x.currency
  loop
    v_net_float := round(ccy.net, 2);

    -- Leg 4: the client-money bank balance the reviewer counted at cut-over.
    -- What the history says should be there is receipts minus remittances;
    -- the balance sheet gets the figure the reviewer recorded, and anything
    -- the history cannot explain stays in clearing instead of being hidden.
    v_bank_recorded := (select (c ->> 'client_money')::numeric
                          from jsonb_array_elements(coalesce(b.control_totals, '[]'::jsonb)) c
                         where upper(c ->> 'currency') = upper(ccy.currency)
                         limit 1);
    if v_bank_recorded is not null then
      if v_bank_recorded < 0 then
        raise exception 'INS_IMPORT_BANK_NEGATIVE: the % client-money balance cannot be negative (%)',
          ccy.currency, v_bank_recorded;
      end if;
      if v_bank_gl is null then
        raise exception 'INS_POSTING_RULE_MISSING: control totals record a % client-money balance, so the chart needs a client_money_bank account (1020 in the insurance template)',
          ccy.currency;
      end if;
      if v_bank_recorded > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'gl_account_id', v_bank_gl, 'debit', v_bank_recorded, 'currency', ccy.currency,
          'description', 'Client money in the bank at cut-over (import ' || left(p_batch_id::text, 8) || ')'));
        v_bank_total := v_bank_total + v_bank_recorded;
        v_bank_by_ccy := v_bank_by_ccy || jsonb_build_object(ccy.currency, v_bank_recorded);
      end if;
      v_net_float := round(v_net_float - v_bank_recorded, 2);
    end if;

    if v_net_float > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'gl_account_id', v_clearing_gl, 'debit', v_net_float, 'currency', ccy.currency,
        'description', 'Client money received at cut-over (import ' || left(p_batch_id::text, 8) || ')'));
    elsif v_net_float < 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'gl_account_id', v_clearing_gl, 'credit', -v_net_float, 'currency', ccy.currency,
        'description', 'Remitted beyond receipts at cut-over (import ' || left(p_batch_id::text, 8) || ')'));
    end if;
    v_clear_by_ccy := v_clear_by_ccy || jsonb_build_object(ccy.currency, v_net_float);
  end loop;

  for pol in
    select p.id, p.policy_no, p.inception_date, p.gross_premium, p.commission_amount,
           p.currency, p.client_id, p.insurer_id,
           round(p.gross_premium - coalesce(p.commission_amount, 0), 2) as net_premium
      from public.ins_policies p
     where p.tenant_id = v_tenant and p.import_batch_id = p_batch_id
     order by p.policy_no
  loop
    v_desc := 'Opening position (import ' || left(p_batch_id::text, 8) || '): ' || pol.policy_no;

    select coalesce(sum(r.amount), 0) into v_receipts
      from public.ins_import_receipts r
     where r.tenant_id = v_tenant and r.batch_id = p_batch_id and r.policy_id = pol.id;
    select coalesce(sum(m.amount), 0) into v_remits
      from public.ins_import_remittances m
     where m.tenant_id = v_tenant and m.batch_id = p_batch_id and m.policy_id = pol.id;
    -- How much of that history names an insurer. Zero means policy-level only,
    -- and only then may the proportional approximation be used.
    select coalesce(sum(m.amount), 0) into v_named
      from public.ins_import_remittances m
     where m.tenant_id = v_tenant and m.batch_id = p_batch_id and m.policy_id = pol.id
       and m.insurer_id is not null;

    -- Client receivable: billed minus received.
    v_ar_out := round(pol.gross_premium - v_receipts, 2);
    if v_ar_out < 0 then
      raise exception 'INS_IMPORT_RECEIPTS_EXCEED_PREMIUM: policy % has % of receipts against a gross premium of %',
        pol.policy_no, v_receipts, pol.gross_premium;
    end if;
    if v_ar_out > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'gl_account_id', v_ar_gl, 'debit', v_ar_out, 'currency', pol.currency, 'description', v_desc));
      v_ar_total := v_ar_total + v_ar_out;
      v_ar_acc := public.ins_ensure_client_account(pol.client_id);
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'party_account_id', v_ar_acc, 'control_role', 'ar_control', 'source_type', 'ins_policy_premium',
        'source_id', pol.id, 'document_no', pol.policy_no, 'amount', v_ar_out,
        'currency', pol.currency, 'description', 'Opening receivable: ' || pol.policy_no));
    end if;

    select count(*) into v_share_rows
      from public.ins_policy_insurer_shares s
     where s.tenant_id = v_tenant and s.policy_id = pol.id;

    if v_share_rows = 0 then
      v_total_pay := pol.net_premium;
    else
      select coalesce(sum(round(s.payable_amount, 2)), 0) into v_total_pay
        from public.ins_policy_insurer_shares s
       where s.tenant_id = v_tenant and s.policy_id = pol.id;
    end if;
    if v_total_pay <= 0 then
      raise exception 'INS_IMPORT_NET_PREMIUM: policy % has no premium payable to an insurer', pol.policy_no;
    end if;

    v_i     := 0;
    v_alloc := 0;
    for sh in
      select s.id as share_id, s.insurer_id,
             round(s.payable_amount, 2) as payable_amount,
             round(coalesce(s.commission_amount, 0), 2) as commission_amount
        from public.ins_policy_insurer_shares s
       where s.tenant_id = v_tenant and s.policy_id = pol.id
       union all
      select null::uuid, pol.insurer_id, pol.net_premium, round(coalesce(pol.commission_amount, 0), 2)
       where v_share_rows = 0
       order by 2
    loop
      v_i := v_i + 1;
      if v_named > 0 then
        -- The source system said which insurer each remittance was paid to.
        -- This share gets exactly those, and the proportional split is not used
        -- at all: it is only ever an approximation of this.
        select coalesce(sum(m.amount), 0) into v_share_remit
          from public.ins_import_remittances m
         where m.tenant_id = v_tenant and m.batch_id = p_batch_id
           and m.policy_id = pol.id and m.insurer_id = sh.insurer_id;
      elsif v_i = greatest(v_share_rows, 1) then
        -- Policy-level history only: split by each share's payable, last one
        -- taking the rounding remainder (the documented approximation).
        v_share_remit := round(v_remits - v_alloc, 2);
      else
        v_share_remit := round(v_remits * sh.payable_amount / v_total_pay, 2);
      end if;
      v_alloc := v_alloc + v_share_remit;

      v_pay_out := round(sh.payable_amount - v_share_remit, 2);
      if v_pay_out < 0 then
        raise exception 'INS_IMPORT_REMITTANCES_EXCEED_PAYABLE: policy % insurer % is over-remitted by %',
          pol.policy_no, sh.insurer_id, -v_pay_out;
      end if;
      if v_pay_out > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'gl_account_id', v_pay_gl, 'credit', v_pay_out, 'currency', pol.currency,
          'description', v_desc || ' - insurer payable'));
        v_pay_total := v_pay_total + v_pay_out;
        v_ins_acc := public.ins_ensure_insurer_account(sh.insurer_id);
        v_items := v_items || jsonb_build_array(jsonb_build_object(
          'party_account_id', v_ins_acc, 'control_role', 'insurer_payable', 'source_type', 'ins_policy_insurer',
          'source_id', coalesce(sh.share_id, pol.id), 'document_no', pol.policy_no, 'amount', v_pay_out,
          'currency', pol.currency, 'description', 'Opening payable: ' || pol.policy_no));
      end if;

      v_comm := sh.commission_amount;
      if v_comm > 0 then
        v_earned := v_share_remit >= sh.payable_amount;
        if v_earned then
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'gl_account_id', v_retained_gl, 'credit', v_comm, 'currency', pol.currency,
            'description', v_desc || ' - commission earned at cut-over'));
          v_earn_total := v_earn_total + v_comm;
        else
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'gl_account_id', v_unearned_gl, 'credit', v_comm, 'currency', pol.currency,
            'description', v_desc || ' - unearned commission'));
          v_def_total := v_def_total + v_comm;
          insert into public.ins_commission_entries
            (tenant_id, policy_id, amount, status, insurer_share_id)
          values (v_tenant, pol.id, v_comm, 'deferred', sh.share_id);
        end if;
      end if;
    end loop;
  end loop;

  if jsonb_array_length(v_lines) = 0 then
    raise exception 'INS_IMPORT_OPENING_EMPTY: batch % has nothing to post', p_batch_id;
  end if;

  -- Self-check before the ledger sees it: every currency must balance on
  -- its own, so the entry cannot depend on an FX rounding line.
  select max(abs(d)) into v_bad
    from (
      select sum(coalesce((l ->> 'debit')::numeric, 0)) - sum(coalesce((l ->> 'credit')::numeric, 0)) as d
        from jsonb_array_elements(v_lines) l
       group by l ->> 'currency'
    ) x;
  if coalesce(v_bad, 0) > 0.005 then
    raise exception 'INS_IMPORT_OPENING_UNBALANCED: the computed opening position is out of balance by % (currency-level, before posting)',
      v_bad;
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_import_opening', p_batch_id, b.cut_over_date,
    'Opening position for import batch ' || left(p_batch_id::text, 8), v_lines);

  -- Open items after the journal, carrying its id (required for a
  -- foreign-currency item's rate).
  for it in select value from jsonb_array_elements(v_items) loop
    perform public.fin_create_open_item_fx(
      v_tenant, (it ->> 'party_account_id')::uuid, it ->> 'control_role', it ->> 'source_type',
      (it ->> 'source_id')::uuid, it ->> 'document_no', b.cut_over_date, b.cut_over_date,
      (it ->> 'amount')::numeric, it ->> 'description', it ->> 'currency', v_je.id);
    v_n_items := v_n_items + 1;
  end loop;

  reset ins.via_rpc;

  return jsonb_build_object(
    'already_posted', false,
    'batch_id', p_batch_id,
    'journal_entry_id', v_je.id,
    'open_items_created', v_n_items,
    'receivable_total', v_ar_total,
    'payable_total', v_pay_total,
    'deferred_commission_total', v_def_total,
    'earned_commission_total', v_earn_total,
    'remittances_naming_an_insurer', v_named,
    'client_money_bank_total', v_bank_total,
    'client_money_bank_by_currency', v_bank_by_ccy,
    'clearing_by_currency', v_clear_by_ccy);
end
$function$;

revoke all on function public.ins_import_post_opening_position(uuid) from public, anon;
grant execute on function public.ins_import_post_opening_position(uuid) to authenticated;
