-- Restricted policy reversal: two consuming credit notes, current-date accounting,
-- optional draft reissue. Voided movements are not permanent blockers.
-- No existing migration is edited. No client-controlled exemption flag is used.

alter table public.ins_policies drop constraint if exists ins_policies_status_check;
alter table public.ins_policies add constraint ins_policies_status_check
  check (status in ('draft','active','renewed','reversed'));

create table public.ins_policy_reversals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  original_policy_id uuid not null unique,
  replacement_policy_id uuid unique,
  request_key uuid not null,
  reason text not null check (length(btrim(reason)) >= 5),
  reissue_requested boolean not null,
  accounting_treatment text not null check (accounting_treatment in ('deferred','legacy','none')),
  original_journal_entry_id uuid not null references public.journal_entries(id),
  premium_credit_note_id uuid references public.fin_credit_notes(id),
  insurer_credit_note_id uuid references public.fin_credit_notes(id),
  premium_journal_entry_id uuid references public.journal_entries(id),
  insurer_journal_entry_id uuid references public.journal_entries(id),
  reversed_by uuid not null default auth.uid(),
  reversed_at timestamptz not null default now(),
  reversal_date date not null default current_date,
  outcome text not null default 'building' check (outcome in ('building','posted')),
  operation_txid bigint not null default txid_current(),
  unique (tenant_id, request_key),
  foreign key (tenant_id, original_policy_id) references public.ins_policies(tenant_id,id),
  foreign key (tenant_id, replacement_policy_id) references public.ins_policies(tenant_id,id)
);
create index ins_policy_reversals_tenant_idx on public.ins_policy_reversals(tenant_id);
create index ins_policy_reversals_original_journal_idx on public.ins_policy_reversals(original_journal_entry_id);
create index ins_policy_reversals_premium_note_idx on public.ins_policy_reversals(premium_credit_note_id);
create index ins_policy_reversals_insurer_note_idx on public.ins_policy_reversals(insurer_credit_note_id);
create index ins_policy_reversals_premium_journal_idx on public.ins_policy_reversals(premium_journal_entry_id);
create index ins_policy_reversals_insurer_journal_idx on public.ins_policy_reversals(insurer_journal_entry_id);
alter table public.ins_policy_reversals enable row level security;
revoke all on public.ins_policy_reversals from public, anon, authenticated;
grant select on public.ins_policy_reversals to authenticated;
create policy ins_policy_reversals_select on public.ins_policy_reversals for select to authenticated
  using (tenant_id = get_my_tenant_id() and can_access_insurance());

