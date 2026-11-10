-- =====================================================================
-- In-force import, step 3 rebuilt: the opening position from history.
--
-- Supersedes ins_import_post_opening_position in
-- 20261108030000_ins_import_opening_position.sql (and its 20261109100000
-- fix). Six defects, all in that one function, all fixed together because
-- they are the same calculation:
--
--   1. Balances now come from the imported payment history, not from the
--      policy header. Client receivable = billed premium minus receipts to
--      date; insurer payable = each share's net premium minus the
--      remittances allocated to it. A partially paid legacy policy no
--      longer enters the ledger owing its whole premium.
--   2. One payable per insurer share, taken from
--      ins_policy_insurer_shares, instead of the whole net premium posted
--      to the policy's lead insurer. Remittances are history rows attached
--      to the policy only, so they are allocated across the shares in
--      proportion to each share's payable, the last share taking the
--      rounding remainder; the allocation therefore always sums exactly to
--      the remitted total.
--   3. Commission follows Option A (IN_FORCE_IMPORT.md section 5,
--      decision 1): a share whose insurer net is fully remitted at
--      cut-over has already earned its commission, which is credited to
--      retained earnings; every other share's commission is carried
--      deferred and recognised by the live settlement event as before.
--      The old code deferred every share in full, settled or not, which
--      contradicted its own file header.
--   4. One opening journal per batch, with the clearing line split by
--      currency. The old single line read
--      `(select distinct currency from ins_policies where import_batch_id
--      = ...)`, which raises "more than one row returned by a subquery" on
--      any batch holding more than one currency.
--   5. The idempotency guard is the opening journal itself, not the
--      receipt history table. The old guard answered already_posted as
--      soon as any receipt row existed for the batch, so recording
--      history and then posting silently skipped the whole opening
--      position (and returned success).
--   6. Open items are created after the journal and carry its id. A
--      foreign-currency item must name the entry that booked it
--      (fin_create_open_item_fx raises OPEN_ITEM_RATE otherwise), so the
--      old code could not have posted a non-functional-currency opening
--      position at all.
--
-- What the clearing account holds: receipts minus remittances, per
-- currency - the client-money float already collected and not yet paid
-- over. It is the exact counterpart of the opening bank-balance leg
-- specified in IN_FORCE_IMPORT.md section 5 (leg 5, "client-money bank
-- balances, taken from control totals"), which is not built yet. Until it
-- is, the float sits visibly in clearing instead of being implied by a
-- receivable that overstates what clients owe.
--
-- Deliberately NOT changed here: persisting control_totals from the staged
-- sheet and the reviewer sign-off gate (review section 3.5), and the import
-- wizard. Those are the next step; this migration is the accounting.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Posting role 'retained_earnings'
--
-- Earned commission at cut-over is prior-period income. Crediting
-- commission_income would put a legacy book's whole commission into the
-- first period after go-live; equity is where it belongs. Same shape as
-- the 'opening_balance_clearing' role added in 20261109090000.
-- ---------------------------------------------------------------------
alter table public.gl_posting_rules drop constraint if exists gl_posting_rules_account_role_check;
alter table public.gl_posting_rules
  add constraint gl_posting_rules_account_role_check
  check (account_role in (
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable', 'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing',
    'retained_earnings'
  ));

create or replace function public.platform_gl_posting_roles()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing',
    'retained_earnings'
  ]::text[];
$$;
revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

-- Template account + rule for new insurance tenants, and a backfill for
-- existing ones (mirrors 20261109090000 part C).
insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('gl_account',   31, '3200',
     '{"name": "Retained Earnings", "account_type": "equity"}'::jsonb),
  ('posting_rule', 31, 'retained_earnings', '{"account_code": "3200"}'::jsonb)
) as v(kind, sort_order, name, payload)
where exists (select 1 from public.industry_templates t where t.key = 'insurance')
on conflict (template_key, kind, name) do nothing;

do $$
declare
  t    record;
  v_gl uuid;
