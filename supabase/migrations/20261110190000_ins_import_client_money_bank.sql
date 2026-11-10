-- =====================================================================
-- In-force import: leg 4, the client-money bank balance at cut-over.
--
-- IN_FORCE_IMPORT.md section 4.5 lists five opening legs. Four shipped in
-- 20261110120000; the fifth - "client-money bank balances, taken from
-- control totals" - did not, so the float a legacy broker is actually
-- holding sat in opening_balance_clearing forever and the clearing account
-- could never net to zero, which is the one assertion the doc asks for.
--
-- The rule here:
--
--   * what the history says should be in the bank is receipts minus
--     remittances per currency (call it the float);
--   * the balance sheet gets the balance the reviewer counted at cut-over,
--     recorded as a control total (column `client_money`, aliases allowed);
--   * clearing carries whatever the history cannot explain, i.e.
--     float minus recorded balance. When the reviewer's number and the
--     history agree, the clearing line is not posted at all.
--
-- So the opening position stops being self-balancing by construction and
-- starts agreeing with the legacy ledger - and where it does not agree, the
-- difference is visible in a named account instead of being assumed away.
--
-- The bank leg is optional. A batch whose control totals record no bank
-- balance posts exactly as it did before (clearing takes the float), and a
-- tenant without a client_money_bank rule is not forced to have one.
--
-- Also here: reconciliation gains the matching measure (client_money), so the
-- reviewer's balance is compared with the float before anything is posted,
-- and because a recorded measure is binding (20261110170000), a bank balance
-- that disagrees with the history stops the commit until it is corrected or
-- approved by someone other than the uploader.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. The canonical totals learn one more measure
-- ---------------------------------------------------------------------
create or replace function public.ins_import_sync_control_totals(p_batch_id uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid;
  v_totals jsonb;
begin
  select b.tenant_id into v_tenant from public.ins_import_batches b where b.id = p_batch_id;
  if v_tenant is null then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(v.vals || jsonb_build_object('currency', v.currency)
                            order by v.currency), '[]'::jsonb)
    into v_totals
    from (
      select distinct on (upper(btrim(x.raw ->> 'currency')))
             upper(btrim(x.raw ->> 'currency')) as currency,
             jsonb_strip_nulls(jsonb_build_object(
               'policy_count',        public.ins_import_pick_num(x.raw, array['policy_count','policies','policy count']),
               'gross_premium',       public.ins_import_pick_num(x.raw, array['gross_premium','gross premium','gross']),
               'commission',          public.ins_import_pick_num(x.raw, array['commission','commission_amount','commission amount']),
               'receipts',            public.ins_import_pick_num(x.raw, array['receipts','receipts_to_date','receipts to date','receipts_todate']),
               'remittances',         public.ins_import_pick_num(x.raw, array['remittances','remittances_to_date','remittances to date','remittances_todate']),
               'receivables',         public.ins_import_pick_num(x.raw, array['receivables','receivable','outstanding_receivable']),
               'payables',            public.ins_import_pick_num(x.raw, array['payables','insurer_payables','insurer payables','payable']),
               'unearned_commission', public.ins_import_pick_num(x.raw, array['unearned_commission','unearned commission','deferred_commission']),
               'client_money',        public.ins_import_pick_num(x.raw, array['client_money','client money','client_money_bank','client money bank','client_money_balance','bank','bank_balance','bank balance','cash'])
             )) as vals
        from public.ins_import_rows x
       where x.batch_id = p_batch_id
         and x.tenant_id = v_tenant
         and x.sheet = 'control_totals'
         and x.status = 'valid'
         and nullif(btrim(x.raw ->> 'currency'), '') is not null
       order by upper(btrim(x.raw ->> 'currency')), x.line
    ) v;

  update public.ins_import_batches
     set control_totals = v_totals,
         control_totals_synced_at = now(),
         updated_at = now()
   where id = p_batch_id and tenant_id = v_tenant
     and control_totals is distinct from v_totals;

  return v_totals;