-- Private context/eligibility check. The durable operation row, writable only by
-- the definer RPC, authorizes its two exact consuming documents, not a custom GUC.
create or replace function public.ins_policy_reversal_context(p_policy_id uuid, p_in_progress boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p ins_policies%rowtype; r ins_policy_reversals%rowtype;
  a fin_open_items%rowtype; b fin_open_items%rowtype;
  ar uuid; payable uuid; offset_id uuid; treatment text := 'none';
  je journal_entries%rowtype; n integer; ce ins_commission_entries%rowtype;
begin
  if not can_manage_insurance() or effective_user_id() is distinct from auth.uid() then
    raise exception 'INS_FORBIDDEN: insurance manager required; user-level impersonation cannot reverse policies' using errcode='42501';
  end if;
  select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status <> 'active' then raise exception 'INS_REVERSAL_STATE: only active policies can be reversed'; end if;
  if p.renewal_of_id is not null or exists(select 1 from ins_policies where renewal_of_id=p.id) then
    raise exception 'INS_REVERSAL_RENEWAL: renewal chains require finance review';
  end if;
  if exists(select 1 from ins_claims where policy_id=p.id) then
    raise exception 'INS_REVERSAL_CLAIM: this policy has a claim; use the future cancellation/refunds workflow';
  end if;
  if exists(select 1 from accounting_periods where tenant_id=p.tenant_id and status='closed'
            and current_date between period_start and period_end) then
    raise exception 'INS_REVERSAL_PERIOD: the current accounting period is closed';
  end if;
  -- Same deterministic item order as the shared settlement/credit machinery.
  perform id from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type in ('ins_policy_premium','ins_policy_insurer') order by id for update;
  select * into a from fin_open_items where tenant_id=p.tenant_id and source_id=p.id and source_type='ins_policy_premium';
  select * into b from fin_open_items where tenant_id=p.tenant_id and source_id=p.id and source_type='ins_policy_insurer';
  select count(*) into n from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type in ('ins_policy_premium','ins_policy_insurer');
  if n<>2 or a.control_role<>'ar_control' or b.control_role<>'insurer_payable'
     or a.amount is distinct from p.gross_premium or b.amount is distinct from p.net_premium_to_insurer
     or a.currency is distinct from p.currency or b.currency is distinct from p.currency then
    raise exception 'INS_REVERSAL_HISTORY: original open items do not reconcile; finance review required';
  end if;
  select * into r from ins_policy_reversals where original_policy_id=p.id;
  if p_in_progress and (r.id is null or r.outcome<>'building' or r.operation_txid<>txid_current()
     or r.reversed_by is distinct from auth.uid()) then
    raise exception 'INS_REVERSAL_INTERNAL: no authorized reversal transaction';
  end if;
  if exists(select 1 from fin_allocations x join fin_settlements s on s.id=x.settlement_id
       where x.open_item_id in (a.id,b.id) and s.status='posted')
     or exists(select 1 from fin_credit_applications x join fin_credit_notes c on c.id=x.credit_note_id
       where x.open_item_id in (a.id,b.id) and c.status='posted'
       and (not p_in_progress or c.id is distinct from r.premium_credit_note_id
            and c.id is distinct from r.insurer_credit_note_id)) then
    raise exception 'INS_REVERSAL_MOVEMENT: effective payment or credit remains; use cancellation/refunds';
  end if;
  select * into ce from ins_commission_entries where policy_id=p.id for update;
  if ce.id is not null and (ce.status<>'deferred' or ce.earned_on is not null or ce.transfer_id is not null) then
    raise exception 'INS_REVERSAL_COMMISSION: effective recognition or commission transfer remains';
  end if;
  select * into je from journal_entries where id=p.journal_entry_id and tenant_id=p.tenant_id for update;
  if not found or je.status<>'posted' or je.source_type<>'ins_policy_bind' or je.source_id is distinct from p.id then
    raise exception 'INS_REVERSAL_HISTORY: original bind journal is missing or void; finance review required';
  end if;
  ar:=get_posting_account(p.tenant_id,'ar_control');
  payable:=get_posting_account(p.tenant_id,'insurer_payable');
  select count(*) into n from journal_entry_lines where journal_entry_id=je.id;
  if n <> (case when p.commission_amount>0 then 3 else 2 end)
    or not exists(select 1 from journal_entry_lines where journal_entry_id=je.id and gl_account_id=ar and debit=p.gross_premium and credit=0)
    or not exists(select 1 from journal_entry_lines where journal_entry_id=je.id and gl_account_id=payable and credit=p.net_premium_to_insurer and debit=0) then
    raise exception 'INS_REVERSAL_HISTORY: bind amounts or historical control mappings do not reconcile';
  end if;
  if p.commission_amount>0 then
    select gl_account_id into offset_id from journal_entry_lines where journal_entry_id=je.id
      and credit=p.commission_amount and debit=0 and gl_account_id not in (ar,payable);
    if offset_id=get_posting_account(p.tenant_id,'unearned_commission') then treatment:='deferred';
    elsif offset_id=get_posting_account(p.tenant_id,'commission_income') then treatment:='legacy';
    else raise exception 'INS_REVERSAL_HISTORY: historical commission mapping cannot be identified'; end if;
    if treatment='legacy' and ce.id is not null then
      raise exception 'INS_REVERSAL_HISTORY: legacy journal has an inconsistent deferred commission record';
    end if;
    if treatment='deferred' and (ce.id is null or ce.amount<>p.commission_amount) then
      raise exception 'INS_REVERSAL_HISTORY: deferred commission record does not reconcile';
    end if;
  else
    -- Zero commission: equal opposite gross offset legs cancel. Explicitly use
    -- the mapped commission-income account; missing mapping needs finance review.
    offset_id:=get_posting_account(p.tenant_id,'commission_income');
  end if;
  if offset_id is null or offset_id in (ar,payable) then
    raise exception 'INS_REVERSAL_HISTORY: a distinct commission offset mapping is required';
  end if;
  return jsonb_build_object('premium_item_id',a.id,'insurer_item_id',b.id,
    'client_party_id',a.party_account_id,'insurer_party_id',b.party_account_id,
    'offset_id',offset_id,'gross',p.gross_premium,'net',p.net_premium_to_insurer,'treatment',treatment);
end $$;
revoke all on function public.ins_policy_reversal_context(uuid,boolean) from public,anon,authenticated;

create or replace function public.ins_policy_reversal_eligibility(p_policy_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform ins_policy_reversal_context(p_policy_id);
  return jsonb_build_object('eligible',true,'reason',null);
exception when others then
  if sqlerrm like 'INS_REVERSAL_%' then return jsonb_build_object('eligible',false,'reason',sqlerrm); end if;
  raise;
end $$;
revoke all on function public.ins_policy_reversal_eligibility(uuid) from public,anon;
grant execute on function public.ins_policy_reversal_eligibility(uuid) to authenticated;

create or replace function public.platform_fin_raise_policy_credit_note_impl(
  p_tenant_id            uuid,
  p_control_role         text,
  p_party_account_id     uuid,
  p_amount               numeric,
  p_credit_date          date,
  p_offset_gl_account_id uuid,
  p_applications         jsonb,
  p_reason               text,
  p_reference            text,
  p_policy_id            uuid
)
returns public.fin_credit_notes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_context jsonb;
  v_side    text;
  v_ids     uuid[];
  v_sum     numeric;
  v_elem    jsonb;
  v_item    fin_open_items%rowtype;
  v_ctl_gl  uuid;
  v_ctl_row gl_accounts%rowtype;
  v_off_row gl_accounts%rowtype;
  v_no      text;
  v_desc    text;
  v_lines   jsonb;
  v_note    fin_credit_notes%rowtype;
  v_je      journal_entries%rowtype;
begin
  if p_tenant_id is distinct from get_my_tenant_id() or not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: insurance manager access required' using errcode = '42501';
  end if;
  v_context := ins_policy_reversal_context(p_policy_id, true);
  if (v_context->>'offset_id')::uuid is distinct from p_offset_gl_account_id
     or p_control_role not in ('ar_control','insurer_payable')
     or p_applications is distinct from jsonb_build_array(jsonb_build_object(
       'open_item_id', case when p_control_role = 'ar_control' then v_context->>'premium_item_id' else v_context->>'insurer_item_id' end,
       'amount', p_amount)) then
    raise exception 'INS_REVERSAL_OFFSET: exemption is limited to this policy and its complete open items';
  end if;
  if p_amount <> (v_context->>(case when p_control_role = 'ar_control' then 'gross' else 'net' end))::numeric then
    raise exception 'INS_REVERSAL_OFFSET: only full policy amounts are allowed';
  end if;
  if p_control_role is null or p_control_role not in ('ar_control', 'commission_receivable', 'ap_control', 'insurer_payable') then
    raise exception 'CREDIT_NOTE_INPUT: control role must be ar_control, commission_receivable, ap_control or insurer_payable';
  end if;
  v_side := case when p_control_role in ('ar_control', 'commission_receivable') then 'receivable' else 'payable' end;
  if p_amount is null or p_amount <= 0 then
    raise exception 'CREDIT_NOTE_INPUT: amount must be positive';
  end if;
  if p_credit_date is null or p_credit_date > current_date + 1 then
    raise exception 'CREDIT_NOTE_INPUT: credit date is required and cannot be in the future';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'CREDIT_NOTE_INPUT: a reason of at least 5 characters is required';
  end if;
  if p_applications is null or jsonb_typeof(p_applications) <> 'array' or jsonb_array_length(p_applications) = 0 then
    raise exception 'CREDIT_NOTE_INPUT: applications must be a non-empty array of {open_item_id, amount}';
  end if;

  v_ids := '{}';
  v_sum := 0;
  for v_elem in select * from jsonb_array_elements(p_applications) loop
    if jsonb_typeof(v_elem) <> 'object'
       or jsonb_typeof(v_elem -> 'open_item_id') <> 'string'
       or jsonb_typeof(v_elem -> 'amount') <> 'number' then
      raise exception 'CREDIT_NOTE_INPUT: each application needs an open_item_id (string) and an amount (number)';
    end if;
    if (v_elem ->> 'amount')::numeric <= 0 then
      raise exception 'CREDIT_NOTE_INPUT: application amounts must be positive';
    end if;
    if (v_elem ->> 'open_item_id')::uuid = any (v_ids) then
      raise exception 'CREDIT_NOTE_INPUT: an open item appears twice in the applications';
    end if;
    v_ids := v_ids || (v_elem ->> 'open_item_id')::uuid;
    v_sum := v_sum + (v_elem ->> 'amount')::numeric;
  end loop;
  if v_sum <> p_amount then
    raise exception 'CREDIT_NOTE_NOT_FULLY_APPLIED: applications total % but the credit note is %', v_sum, p_amount;
  end if;

  -- Lock the items in a fixed order, then check each one.
  for v_item in
    select * from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids) order by id for update
  loop
    if v_item.control_role <> p_control_role then
      raise exception 'CREDIT_NOTE_ROLE: a % credit note cannot be applied to % items (%)',
        p_control_role, v_item.control_role, v_item.document_no;
    end if;
  end loop;
  if (select count(*) from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'CREDIT_APPLICATION_ITEM: an open item was not found in this company';
  end if;

  -- Control account for the role.
  v_ctl_gl := get_posting_account(p_tenant_id, p_control_role);
  if v_ctl_gl is null then
    raise exception 'CREDIT_NOTE_UNMAPPED_ROLE: the posting role % is not mapped to a GL account', p_control_role;
  end if;
  select * into v_ctl_row from gl_accounts where id = v_ctl_gl and tenant_id = p_tenant_id;
  if not found or not v_ctl_row.is_active then
    raise exception 'CREDIT_NOTE_UNMAPPED_ROLE: the GL account for posting role % is missing or inactive', p_control_role;
  end if;

  -- Offset account: same company, active, and not a bank, client-money or control account.
  select * into v_off_row from gl_accounts where id = p_offset_gl_account_id and tenant_id = p_tenant_id;
  if not found then
    raise exception 'CREDIT_NOTE_OFFSET: the offset account was not found in this company';
  end if;
  if not v_off_row.is_active then
    raise exception 'CREDIT_NOTE_OFFSET: the offset account % is inactive', v_off_row.account_code;
  end if;
  if v_off_row.id = v_ctl_gl or (v_off_row.is_control_account and (v_context->>'offset_id')::uuid is distinct from v_off_row.id)
     or exists (
       select 1 from gl_posting_rules r
        where r.tenant_id = p_tenant_id and r.gl_account_id = v_off_row.id
          and r.account_role in ('ar_control', 'ap_control', 'commission_receivable', 'insurer_payable',
                                 'bank', 'cash', 'client_money_bank')
     )
     or exists (
       select 1 from fin_bank_accounts b where b.tenant_id = p_tenant_id and b.gl_account_id = v_off_row.id
     ) then
    raise exception 'CREDIT_NOTE_OFFSET: account % is a control, bank or client-money account and cannot be the offset', v_off_row.account_code;
  end if;

  v_no := next_doc_number(p_tenant_id, 'fin_credit_note', 'CRN');
  v_desc := 'Credit note ' || v_no;

  v_lines := case v_side
    when 'receivable' then jsonb_build_array(
      jsonb_build_object('gl_account_id', v_off_row.id, 'debit', p_amount, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_ctl_gl, 'credit', p_amount, 'description', v_desc))
    else jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ctl_gl, 'debit', p_amount, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_off_row.id, 'credit', p_amount, 'description', v_desc))
  end;

  insert into fin_credit_notes (
    tenant_id, credit_note_no, side, control_role, party_account_id, offset_gl_account_id,
    amount, currency, credit_date, reason, reference
  ) values (
    p_tenant_id, v_no, v_side, p_control_role, p_party_account_id, v_off_row.id,
    p_amount, fin_ledger_currency(p_tenant_id), p_credit_date, btrim(p_reason), nullif(btrim(p_reference), '')
  )
  returning * into v_note;

  for v_elem in select * from jsonb_array_elements(p_applications) loop
    insert into fin_credit_applications (tenant_id, credit_note_id, open_item_id, amount)
    values (p_tenant_id, v_note.id, (v_elem ->> 'open_item_id')::uuid, (v_elem ->> 'amount')::numeric);
  end loop;

  v_je := post_journal_entry(p_tenant_id, 'fin_credit_note', v_note.id, p_credit_date, v_desc || ': ' || btrim(p_reason), v_lines);

  update fin_credit_notes set journal_entry_id = v_je.id where id = v_note.id returning * into v_note;
  return v_note;