begin
  for t in
    select distinct r.tenant_id
      from public.gl_posting_rules r
     where r.account_role = 'insurer_payable'
  loop
    if exists (select 1 from public.gl_posting_rules x
                where x.tenant_id = t.tenant_id and x.account_role = 'retained_earnings') then
      continue;
    end if;
    select id into v_gl from public.gl_accounts
     where tenant_id = t.tenant_id and account_code = '3200';
    if v_gl is null then
      insert into public.gl_accounts (tenant_id, account_code, name, account_type)
      values (t.tenant_id, '3200', 'Retained Earnings', 'equity')
      returning id into v_gl;
    elsif not exists (
      select 1 from public.gl_accounts
       where id = v_gl and account_type = 'equity' and is_active
         and name ilike '%retained%'
    ) then
      raise notice 'ins_import_opening_from_history: tenant % already uses account code 3200 for something else; map retained_earnings by hand',
        t.tenant_id;
      continue;
    end if;
    insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
    values (t.tenant_id, 'retained_earnings', v_gl)
    on conflict (tenant_id, account_role) do nothing;
  end loop;
end
$$;

-- ---------------------------------------------------------------------
-- B. History is validated, idempotent and locked once the opening
--    position is posted.
-- ---------------------------------------------------------------------
create or replace function public.ins_import_record_history(
  p_batch_id uuid, p_receipts jsonb, p_remittances jsonb
)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  b          public.ins_import_batches;
  r          jsonb;
  v_pol      public.ins_policies;
  v_date     date;
  v_amount   numeric;
  v_ref      text;
  v_have     numeric;
  v_cap      numeric;
  v_rec_n    integer := 0;
  v_rec_skip integer := 0;
  v_rem_n    integer := 0;
  v_rem_skip integer := 0;
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
  if exists (select 1 from public.journal_entries
              where tenant_id = v_tenant and source_type = 'ins_import_opening'
                and source_id = p_batch_id) then
    raise exception 'INS_IMPORT_OPENING_POSTED: the opening position is posted; history can no longer change';
  end if;

  set local ins.via_rpc = 'on';

  for r in select * from jsonb_array_elements(coalesce(p_receipts, '[]'::jsonb)) loop
    v_date   := (r ->> 'receipt_date')::date;
    v_amount := (r ->> 'amount')::numeric;
    v_ref    := nullif(btrim(coalesce(r ->> 'reference', '')), '');
    if v_date is null then
      raise exception 'INS_IMPORT_RECEIPT_DATE: every receipt needs a receipt_date';
    end if;
    if v_date > b.cut_over_date then
      raise exception 'INS_IMPORT_HISTORY_AFTER_CUTOFF: receipt dated % is after the cut-over date %',
        v_date, b.cut_over_date;
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'INS_IMPORT_RECEIPT_AMOUNT: every receipt needs an amount above zero';
    end if;
    select * into v_pol from public.ins_policies
     where tenant_id = v_tenant and id = (r ->> 'policy_id')::uuid
       and import_batch_id = p_batch_id;
    if not found then
      raise exception 'INS_IMPORT_POLICY_NOT_IN_BATCH: policy % is not in this batch',
        coalesce(r ->> 'policy_id', '(blank)');
    end if;

    if exists (select 1 from public.ins_import_receipts x
                where x.tenant_id = v_tenant and x.batch_id = p_batch_id
                  and x.policy_id = v_pol.id and x.receipt_date = v_date
                  and x.amount = v_amount and x.reference is not distinct from v_ref) then
      v_rec_skip := v_rec_skip + 1;
    else
      select coalesce(sum(x.amount), 0) into v_have
        from public.ins_import_receipts x
       where x.tenant_id = v_tenant and x.batch_id = p_batch_id and x.policy_id = v_pol.id;
      if v_have + v_amount > v_pol.gross_premium then
        raise exception 'INS_IMPORT_RECEIPTS_EXCEED_PREMIUM: receipts for policy % would total % against a gross premium of %',
          v_pol.policy_no, v_have + v_amount, v_pol.gross_premium;
      end if;
      insert into public.ins_import_receipts
        (tenant_id, batch_id, policy_id, receipt_date, reference, amount)
      values (v_tenant, p_batch_id, v_pol.id, v_date, v_ref, v_amount);
      v_rec_n := v_rec_n + 1;
    end if;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_remittances, '[]'::jsonb)) loop
    v_date   := (r ->> 'remit_date')::date;
    v_amount := (r ->> 'amount')::numeric;
    v_ref    := nullif(btrim(coalesce(r ->> 'reference', '')), '');
    if v_date is null then
      raise exception 'INS_IMPORT_REMITTANCE_DATE: every remittance needs a remit_date';
    end if;
    if v_date > b.cut_over_date then
      raise exception 'INS_IMPORT_HISTORY_AFTER_CUTOFF: remittance dated % is after the cut-over date %',
        v_date, b.cut_over_date;
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'INS_IMPORT_REMITTANCE_AMOUNT: every remittance needs an amount above zero';
    end if;
    select * into v_pol from public.ins_policies
     where tenant_id = v_tenant and id = (r ->> 'policy_id')::uuid
       and import_batch_id = p_batch_id;
    if not found then
      raise exception 'INS_IMPORT_POLICY_NOT_IN_BATCH: policy % is not in this batch',
        coalesce(r ->> 'policy_id', '(blank)');
    end if;

    if exists (select 1 from public.ins_import_remittances x
                where x.tenant_id = v_tenant and x.batch_id = p_batch_id
                  and x.policy_id = v_pol.id and x.remit_date = v_date
                  and x.amount = v_amount and x.reference is not distinct from v_ref) then
      v_rem_skip := v_rem_skip + 1;
    else
      v_cap := round(v_pol.gross_premium - coalesce(v_pol.commission_amount, 0), 2);
      select coalesce(sum(x.amount), 0) into v_have
        from public.ins_import_remittances x
       where x.tenant_id = v_tenant and x.batch_id = p_batch_id and x.policy_id = v_pol.id;
      if v_have + v_amount > v_cap then
        raise exception 'INS_IMPORT_REMITTANCES_EXCEED_PAYABLE: remittances for policy % would total % against a net premium of %',
          v_pol.policy_no, v_have + v_amount, v_cap;
      end if;
      insert into public.ins_import_remittances
        (tenant_id, batch_id, policy_id, remit_date, reference, amount)
      values (v_tenant, p_batch_id, v_pol.id, v_date, v_ref, v_amount);
      v_rem_n := v_rem_n + 1;
    end if;
  end loop;

  reset ins.via_rpc;

  return jsonb_build_object(
    'batch_id', p_batch_id,
    'receipts_recorded', v_rec_n,
    'receipts_already_present', v_rec_skip,
    'remittances_recorded', v_rem_n,
    'remittances_already_present', v_rem_skip);