end $$;
revoke all on function public.ins_import_sync_control_totals(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- B. Reconciliation gains the bank measure
--
-- imported = the float the history implies (receipts minus remittances),
-- control  = the balance the reviewer counted. NULL when they recorded none.
-- ---------------------------------------------------------------------
create or replace function public.ins_import_control_rows(p_batch_id uuid)
returns table (currency text, measure text, imported_amount numeric, control_amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant    uuid;
  v_status    text;
  v_totals    jsonb;
  v_committed boolean;
begin
  select b.tenant_id, b.status, coalesce(b.control_totals, '[]'::jsonb)
    into v_tenant, v_status, v_totals
    from public.ins_import_batches b
   where b.id = p_batch_id;
  if v_status is null then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;

  v_committed := (v_status = 'committed');

  return query
  with src as (
    select p.currency as currency,
           p.gross_premium as gross,
           coalesce(p.commission_amount, 0) as comm,
           coalesce((select sum(r.amount) from public.ins_import_receipts r
                      where r.tenant_id = v_tenant and r.batch_id = p_batch_id
                        and r.policy_id = p.id), 0) as receipts,
           coalesce((select sum(m.amount) from public.ins_import_remittances m
                      where m.tenant_id = v_tenant and m.batch_id = p_batch_id
                        and m.policy_id = p.id), 0) as remits
      from public.ins_policies p
     where v_committed
       and p.tenant_id = v_tenant and p.import_batch_id = p_batch_id
    union all
    select upper(btrim(x.resolved ->> 'currency')),
           coalesce(public.platform_ins_import_num(x.resolved ->> 'gross_premium'), 0),
           coalesce(public.platform_ins_import_num(x.resolved ->> 'commission_amount'), 0),
           coalesce((select sum(public.platform_ins_import_num(y.raw ->> 'amount'))
                       from public.ins_import_rows y
                      where y.tenant_id = v_tenant and y.batch_id = p_batch_id
                        and y.sheet = 'receipts' and y.status = 'valid'
                        and btrim(y.raw ->> 'legacy_policy_no') = btrim(x.raw ->> 'legacy_policy_no')), 0),
           coalesce((select sum(public.platform_ins_import_num(y.raw ->> 'amount'))
                       from public.ins_import_rows y
                      where y.tenant_id = v_tenant and y.batch_id = p_batch_id
                        and y.sheet = 'remittances' and y.status = 'valid'
                        and btrim(y.raw ->> 'legacy_policy_no') = btrim(x.raw ->> 'legacy_policy_no')), 0)
      from public.ins_import_rows x
     where not v_committed
       and x.tenant_id = v_tenant and x.batch_id = p_batch_id
       and x.sheet = 'policies' and x.status = 'valid'
       and nullif(btrim(x.resolved ->> 'currency'), '') is not null
  ),
  imp as (
    select s.currency, sum(s.gross) as gross, sum(s.comm) as comm,
           sum(s.receipts) as receipts, sum(s.remits) as remits
      from src s
     group by s.currency
  )
  select i.currency,
         m.measure,
         m.amt,
         (select case m.measure
                   when 'gross_premium'       then (c ->> 'gross_premium')::numeric
                   when 'commission'          then (c ->> 'commission')::numeric
                   when 'receipts_to_date'    then (c ->> 'receipts')::numeric
                   when 'remittances_to_date' then (c ->> 'remittances')::numeric
                   when 'client_money'        then (c ->> 'client_money')::numeric
                 end
            from jsonb_array_elements(v_totals) c
           where upper(c ->> 'currency') = upper(i.currency)
           limit 1)
    from imp i
    cross join lateral (values
      ('gross_premium', i.gross),
      ('commission', i.comm),
      ('receipts_to_date', i.receipts),
      ('remittances_to_date', i.remits),
      ('client_money', round(i.receipts - i.remits, 2))) m(measure, amt)
   order by i.currency, m.measure;
end $$;
revoke all on function public.ins_import_control_rows(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- C. The opening position posts leg 4
--
-- Everything from 20261110120000, plus the bank leg in the per-currency
-- clearing loop and two keys in the payload.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ins_import_post_opening_position(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
    'client_money_bank_total', v_bank_total,
    'client_money_bank_by_currency', v_bank_by_ccy,
    'clearing_by_currency', v_clear_by_ccy);
end $function$;



revoke all on function public.ins_import_post_opening_position(uuid) from public, anon;
grant execute on function public.ins_import_post_opening_position(uuid) to authenticated;