end;
$$;

revoke all on function public.platform_fin_raise_policy_credit_note_impl(uuid,text,uuid,numeric,date,uuid,jsonb,text,text,uuid) from public, anon, authenticated;

create or replace function public.ins_reverse_policy(
  p_policy_id uuid, p_reason text, p_reissue boolean, p_request_key uuid
) returns public.ins_policy_reversals
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  p ins_policies%rowtype; r ins_policy_reversals%rowtype; c jsonb;
  cn fin_credit_notes%rowtype; draft ins_policies%rowtype;
  old_flag text := coalesce(current_setting('ins.via_rpc',true),'');
begin
  if not can_manage_insurance() or effective_user_id() is distinct from auth.uid() then
    raise exception 'INS_FORBIDDEN: insurance manager required; user-level impersonation cannot reverse policies' using errcode='42501';
  end if;
  if p_request_key is null or p_reissue is null or p_reason is null or length(btrim(p_reason))<5 then
    raise exception 'INS_REVERSAL_INPUT: request key, reissue choice and a reason of at least 5 characters are required';
  end if;
  select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  select * into r from ins_policy_reversals where original_policy_id=p.id;
  if found then
    if r.request_key=p_request_key and r.reason=btrim(p_reason) and r.reissue_requested=p_reissue and r.outcome='posted' then
      return r;
    end if;
    raise exception 'INS_REVERSAL_DUPLICATE: policy already reversed with a different request';
  end if;
  if exists(select 1 from ins_policy_reversals where tenant_id=p.tenant_id and request_key=p_request_key) then
    raise exception 'INS_REVERSAL_DUPLICATE: request key already used for another policy';
  end if;
  c:=ins_policy_reversal_context(p.id);
  insert into ins_policy_reversals(tenant_id,original_policy_id,request_key,reason,reissue_requested,
    accounting_treatment,original_journal_entry_id)
  values(p.tenant_id,p.id,p_request_key,btrim(p_reason),p_reissue,c->>'treatment',p.journal_entry_id)
  returning * into r;

  cn:=platform_fin_raise_policy_credit_note_impl(p.tenant_id,'ar_control',(c->>'client_party_id')::uuid,
    p.gross_premium,current_date,(c->>'offset_id')::uuid,
    jsonb_build_array(jsonb_build_object('open_item_id',c->>'premium_item_id','amount',p.gross_premium)),
    btrim(p_reason),p.policy_no,p.id);
  update ins_policy_reversals set premium_credit_note_id=cn.id,premium_journal_entry_id=cn.journal_entry_id where id=r.id;
  cn:=platform_fin_raise_policy_credit_note_impl(p.tenant_id,'insurer_payable',(c->>'insurer_party_id')::uuid,
    p.net_premium_to_insurer,current_date,(c->>'offset_id')::uuid,
    jsonb_build_array(jsonb_build_object('open_item_id',c->>'insurer_item_id','amount',p.net_premium_to_insurer)),
    btrim(p_reason),p.policy_no,p.id);
  update ins_policy_reversals set insurer_credit_note_id=cn.id,insurer_journal_entry_id=cn.journal_entry_id where id=r.id;

  -- Compare the aggregate inverse by actual account, not just total balance.
  if exists(
    select gl_account_id from journal_entry_lines
    where journal_entry_id in (p.journal_entry_id,
      (select premium_journal_entry_id from ins_policy_reversals where id=r.id),cn.journal_entry_id)
    group by gl_account_id having sum(debit-credit)<>0
  ) then raise exception 'INS_REVERSAL_BALANCE: reversal does not negate the original bind'; end if;
  if p_reissue then
    draft:=ins_create_policy(p.client_id,p.insurer_id,p.product_line_id,p.inception_date,p.expiry_date,
      p.sum_insured,p.currency,p.gross_premium,p.commission_rate_pct,p.risk_description,p.notes);
    update ins_policy_reversals set replacement_policy_id=draft.id where id=r.id;
  end if;
  update ins_policy_reversals set outcome='posted' where id=r.id returning * into r;
  perform set_config('ins.via_rpc','on',true);
  update ins_policies set status='reversed' where id=p.id;
  perform set_config('ins.via_rpc',old_flag,true);
  perform log_platform_event('insurance.policy.reverse',p.tenant_id,'ins_policy',p.id::text,btrim(p_reason),
    jsonb_build_object('status','active','journal',p.journal_entry_id),to_jsonb(r));
  return r;
