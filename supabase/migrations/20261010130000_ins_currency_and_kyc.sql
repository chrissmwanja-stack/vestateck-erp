-- Insurance core hardening, part 2.
--
-- 1. ins_bind_policy refuses a policy whose currency differs from the tenant's
--    ledger currency. Before this a USD policy bound and posted its face amount
--    as UGX (the open items carry the ledger currency), and the D4 settlement
--    path refuses non-ledger bank accounts anyway. Multi-currency is a design
--    decision for later; until then the bind says so instead of misposting.
--    Drafts in another currency can still be saved; they just cannot be bound.
--    The function body is otherwise identical to 20261010100000.
-- 2. KYC approval is a manager decision. Members register and maintain client
--    profiles, but only insurance admins and managers (or an RPC) can set
--    kyc_status to anything other than 'pending' or change it afterwards.
--
-- Re-runnable: create or replace only.

-- =====================================================================
-- 1. Bind refuses non-ledger currencies
-- =====================================================================
create or replace function public.ins_bind_policy(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pol        ins_policies%rowtype;
  v_client     ins_clients%rowtype;
  v_client_nm  text;
  v_comm       numeric(18,2);
  v_net        numeric(18,2);
  v_ar_acc     uuid;
  v_ins_acc    uuid;
  v_ar_gl      uuid;
  v_payable_gl uuid;
  v_comm_gl    uuid;
  v_lines      jsonb;
  v_je         journal_entries;
  v_desc       text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can bind policies' using errcode = '42501';
  end if;

  select * into v_pol from ins_policies where id = p_policy_id for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform assert_tenant_access(v_pol.tenant_id);

  if v_pol.status <> 'draft' then
    raise exception 'INS_NOT_DRAFT: policy % is already %', v_pol.policy_no, v_pol.status;
  end if;
  if v_pol.gross_premium <= 0 then
    raise exception 'INS_PREMIUM_REQUIRED: enter the gross premium before binding';
  end if;
  if v_pol.currency is distinct from fin_ledger_currency(v_pol.tenant_id) then
    raise exception 'INS_CURRENCY_UNSUPPORTED: policies bind in the ledger currency (%) only until multi-currency is designed (policy is %)',
      fin_ledger_currency(v_pol.tenant_id), v_pol.currency;
  end if;

  v_comm := round(v_pol.gross_premium * v_pol.commission_rate_pct / 100, 2);
  v_net  := v_pol.gross_premium - v_comm;
  if v_net <= 0 then
    raise exception 'INS_COMMISSION_TOO_HIGH: commission would leave nothing to remit to the insurer';
  end if;

  -- Posting roles from the tenant's chart. Missing roles stop the bind.
  v_ar_gl      := get_posting_account(v_pol.tenant_id, 'ar_control');
  v_payable_gl := get_posting_account(v_pol.tenant_id, 'insurer_payable');
  v_comm_gl    := get_posting_account(v_pol.tenant_id, 'commission_income');
  if v_ar_gl is null or v_payable_gl is null or (v_comm > 0 and v_comm_gl is null) then
    raise exception 'INS_POSTING_RULE_MISSING: the chart of accounts needs ar_control, insurer_payable and commission_income';
  end if;

  select * into v_client from ins_clients where id = v_pol.client_id;
  select name into v_client_nm from bd_clients where id = v_client.client_id;
  v_ar_acc  := ins_ensure_client_account(v_pol.client_id);
  v_ins_acc := ins_ensure_insurer_account(v_pol.insurer_id);

  v_desc := 'Bind ' || v_pol.policy_no || ' (' || coalesce(v_client_nm, 'client') || ')';
  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ar_gl, 'debit', v_pol.gross_premium, 'description', v_desc),
    jsonb_build_object('gl_account_id', v_payable_gl, 'credit', v_net, 'description', v_desc)
  );
  if v_comm > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_comm_gl, 'credit', v_comm, 'description', v_desc)
    );
  end if;

  -- Booked on the inception date, so the period-close check applies to it.
  v_je := post_journal_entry(v_pol.tenant_id, 'ins_policy_bind', v_pol.id, v_pol.inception_date, v_desc, v_lines);

  perform fin_create_open_item(
    v_pol.tenant_id, v_ar_acc, 'ar_control', 'ins_policy_premium', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_pol.gross_premium,
    'Premium due: ' || v_pol.policy_no
  );
  perform fin_create_open_item(
    v_pol.tenant_id, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_net,
    'Net premium payable to insurer: ' || v_pol.policy_no
  );

  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies
     set status = 'active',
         commission_amount = v_comm,
         net_premium_to_insurer = v_net,
         bound_at = now(),
         bound_by = auth.uid(),
         journal_entry_id = v_je.id
   where id = v_pol.id
  returning * into v_pol;

  if v_pol.renewal_of_id is not null then
    update ins_policies set status = 'renewed'
     where id = v_pol.renewal_of_id and tenant_id = v_pol.tenant_id and status = 'active';
  end if;

  return v_pol;
end;
$$;

-- =====================================================================
-- 2. KYC status is manager-only
-- =====================================================================
create or replace function public.ins_clients_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.client_id is distinct from old.client_id then
    raise exception 'INS_IMMUTABLE: the BD client link cannot be changed';
  end if;
  if tg_op = 'UPDATE' and new.party_account_id is distinct from old.party_account_id and not public.ins_via_rpc() then
    raise exception 'INS_PARTY_ACCOUNT_RPC_ONLY: the party account is managed by binding a policy' using errcode = '42501';
  end if;
  if not public.ins_via_rpc() and not public.can_manage_insurance() then
    if tg_op = 'INSERT' and new.kyc_status is distinct from 'pending' then
      raise exception 'INS_KYC_MANAGER_ONLY: new clients start as pending; a manager verifies KYC' using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and new.kyc_status is distinct from old.kyc_status then
      raise exception 'INS_KYC_MANAGER_ONLY: only insurance admins and managers can change KYC status' using errcode = '42501';
    end if;
  end if;
  if not exists (select 1 from bd_clients c where c.id = new.client_id and c.tenant_id = new.tenant_id) then
    raise exception 'INS_CROSS_TENANT: the BD client belongs to another tenant';
  end if;
  if new.party_account_id is not null and not exists (
    select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id
  ) then
    raise exception 'INS_CROSS_TENANT: party account belongs to another tenant';
  end if;
  return new;
end;
$$;