end $$;

-- ---------------------------------------------------------------------
-- C. The opening position
-- ---------------------------------------------------------------------
create or replace function public.ins_import_post_opening_position(p_batch_id uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant      uuid := public.get_my_tenant_id();
  b             public.ins_import_batches;
  v_existing    uuid;
  v_je          public.journal_entries;
  v_lines       jsonb := '[]'::jsonb;
  v_items       jsonb := '[]'::jsonb;
  v_desc        text;
  v_ar_gl       uuid; v_pay_gl uuid; v_unearned_gl uuid; v_clearing_gl uuid; v_retained_gl uuid;
  v_ar_acc      uuid; v_ins_acc uuid;
  pol           record;
  sh            record;
  v_receipts    numeric;
  v_remits      numeric;
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
      -- Remittances attach to the policy, not the share: split them by each
      -- share's payable, last one taking the rounding remainder.
      if v_i = greatest(v_share_rows, 1) then
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
    'clearing_by_currency', v_clear_by_ccy);
end $$;

revoke all on function public.ins_import_post_opening_position(uuid) from public, anon;
revoke all on function public.ins_import_record_history(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.ins_import_post_opening_position(uuid) to authenticated;
grant execute on function public.ins_import_record_history(uuid, jsonb, jsonb) to authenticated;