end $$;
revoke all on function public.ins_reverse_policy(uuid,text,boolean,uuid) from public,anon;
grant execute on function public.ins_reverse_policy(uuid,text,boolean,uuid) to authenticated;

-- Enforce complete operation rows at commit: a future RPC edit cannot leave an
-- incomplete durable record. SELECT-only client grants are not the only barrier.
create or replace function public.ins_reversal_complete_guard()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare r ins_policy_reversals%rowtype;
begin
  select * into r from ins_policy_reversals where id=new.id;
  if r.outcome<>'posted' or r.premium_credit_note_id is null or r.insurer_credit_note_id is null
    or r.premium_journal_entry_id is null or r.insurer_journal_entry_id is null
    or r.reissue_requested is distinct from (r.replacement_policy_id is not null)
    or not exists(select 1 from ins_policies where id=r.original_policy_id and status='reversed') then
    raise exception 'INS_REVERSAL_INCOMPLETE: reversal must be complete at commit';
  end if;
  return null;
end $$;
revoke all on function public.ins_reversal_complete_guard() from public,anon,authenticated;
create constraint trigger ins_reversal_complete after insert or update on public.ins_policy_reversals
  deferrable initially deferred for each row execute function public.ins_reversal_complete_guard();

-- Once posted, reversal evidence is immutable even to accidental definer writes.
create or replace function public.ins_reversal_immutable_guard()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if old.outcome='posted' then raise exception 'INS_REVERSAL_IMMUTABLE: reversal audit cannot be changed'; end if;
  return new;
end $$;
revoke all on function public.ins_reversal_immutable_guard() from public,anon,authenticated;
create trigger ins_reversal_immutable before update on public.ins_policy_reversals
  for each row execute function public.ins_reversal_immutable_guard();

-- All claim/renewal writers rendezvous on the original policy lock. Recheck
-- after waiting, closing the race between eligibility and a newly inserted row.
create or replace function public.ins_policy_child_guard()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; target uuid;
begin
  target:=case when tg_table_name='ins_claims' then (to_jsonb(new)->>'policy_id')::uuid
               else (to_jsonb(new)->>'renewal_of_id')::uuid end;
  if target is null then return new; end if;
  select * into p from ins_policies where id=target and tenant_id=new.tenant_id for update;
  if not found or p.status not in ('active','renewed') then
    raise exception 'INS_POLICY_UNAVAILABLE: claims and renewals require an unreversed bound policy';
  end if;
  return new;
end $$;
revoke all on function public.ins_policy_child_guard() from public,anon,authenticated;
create trigger ins_claim_policy_lock before insert on public.ins_claims for each row execute function public.ins_policy_child_guard();
create trigger ins_renewal_policy_lock before insert or update of renewal_of_id on public.ins_policies
  for each row execute function public.ins_policy_child_guard();

create or replace function public.ins_reversed_policy_guard()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if old.status='reversed' and new.status is distinct from old.status then
    raise exception 'INS_REVERSAL_LOCKED: a reversed policy cannot be reactivated';
  end if;
  if new.status='reversed' and old.status<>'reversed' and not exists(
    select 1 from ins_policy_reversals where original_policy_id=new.id and tenant_id=new.tenant_id and outcome='posted'
  ) then raise exception 'INS_REVERSAL_RPC_ONLY: use ins_reverse_policy'; end if;
  return new;
end $$;
revoke all on function public.ins_reversed_policy_guard() from public,anon,authenticated;
create trigger ins_reversed_policy_guard before update on public.ins_policies
  for each row execute function public.ins_reversed_policy_guard();

-- Guard both the note and its journals, including the generic journal-void RPC.
create or replace function public.ins_reversal_note_void_guard()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status is distinct from old.status and exists(select 1 from ins_policy_reversals
    where old.id in (premium_credit_note_id,insurer_credit_note_id)) then
    raise exception 'INS_REVERSAL_NOTE_LOCKED: reversal credit notes cannot be voided independently';
  end if;
  return new;
end $$;
revoke all on function public.ins_reversal_note_void_guard() from public,anon,authenticated;
create trigger ins_reversal_note_void before update on public.fin_credit_notes
  for each row execute function public.ins_reversal_note_void_guard();

create or replace function public.ins_reversal_journal_void_guard()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status is distinct from old.status and (
    old.source_type='ins_policy_bind' or exists(select 1 from ins_policy_reversals
      where old.id in (premium_journal_entry_id,insurer_journal_entry_id))) then
    raise exception 'INS_REVERSAL_JOURNAL_LOCKED: use the policy workflow, not independent journal voids';
  end if;
  return new;
end $$;
revoke all on function public.ins_reversal_journal_void_guard() from public,anon,authenticated;
create trigger ins_reversal_journal_void before update on public.journal_entries
  for each row execute function public.ins_reversal_journal_void_guard();

-- Keep commission evidence, but exclude reversed policies from active positions
-- and transfer selection (which reads ins_commission_entries directly).
create or replace view public.ins_commission_ledger with (security_invoker=true) as
select e.id,e.tenant_id,e.policy_id,p.policy_no,p.insurer_id,p.client_id,
  e.amount,e.status,e.earned_on,e.transfer_id,t.transfer_no,t.transfer_date,e.created_at,e.updated_at
from public.ins_commission_entries e join public.ins_policies p on p.id=e.policy_id
left join public.ins_commission_transfers t on t.id=e.transfer_id where p.status<>'reversed';
create or replace view public.ins_commission_position with (security_invoker=true) as
select e.tenant_id,
 coalesce(sum(e.amount) filter(where e.status='deferred'),0) as unearned_amount,
 coalesce(sum(e.amount) filter(where e.status='earned'),0) as earned_in_client_money,
 coalesce(sum(e.amount) filter(where e.status='transferred'),0) as transferred_amount
from public.ins_commission_entries e join public.ins_policies p on p.id=e.policy_id
where p.status<>'reversed' group by e.tenant_id;
select public.apply_tenant_read_only_guard();
