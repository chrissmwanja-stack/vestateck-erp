-- Durable cancellation proposals and independently checked current-date posting.
-- No cash is paid by approval. Cash legs remain blocked until an exact approved
-- cancellation-cash context is introduced; a generic settlement is not an escape.
-- Original bind snapshots, commission entries and posted cash are preserved.

alter table public.ins_policies drop constraint ins_policies_status_check;
alter table public.ins_policies add constraint ins_policies_status_check check(status in('draft','active','renewed','reversed','cancelled'));
-- Preserve the full installed journal source list and append just this source.
do $$ declare definition text; begin
 select pg_get_constraintdef(oid) into definition from pg_constraint where conrelid='public.journal_entries'::regclass and conname='journal_entries_source_type_check';
 if definition is null then raise exception 'INS_CANCELLATION_SCHEMA: journal source check missing'; end if;
 alter table public.journal_entries drop constraint journal_entries_source_type_check;
 execute 'alter table public.journal_entries add constraint journal_entries_source_type_check check ('||substring(definition from 8 for length(definition)-8)||' or source_type=''ins_policy_cancellation'')';
end $$;

create table public.ins_policy_cancellations (
 id uuid primary key default gen_random_uuid(), tenant_id uuid not null references public.tenants(id), policy_id uuid not null,
 request_key uuid not null, reason text not null check(length(btrim(reason)) between 5 and 2000), effective_date date not null,
 insurer_terms jsonb not null check(jsonb_typeof(insurer_terms)='array'), charge_refunds jsonb not null check(jsonb_typeof(charge_refunds)='array'),
 proposed_by uuid not null, proposed_at timestamptz not null default now(),
 status text not null default 'proposed' check(status in('proposed','prepared','posting','posted','rejected','withdrawn')),
 prepared_by uuid, prepared_at timestamptz, clearing_gl_account_id uuid,
 calculation jsonb not null, checked_by uuid, checked_at timestamptz, review_note text,
 manual_exception_accepted boolean not null default false,
 cancellation_no text, posting_date date, journal_entry_id uuid references public.journal_entries(id),
 refund_item_id uuid, cash_at_posting jsonb, accounting_mappings jsonb, operation_txid bigint,
 unique(tenant_id,id), unique(tenant_id,request_key), unique(tenant_id,cancellation_no),
 foreign key(tenant_id,policy_id) references public.ins_policies(tenant_id,id),
 foreign key(tenant_id,clearing_gl_account_id) references public.gl_accounts(tenant_id,id),
 foreign key(tenant_id,refund_item_id) references public.fin_open_items(tenant_id,id),
 check(checked_by is null or (checked_by is distinct from prepared_by and checked_by is distinct from proposed_by)),
 check(status not in('prepared','posting','posted') or (prepared_by is not null and prepared_at is not null and clearing_gl_account_id is not null)),
 check(status not in('posting','posted') or (checked_by is not null and checked_at is not null and length(btrim(review_note))>=5)),
 check((status='posting')=(operation_txid is not null)),
 check(status<>'posted' or (cancellation_no is not null and posting_date is not null and cash_at_posting is not null))
);
create unique index ins_policy_cancellations_one_live on public.ins_policy_cancellations(policy_id) where status in('proposed','prepared','posting','posted');
create index ins_policy_cancellations_status_idx on public.ins_policy_cancellations(tenant_id,status,proposed_at);
create index ins_policy_cancellations_clearing_idx on public.ins_policy_cancellations(clearing_gl_account_id);
create index ins_policy_cancellations_refund_idx on public.ins_policy_cancellations(refund_item_id);
create index ins_policy_cancellations_journal_idx on public.ins_policy_cancellations(journal_entry_id);

create table public.ins_cancellation_credit_links (
 id uuid primary key default gen_random_uuid(), tenant_id uuid not null references public.tenants(id), cancellation_id uuid not null,
 credit_note_id uuid not null unique, open_item_id uuid not null, amount numeric(18,2) not null check(amount>0),
 foreign key(tenant_id,cancellation_id) references public.ins_policy_cancellations(tenant_id,id),
 foreign key(tenant_id,open_item_id) references public.fin_open_items(tenant_id,id),
 foreign key(tenant_id,credit_note_id) references public.fin_credit_notes(tenant_id,id) deferrable initially deferred
);
create index ins_cancellation_credit_case_idx on public.ins_cancellation_credit_links(tenant_id,cancellation_id);
create index ins_cancellation_credit_item_idx on public.ins_cancellation_credit_links(open_item_id);

create table public.ins_cancellation_insurer_adjustments (
 id uuid primary key default gen_random_uuid(), tenant_id uuid not null references public.tenants(id), cancellation_id uuid not null,
 insurer_id uuid not null, insurer_share_id uuid, original_item_id uuid not null,
 original_commission_entry_id uuid references public.ins_commission_entries(id), original_commission_state jsonb,
 return_premium numeric(18,2) not null check(return_premium>=0), commission_clawback numeric(18,2) not null check(commission_clawback>=0),
 pass_through_refund numeric(18,2) not null check(pass_through_refund>=0), total_insurer_credit numeric(18,2) not null check(total_insurer_credit>=0),
 payable_credit numeric(18,2) not null check(payable_credit>=0), recovery_due numeric(18,2) not null check(recovery_due>=0), recovery_item_id uuid,
 retained_commission numeric(18,2) not null check(retained_commission>=0), retained_commission_status text not null check(retained_commission_status in('deferred','earned','transferred','legacy')),
 transferred_clawback_due numeric(18,2) not null check(transferred_clawback_due>=0),
 unique(tenant_id,id), unique(cancellation_id,insurer_id),
 foreign key(tenant_id,cancellation_id) references public.ins_policy_cancellations(tenant_id,id),
 foreign key(tenant_id,insurer_id) references public.ins_insurers(tenant_id,id),
 foreign key(tenant_id,insurer_share_id) references public.ins_policy_insurer_shares(tenant_id,id),
 foreign key(tenant_id,original_item_id) references public.fin_open_items(tenant_id,id),
 foreign key(tenant_id,recovery_item_id) references public.fin_open_items(tenant_id,id),
 check(total_insurer_credit=return_premium-commission_clawback+pass_through_refund), check(total_insurer_credit=payable_credit+recovery_due)
);
create index ins_cancel_adjust_case_idx on public.ins_cancellation_insurer_adjustments(tenant_id,cancellation_id);
create index ins_cancel_adjust_insurer_idx on public.ins_cancellation_insurer_adjustments(insurer_id);
create index ins_cancel_adjust_share_idx on public.ins_cancellation_insurer_adjustments(insurer_share_id);
create index ins_cancel_adjust_item_idx on public.ins_cancellation_insurer_adjustments(original_item_id);
create index ins_cancel_adjust_recovery_idx on public.ins_cancellation_insurer_adjustments(recovery_item_id);
create index ins_cancel_adjust_entry_idx on public.ins_cancellation_insurer_adjustments(original_commission_entry_id);

create table public.ins_cancellation_journals (
 tenant_id uuid not null references public.tenants(id), cancellation_id uuid not null,
 journal_entry_id uuid primary key references public.journal_entries(id), purpose text not null,
 foreign key(tenant_id,cancellation_id) references public.ins_policy_cancellations(tenant_id,id)
);
create index ins_cancel_journals_case_idx on public.ins_cancellation_journals(tenant_id,cancellation_id);
create table public.ins_cancellation_events (
 id uuid primary key default gen_random_uuid(), tenant_id uuid not null references public.tenants(id), cancellation_id uuid not null,
 event text not null, actor_id uuid not null, created_at timestamptz not null default now(), detail jsonb not null default '{}',
 foreign key(tenant_id,cancellation_id) references public.ins_policy_cancellations(tenant_id,id)
);
create index ins_cancel_events_case_idx on public.ins_cancellation_events(tenant_id,cancellation_id,created_at);

do $$ declare t text; begin
 foreach t in array array['ins_policy_cancellations','ins_cancellation_credit_links','ins_cancellation_insurer_adjustments','ins_cancellation_journals','ins_cancellation_events'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy %I on public.%I for select to authenticated using(tenant_id=get_my_tenant_id() and (can_access_insurance() or is_finance_team_member(''finance'')))',t||'_select',t);
 end loop;
end $$;

-- Durable approval context, not a caller-controlled session flag.
create function public.platform_ins_cancellation_context(p_id uuid) returns public.ins_policy_cancellations
language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype;
begin
 perform ins_policy_cash_require_finance();
 select * into c from ins_policy_cancellations where id=p_id and tenant_id=get_my_tenant_id();
 if not found or c.status<>'posting' or c.operation_txid<>txid_current() or c.checked_by is distinct from auth.uid()
  or c.prepared_by=auth.uid() or c.proposed_by=auth.uid() then
  raise exception 'INS_CANCELLATION_CONTEXT: independent current-transaction approval required' using errcode='42501'; end if;
 return c;
end $$;
revoke all on function public.platform_ins_cancellation_context(uuid) from public,anon,authenticated;

-- Bind accounting mappings must still identify the original accounts. A changed
-- chart/posting map is a Finance-review exception, not an invitation to silently
-- reverse the old posting into today's different control account.
create function public.platform_ins_cancellation_mappings(p_policy_id uuid,p_clearing uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; sn ins_policy_financial_snapshots%rowtype; ar uuid; pay uuid; ue uuid; income uuid; vat uuid; ap uuid;
 total numeric; payable numeric; treatment text; ch record;
begin
 perform ins_policy_cash_require_finance();
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 if not exists(select 1 from gl_accounts g where g.id=p_clearing and g.tenant_id=p.tenant_id and g.is_active and g.account_type='asset' and not g.is_control_account
   and not exists(select 1 from gl_posting_rules r where r.tenant_id=p.tenant_id and r.gl_account_id=g.id)
   and not exists(select 1 from fin_bank_accounts b where b.tenant_id=p.tenant_id and b.gl_account_id=g.id)) then
  raise exception 'INS_CANCELLATION_MAPPING: choose an active, non-bank, unmapped non-control asset clearing account'; end if;
 select * into sn from ins_policy_financial_snapshots where policy_id=p.id;
 total:=coalesce(sn.invoice_total,p.gross_premium);
 payable:=case when sn.extended then (select sum(payable_amount) from ins_policy_insurer_shares where policy_id=p.id) else p.net_premium_to_insurer end;
 ar:=get_posting_account(p.tenant_id,'ar_control'); pay:=get_posting_account(p.tenant_id,'insurer_payable');
 ue:=get_posting_account(p.tenant_id,'unearned_commission'); income:=get_posting_account(p.tenant_id,'commission_income');
 vat:=get_posting_account(p.tenant_id,'vat_output'); ap:=get_posting_account(p.tenant_id,'ap_control');
 if not exists(select 1 from journal_entries where id=p.journal_entry_id and tenant_id=p.tenant_id and source_type='ins_policy_bind' and status='posted')
  or coalesce((select sum(debit-credit) from journal_entry_lines where journal_entry_id=p.journal_entry_id and gl_account_id=ar),0)<>total
  or coalesce((select sum(credit-debit) from journal_entry_lines where journal_entry_id=p.journal_entry_id and gl_account_id=pay),0)<>payable then
  raise exception 'INS_CANCELLATION_MAPPING: original receivable/payable accounts or journal no longer reconcile'; end if;
 treatment:='none';
 if p.commission_amount>0 then
  if coalesce((select sum(credit-debit) from journal_entry_lines where journal_entry_id=p.journal_entry_id and gl_account_id=ue),0)=p.commission_amount then treatment:='deferred';
  elsif coalesce((select sum(credit-debit) from journal_entry_lines where journal_entry_id=p.journal_entry_id and gl_account_id=income),0)=p.commission_amount then treatment:='legacy';
  else raise exception 'INS_CANCELLATION_MAPPING: original commission treatment is unclear'; end if;
 end if;
 if not exists(select 1 from gl_accounts where id=ap and tenant_id=p.tenant_id and is_active and account_type='liability')
  or exists(select 1 from gl_accounts where id=any(array[ar,pay,ue,income]) and not is_active) then
  raise exception 'INS_CANCELLATION_MAPPING: active AP refund liability and original posting mappings required'; end if;
 if coalesce(sn.vat_total,0)>0 and (not exists(select 1 from gl_accounts where id=vat and tenant_id=p.tenant_id and is_active and account_type='liability')
  or coalesce((select sum(credit-debit) from journal_entry_lines where journal_entry_id=p.journal_entry_id and gl_account_id=vat),0)<>sn.vat_total) then
  raise exception 'INS_CANCELLATION_MAPPING: original VAT liability mapping changed'; end if;
 for ch in select * from ins_policy_charges where policy_id=p.id and kind='broker_fee' and amount>0 loop
  if not exists(select 1 from gl_accounts where id=ch.income_gl_account_id and tenant_id=p.tenant_id and is_active and account_type='revenue') then
   raise exception 'INS_CANCELLATION_MAPPING: original fee income account inactive'; end if;
 end loop;
 return jsonb_build_object('ar',ar,'payable',pay,'unearned',ue,'income',income,'vat',vat,'refund_payable',ap,'clearing',p_clearing,'commission_treatment',treatment);
end $$;
revoke all on function public.platform_ins_cancellation_mappings(uuid,uuid) from public,anon,authenticated;

create function public.ins_submit_policy_cancellation(p_policy_id uuid,p_effective_date date,p_insurer_terms jsonb,p_charge_refunds jsonb,p_reason text,p_request_key uuid)
returns public.ins_policy_cancellations language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; quote jsonb;
begin
 if auth.uid() is null or effective_user_id() is distinct from auth.uid() or not(can_manage_insurance() or is_finance_team_member('finance')) then
  raise exception 'INS_FORBIDDEN: Insurance manager or Finance acting as themselves required' using errcode='42501'; end if;
 if p_request_key is null or p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then raise exception 'INS_CANCELLATION_INPUT: request key and reason required'; end if;
 perform id from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 select * into c from ins_policy_cancellations where tenant_id=get_my_tenant_id() and request_key=p_request_key;
 if found then
  if c.proposed_by<>auth.uid() or c.policy_id is distinct from p_policy_id or c.effective_date is distinct from p_effective_date or c.insurer_terms is distinct from p_insurer_terms
   or c.charge_refunds is distinct from p_charge_refunds or c.reason is distinct from btrim(p_reason) then raise exception 'INS_CANCELLATION_RETRY_CONFLICT: different payload'; end if;
  return c;
 end if;
 quote:=ins_preview_policy_cancellation(p_policy_id,p_effective_date,p_insurer_terms,p_charge_refunds);
 if exists(select 1 from ins_policy_cancellations where policy_id=p_policy_id and status in('proposed','prepared','posting','posted')) then raise exception 'INS_CANCELLATION_EXISTS: a live proposal or posted cancellation already exists'; end if;
 insert into ins_policy_cancellations(tenant_id,policy_id,request_key,reason,effective_date,insurer_terms,charge_refunds,proposed_by,calculation)
 values(get_my_tenant_id(),p_policy_id,p_request_key,btrim(p_reason),p_effective_date,p_insurer_terms,p_charge_refunds,auth.uid(),quote) returning * into c;
 insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id) values(c.tenant_id,c.id,'proposed',auth.uid());
 return c;
end $$;
revoke all on function public.ins_submit_policy_cancellation(uuid,date,jsonb,jsonb,text,uuid) from public,anon;
grant execute on function public.ins_submit_policy_cancellation(uuid,date,jsonb,jsonb,text,uuid) to authenticated;

create function public.platform_ins_cancellation_review_position(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform ins_policy_cash_require_finance();
 if not exists(select 1 from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id()) then raise exception 'INS_NOT_FOUND: policy'; end if;
 if exists(select 1 from fin_settlements s join fin_allocations a on a.settlement_id=s.id join ins_policy_cash_items k on k.id=a.open_item_id
  left join journal_entries j on j.id=s.journal_entry_id where k.source_id=p_policy_id and s.status='posted' and (j.id is null or j.status<>'posted'))
 or exists(select 1 from ins_commission_events e join ins_commission_entries ce on ce.id=e.entry_id left join journal_entries j on j.id=e.journal_entry_id
  where ce.policy_id=p_policy_id and e.event in('recognised','transferred') and e.journal_entry_id is not null and j.status<>'posted') then
  raise exception 'INS_CANCELLATION_HISTORY: cash or commission journal was independently voided; Finance review required'; end if;
 return jsonb_build_object('cash_position',(select jsonb_object_agg(key,value#>>'{}') from jsonb_each(ins_policy_cash_totals(p_policy_id))),
  'insurer_balances',coalesce((select jsonb_agg(jsonb_build_object('item_id',b.id,'insurer_share_id',k.insurer_share_id,'insurer_id',coalesce((select sh.insurer_id from ins_policy_insurer_shares sh where sh.id=k.insurer_share_id),(select pp.insurer_id from ins_policies pp where pp.id=p_policy_id)),'outstanding',b.outstanding_amount::text) order by b.id)
    from fin_open_item_balances b join ins_policy_cash_items k on k.id=b.id where k.source_id=p_policy_id and k.source_type='ins_policy_insurer'),'[]'::jsonb),
  'commission_entries',coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from ins_commission_entries e where e.policy_id=p_policy_id),'[]'::jsonb));
end $$;
revoke all on function public.platform_ins_cancellation_review_position(uuid) from public,anon,authenticated;

create function public.ins_prepare_policy_cancellation(p_cancellation_id uuid,p_clearing_gl_account_id uuid)
returns public.ins_policy_cancellations language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; pid uuid; quote jsonb; mappings jsonb;
begin
 perform ins_policy_cash_require_finance();
 select policy_id into pid from ins_policy_cancellations where id=p_cancellation_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cancellation'; end if;
 perform id from ins_policies where id=pid for update;
 select * into c from ins_policy_cancellations where id=p_cancellation_id for update;
 if c.status not in('proposed','prepared') or (c.status='prepared' and c.prepared_by<>auth.uid()) then raise exception 'INS_CANCELLATION_STATE: proposal or own prepared case required'; end if;
 quote:=ins_preview_policy_cancellation(c.policy_id,c.effective_date,c.insurer_terms,c.charge_refunds)||platform_ins_cancellation_review_position(c.policy_id);
 mappings:=platform_ins_cancellation_mappings(c.policy_id,p_clearing_gl_account_id);
 update ins_policy_cancellations set status='prepared',prepared_by=auth.uid(),prepared_at=now(),calculation=quote,clearing_gl_account_id=p_clearing_gl_account_id,accounting_mappings=mappings
 where id=c.id returning * into c;
 insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id,detail) values(c.tenant_id,c.id,'finance_prepared',auth.uid(),jsonb_build_object('calculation',quote,'mappings',mappings));
 return c;
end $$;
revoke all on function public.ins_prepare_policy_cancellation(uuid,uuid) from public,anon;
grant execute on function public.ins_prepare_policy_cancellation(uuid,uuid) to authenticated;

-- Authorize precisely preassigned documents inside the independently approved
-- transaction. Existing generic credits against complex policies still fail.
create or replace function public.ins_complex_policy_credit_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare linked ins_cancellation_credit_links%rowtype; c ins_policy_cancellations%rowtype;
begin
 select * into linked from ins_cancellation_credit_links where credit_note_id=new.credit_note_id and tenant_id=new.tenant_id;
 if found then
  c:=platform_ins_cancellation_context(linked.cancellation_id);
  if linked.open_item_id<>new.open_item_id or linked.amount<>new.amount then raise exception 'INS_CANCELLATION_CONTEXT: credit outside exact authorization'; end if;
  return new;
 end if;
 if exists(select 1 from ins_policy_cash_items m join ins_policy_financial_snapshots sn on sn.policy_id=m.source_id and sn.tenant_id=m.tenant_id and sn.extended
   where m.id=new.open_item_id and m.tenant_id=new.tenant_id and m.source_type in('ins_policy_premium','ins_policy_insurer'))
  or exists(select 1 from ins_policy_cash_items m join ins_policy_cancellations c2 on c2.policy_id=m.source_id and c2.tenant_id=m.tenant_id and c2.status in('posting','posted') where m.id=new.open_item_id) then
  raise exception 'INS_CANCELLATION_REQUIRED: policy credits require the cancellation workflow'; end if;
 return new;
end $$;

create function public.platform_ins_cancellation_credit(p_cancellation_id uuid,p_item_id uuid,p_amount numeric) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; i fin_open_items%rowtype; nid uuid:=gen_random_uuid(); no text; je journal_entries%rowtype; lines jsonb; control uuid;
begin
 c:=platform_ins_cancellation_context(p_cancellation_id);
 select * into i from fin_open_items where id=p_item_id and tenant_id=c.tenant_id for update;
 if not found or i.control_role not in('ar_control','insurer_payable') or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'INS_CANCELLATION_CONTEXT: invalid original credit target'; end if;
 if not exists(select 1 from ins_policy_cash_items m where m.id=i.id and m.source_id=c.policy_id and m.source_type in('ins_policy_premium','ins_policy_insurer')) then raise exception 'INS_CANCELLATION_CONTEXT: target outside original policy'; end if;
 no:=next_doc_number(c.tenant_id,'fin_credit_note','CRN'); control:=(c.accounting_mappings->>case i.control_role when 'ar_control' then 'ar' else 'payable' end)::uuid;
 insert into ins_cancellation_credit_links(tenant_id,cancellation_id,credit_note_id,open_item_id,amount) values(c.tenant_id,c.id,nid,i.id,p_amount);
 insert into fin_credit_notes(id,tenant_id,credit_note_no,side,control_role,party_account_id,offset_gl_account_id,amount,currency,credit_date,reason,reference)
 values(nid,c.tenant_id,no,i.side,i.control_role,i.party_account_id,c.clearing_gl_account_id,p_amount,i.currency,current_date,c.reason,c.cancellation_no);
 insert into fin_credit_applications(tenant_id,credit_note_id,open_item_id,amount) values(c.tenant_id,nid,i.id,p_amount);
 lines:=case i.side when 'receivable' then jsonb_build_array(jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'debit',p_amount),jsonb_build_object('gl_account_id',control,'credit',p_amount))
 else jsonb_build_array(jsonb_build_object('gl_account_id',control,'debit',p_amount),jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'credit',p_amount)) end;
 je:=post_journal_entry(c.tenant_id,'fin_credit_note',nid,current_date,'Cancellation credit '||c.cancellation_no,lines);
 update fin_credit_notes set journal_entry_id=je.id where id=nid;
 insert into ins_cancellation_journals values(c.tenant_id,c.id,je.id,'original_item_credit');
 return nid;
end $$;
revoke all on function public.platform_ins_cancellation_credit(uuid,uuid,numeric) from public,anon,authenticated;

create function public.ins_decide_policy_cancellation(p_cancellation_id uuid,p_decision text,p_review_note text,p_accept_manual_exception boolean default false)
returns public.ins_policy_cancellations language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; p ins_policies%rowtype; pid uuid; fresh jsonb; mappings jsonb; cash jsonb;
 client_item fin_open_items%rowtype; item fin_open_items%rowtype; created_item fin_open_items%rowtype; ce ins_commission_entries%rowtype;
 line jsonb; charge jsonb; outstanding numeric; amount numeric; applied numeric; recovered numeric; remaining numeric; claw numeric;
 target_status text; adjustment_id uuid; insurer uuid; share_id uuid; lines jsonb:='[]'; debit_total numeric:=0; recognition_lines jsonb:='[]'; recognized numeric:=0;
 je journal_entries%rowtype; transfer_due numeric; client_credit numeric; refund numeric;
begin
 perform ins_policy_cash_require_finance();
 if p_decision not in('approve','reject') or p_decision is null or p_review_note is null or length(btrim(p_review_note)) not between 5 and 2000 then
  raise exception 'INS_CANCELLATION_INPUT: decision and detailed Finance review note required'; end if;
 select policy_id into pid from ins_policy_cancellations where id=p_cancellation_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cancellation'; end if;
 select * into p from ins_policies where id=pid and tenant_id=get_my_tenant_id() for update;
 select * into c from ins_policy_cancellations where id=p_cancellation_id for update;
 if c.prepared_by=auth.uid() or c.proposed_by=auth.uid() then raise exception 'INS_CANCELLATION_SELF_APPROVAL: an independent Finance checker is required'; end if;
 if c.status='posted' and p_decision='approve' and c.checked_by=auth.uid() then
  if c.review_note is distinct from btrim(p_review_note) or c.manual_exception_accepted is distinct from coalesce(p_accept_manual_exception,false) then raise exception 'INS_CANCELLATION_RETRY_CONFLICT: different approval payload'; end if;
  return c;
 end if;
 if p_decision='reject' then
  if c.status not in('proposed','prepared') then raise exception 'INS_CANCELLATION_STATE: open proposal required'; end if;
  update ins_policy_cancellations set status='rejected',checked_by=auth.uid(),checked_at=now(),review_note=btrim(p_review_note) where id=c.id returning * into c;
  insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id,detail) values(c.tenant_id,c.id,'rejected',auth.uid(),jsonb_build_object('note',p_review_note));
  return c;
 end if;
 if c.status<>'prepared' then raise exception 'INS_CANCELLATION_STATE: Finance preparation required before approval'; end if;
 -- Serialize with cash approvals, claims, credits and commission transfers.
 perform m.id from fin_open_items m join ins_policy_cash_items k on k.id=m.id where k.source_id=p.id and k.tenant_id=p.tenant_id order by m.id for update of m;
 perform e.id from ins_commission_entries e where e.policy_id=p.id order by e.id for update;
 fresh:=ins_preview_policy_cancellation(p.id,c.effective_date,c.insurer_terms,c.charge_refunds)||platform_ins_cancellation_review_position(p.id);
 if exists(select 1 from accounting_periods where tenant_id=p.tenant_id and status='closed' and current_date between period_start and period_end) then raise exception 'INS_CANCELLATION_PERIOD: current accounting period closed'; end if;
 if (fresh-'generated_at') is distinct from (c.calculation-'generated_at') then raise exception 'INS_CANCELLATION_STALE: amounts or collection position changed; Finance maker must refresh preparation'; end if;
 if (fresh->>'requires_finance_exception')::boolean and not coalesce(p_accept_manual_exception,false) then raise exception 'INS_CANCELLATION_EXCEPTION: explicit independent Finance acceptance of the documented manual exception required'; end if;
 mappings:=platform_ins_cancellation_mappings(p.id,c.clearing_gl_account_id);
 if mappings is distinct from c.accounting_mappings then raise exception 'INS_CANCELLATION_STALE: accounting mappings changed'; end if;
 cash:=ins_policy_cash_totals(p.id);
 -- Existing credits to any insurer payable would otherwise double-adjust its
 -- original bound obligations. Treat them as an exception, not as cash paid.
 if exists(select 1 from fin_credit_applications a join fin_credit_notes n on n.id=a.credit_note_id and n.status='posted'
   join ins_policy_cash_items k on k.id=a.open_item_id where k.source_id=p.id and k.source_type='ins_policy_insurer') then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: original insurer credits need separate Finance review'; end if;
 update ins_policy_cancellations set status='posting',checked_by=auth.uid(),checked_at=now(),review_note=btrim(p_review_note),manual_exception_accepted=coalesce(p_accept_manual_exception,false),
  posting_date=current_date,cancellation_no=next_doc_number(c.tenant_id,'ins_policy_cancellation','CXL'),cash_at_posting=cash,operation_txid=txid_current() where id=c.id returning * into c;
 select * into client_item from fin_open_items where tenant_id=p.tenant_id and source_type='ins_policy_premium' and source_id=p.id;
 client_credit:=(fresh->>'receivable_credit')::numeric; refund:=(fresh->>'client_refund_due')::numeric;
 if client_credit>0 then perform platform_ins_cancellation_credit(c.id,client_item.id,client_credit); end if;
 if refund>0 then
  created_item:=fin_create_open_item(c.tenant_id,client_item.party_account_id,'ap_control','ins_cancellation_client_refund',c.id,c.cancellation_no,current_date,current_date,refund,'Client refund due: '||p.policy_no);
  update ins_policy_cancellations set refund_item_id=created_item.id where id=c.id;
  lines:=lines||jsonb_build_array(jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'debit',refund),jsonb_build_object('gl_account_id',(mappings->>'refund_payable')::uuid,'credit',refund));
 end if;
 for line in select value from jsonb_array_elements(fresh->'insurers') loop
  insurer:=(line->>'insurer_id')::uuid; amount:=(line->>'total_insurer_credit')::numeric; claw:=(line->>'commission_clawback')::numeric;
  select id into share_id from ins_policy_insurer_shares where policy_id=p.id and insurer_id=insurer;
  select i.* into item from fin_open_items i join ins_policy_cash_items k on k.id=i.id
   where k.source_id=p.id and k.source_type='ins_policy_insurer' and k.tenant_id=p.tenant_id
    and (k.insurer_share_id=share_id or (k.insurer_share_id is null and insurer=p.insurer_id));
  if not found then raise exception 'INS_CANCELLATION_HISTORY: original insurer item missing'; end if;
  select outstanding_amount into outstanding from fin_open_item_balances where id=item.id;
  applied:=least(outstanding,amount); recovered:=amount-applied;
  select * into ce from ins_commission_entries where policy_id=p.id and insurer_share_id is not distinct from
   (case when exists(select 1 from ins_policy_financial_snapshots where policy_id=p.id and extended) then share_id else null end);
  if (line->>'original_commission')::numeric>0 and (mappings->>'commission_treatment')='deferred' and ce.id is null then raise exception 'INS_CANCELLATION_HISTORY: original commission entry missing'; end if;
  if ce.id is not null and ce.amount<>(line->>'original_commission')::numeric then raise exception 'INS_CANCELLATION_HISTORY: original commission amount differs'; end if;
  remaining:=(line->>'original_commission')::numeric-claw;
  target_status:=case when ce.id is null then 'legacy' when ce.status='transferred' then 'transferred' when ce.status='earned' then 'earned'
   when outstanding-applied=0 and remaining>0 then 'earned' else 'deferred' end;
  transfer_due:=case when ce.status='transferred' then claw else 0 end;
  adjustment_id:=gen_random_uuid();
  insert into ins_cancellation_insurer_adjustments(id,tenant_id,cancellation_id,insurer_id,insurer_share_id,original_item_id,original_commission_entry_id,original_commission_state,
   return_premium,commission_clawback,pass_through_refund,total_insurer_credit,payable_credit,recovery_due,retained_commission,retained_commission_status,transferred_clawback_due)
  values(adjustment_id,c.tenant_id,c.id,insurer,share_id,item.id,ce.id,case when ce.id is not null then to_jsonb(ce) else null end,
   (line->>'return_premium')::numeric,claw,(line->>'pass_through_refund')::numeric,amount,applied,recovered,remaining,target_status,transfer_due);
  if applied>0 then perform platform_ins_cancellation_credit(c.id,item.id,applied); end if;
  if recovered>0 then
   created_item:=fin_create_open_item(c.tenant_id,item.party_account_id,'ar_control','ins_cancellation_insurer_recovery',adjustment_id,c.cancellation_no,current_date,current_date,recovered,'Insurer recovery: '||p.policy_no);
   update ins_cancellation_insurer_adjustments set recovery_item_id=created_item.id where id=adjustment_id;
   lines:=lines||jsonb_build_array(jsonb_build_object('gl_account_id',(mappings->>'ar')::uuid,'debit',recovered),jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'credit',recovered));
  end if;
  if claw>0 then
   lines:=lines||jsonb_build_object('gl_account_id',(mappings->>case when ce.id is not null and ce.status='deferred' then 'unearned' else 'income' end)::uuid,'debit',claw);
   debit_total:=debit_total+claw;
  end if;
  if ce.status='deferred' and target_status='earned' and remaining>0 then
   recognition_lines:=recognition_lines||jsonb_build_array(jsonb_build_object('gl_account_id',(mappings->>'unearned')::uuid,'debit',remaining),jsonb_build_object('gl_account_id',(mappings->>'income')::uuid,'credit',remaining));
   recognized:=recognized+remaining;
  end if;
 end loop;
 for charge in select value from jsonb_array_elements(fresh->'charges') where value->>'kind'='broker_fee' loop
  if (charge->>'refund_base')::numeric>0 then
   lines:=lines||jsonb_build_object('gl_account_id',(charge->>'income_gl_account_id')::uuid,'debit',(charge->>'refund_base')::numeric);
   debit_total:=debit_total+(charge->>'refund_base')::numeric;
  end if;
  if (charge->>'refund_vat')::numeric>0 then
   lines:=lines||jsonb_build_object('gl_account_id',(mappings->>'vat')::uuid,'debit',(charge->>'refund_vat')::numeric);
   debit_total:=debit_total+(charge->>'refund_vat')::numeric;
  end if;
 end loop;
 if debit_total>0 then lines:=lines||jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'credit',debit_total); end if;
 if jsonb_array_length(lines)>0 then
  je:=post_journal_entry(c.tenant_id,'ins_policy_cancellation',c.id,current_date,'Cancellation '||c.cancellation_no||': '||c.reason,lines);
  insert into ins_cancellation_journals values(c.tenant_id,c.id,je.id,'cancellation_adjustments');
 end if;
 if recognized>0 then
  declare recognition journal_entries%rowtype; begin
   recognition:=post_journal_entry(c.tenant_id,'ins_policy_cancellation',gen_random_uuid(),current_date,'Retained commission earned: '||c.cancellation_no,recognition_lines);
   insert into ins_cancellation_journals values(c.tenant_id,c.id,recognition.id,'retained_commission_recognition');
  end;
 end if;
 update ins_policy_cancellations set status='posted',journal_entry_id=je.id,operation_txid=null where id=c.id returning * into c;
 perform set_config('ins.via_rpc','on',true);
 update ins_policies set status='cancelled' where id=p.id;
 update ins_policy_cash_requests set status='cancelled',checker_id=null,checked_at=now(),decision_reason='Policy cancellation posted: '||c.cancellation_no
  where policy_id=p.id and status='pending';
 insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id,detail) values(c.tenant_id,c.id,'posted',auth.uid(),jsonb_build_object('review_note',p_review_note,'manual_exception_accepted',p_accept_manual_exception,'cash_authorized',false));
 return c;
end $$;
revoke all on function public.ins_decide_policy_cancellation(uuid,text,text,boolean) from public,anon;
grant execute on function public.ins_decide_policy_cancellation(uuid,text,text,boolean) to authenticated;

create function public.ins_withdraw_policy_cancellation(p_cancellation_id uuid,p_reason text) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; pid uuid;
begin
 if auth.uid() is null or effective_user_id() is distinct from auth.uid() or not(can_manage_insurance() or is_finance_team_member('finance')) then raise exception 'INS_FORBIDDEN: acting identity and current role required' using errcode='42501'; end if;
 select policy_id into pid from ins_policy_cancellations where id=p_cancellation_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cancellation'; end if;
 perform id from ins_policies where id=pid for update;
 select * into c from ins_policy_cancellations where id=p_cancellation_id for update;
 if c.proposed_by<>auth.uid() or c.status not in('proposed','prepared') or length(btrim(coalesce(p_reason,'')))<5 then raise exception 'INS_CANCELLATION_WITHDRAW: proposer, open case and reason required'; end if;
 update ins_policy_cancellations set status='withdrawn',review_note=btrim(p_reason) where id=c.id;
 insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id,detail) values(c.tenant_id,c.id,'withdrawn',auth.uid(),jsonb_build_object('reason',p_reason));
end $$;
revoke all on function public.ins_withdraw_policy_cancellation(uuid,text) from public,anon;
grant execute on function public.ins_withdraw_policy_cancellation(uuid,text) to authenticated;

-- Immutable posted cases and their financial evidence, including owner paths.
create function public.ins_cancellation_evidence_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare cid uuid; c ins_policy_cancellations%rowtype;
begin
 if tg_table_name='ins_policy_cancellations' then
  if tg_op='DELETE' then raise exception 'INS_CANCELLATION_IMMUTABLE: retain cancellation audit'; end if;
  if tg_op='INSERT' then return new; end if;
  if old.status in('posted','rejected','withdrawn') then raise exception 'INS_CANCELLATION_IMMUTABLE: terminal cases cannot change'; end if;
  if (to_jsonb(new)-array['status','prepared_by','prepared_at','clearing_gl_account_id','calculation','checked_by','checked_at','review_note','manual_exception_accepted','cancellation_no','posting_date','journal_entry_id','refund_item_id','cash_at_posting','accounting_mappings','operation_txid'])
    is distinct from (to_jsonb(old)-array['status','prepared_by','prepared_at','clearing_gl_account_id','calculation','checked_by','checked_at','review_note','manual_exception_accepted','cancellation_no','posting_date','journal_entry_id','refund_item_id','cash_at_posting','accounting_mappings','operation_txid']) then
   raise exception 'INS_CANCELLATION_IMMUTABLE: proposal inputs cannot be rewritten; withdraw and resubmit'; end if;
  return new;
 end if;
 if tg_table_name='ins_cancellation_events' then
  if tg_op<>'INSERT' then raise exception 'INS_CANCELLATION_IMMUTABLE: append-only audit'; end if;
  return new;
 end if;
 cid:=case when tg_op='DELETE' then old.cancellation_id else new.cancellation_id end;
 select * into c from ins_policy_cancellations where id=cid;
 if tg_op='DELETE' or c.status<>'posting' or c.operation_txid<>txid_current() then raise exception 'INS_CANCELLATION_IMMUTABLE: financial evidence is transaction-bound and immutable'; end if;
 if tg_op='UPDATE' and (tg_table_name<>'ins_cancellation_insurer_adjustments' or (to_jsonb(new)-'recovery_item_id') is distinct from (to_jsonb(old)-'recovery_item_id')) then
  raise exception 'INS_CANCELLATION_IMMUTABLE: adjustment history cannot change'; end if;
 return new;
end $$;
revoke all on function public.ins_cancellation_evidence_guard() from public,anon,authenticated;
do $$ declare t text; begin
 foreach t in array array['ins_policy_cancellations','ins_cancellation_credit_links','ins_cancellation_insurer_adjustments','ins_cancellation_journals','ins_cancellation_events'] loop
  execute format('create trigger %I before insert or update or delete on public.%I for each row execute function public.ins_cancellation_evidence_guard()',t||'_immutable',t);
 end loop;
end $$;

create function public.ins_cancelled_policy_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.status='cancelled' and new.status is distinct from old.status then raise exception 'INS_CANCELLATION_LOCKED: cancelled policies cannot reactivate'; end if;
 if new.status='cancelled' and old.status<>'cancelled' and not exists(select 1 from ins_policy_cancellations c where c.policy_id=new.id and c.tenant_id=new.tenant_id and c.status='posted' and c.checked_by=auth.uid() and c.posting_date=current_date) then
  raise exception 'INS_CANCELLATION_CONTEXT: use the independently approved cancellation workflow'; end if;
 return new;
end $$;
revoke all on function public.ins_cancelled_policy_guard() from public,anon,authenticated;
create trigger ins_cancelled_policy_guard before update on public.ins_policies for each row execute function public.ins_cancelled_policy_guard();

-- Deferred end-of-transaction backstop: no "posting" case may be committed,
-- every credit/journal must exist and the private clearing balance must be zero.
create function public.ins_cancellation_complete_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; difference numeric;
begin
 select * into c from ins_policy_cancellations where id=new.id;
 if c.status='posting' then raise exception 'INS_CANCELLATION_INCOMPLETE: interrupted transaction'; end if;
 if c.status='posted' then
  if not exists(select 1 from ins_policies where id=c.policy_id and status='cancelled') or exists(select 1 from ins_cancellation_credit_links l left join fin_credit_notes n on n.id=l.credit_note_id where l.cancellation_id=c.id and (n.id is null or n.journal_entry_id is null or n.status<>'posted' or n.amount<>l.amount)) then
   raise exception 'INS_CANCELLATION_INCOMPLETE: missing policy state or credit document'; end if;
  select coalesce(sum(l.debit-l.credit),0) into difference from ins_cancellation_journals j join journal_entry_lines l on l.journal_entry_id=j.journal_entry_id where j.cancellation_id=c.id and l.gl_account_id=c.clearing_gl_account_id;
  if difference<>0 then raise exception 'INS_CANCELLATION_INCOMPLETE: clearing account does not reconcile'; end if;
  if (select count(*) from ins_cancellation_insurer_adjustments where cancellation_id=c.id)<>jsonb_array_length(c.calculation->'insurers')
   or coalesce((select sum(l.amount) from ins_cancellation_credit_links l join fin_open_items i on i.id=l.open_item_id where l.cancellation_id=c.id and i.source_type='ins_policy_premium'),0)<>(c.calculation->>'receivable_credit')::numeric then
   raise exception 'INS_CANCELLATION_INCOMPLETE: insurer rows or receivable credits missing'; end if;
  if ((c.calculation->>'client_refund_due')::numeric>0 and not exists(select 1 from fin_open_items i where i.id=c.refund_item_id and i.tenant_id=c.tenant_id and i.source_type='ins_cancellation_client_refund' and i.source_id=c.id and i.control_role='ap_control' and i.amount=(c.calculation->>'client_refund_due')::numeric))
    or ((c.calculation->>'client_refund_due')::numeric=0 and c.refund_item_id is not null) then raise exception 'INS_CANCELLATION_INCOMPLETE: refund liability mismatch'; end if;
  if exists(select 1 from ins_cancellation_insurer_adjustments a where a.cancellation_id=c.id and
   (a.payable_credit<>coalesce((select sum(l.amount) from ins_cancellation_credit_links l where l.cancellation_id=c.id and l.open_item_id=a.original_item_id),0)
    or (a.recovery_due>0 and not exists(select 1 from fin_open_items i where i.id=a.recovery_item_id and i.tenant_id=c.tenant_id and i.source_type='ins_cancellation_insurer_recovery' and i.source_id=a.id and i.amount=a.recovery_due)))) then
   raise exception 'INS_CANCELLATION_INCOMPLETE: insurer credits/recovery items missing'; end if;
  if exists(select 1 from ins_cancellation_journals j join journal_entries e on e.id=j.journal_entry_id where j.cancellation_id=c.id and (e.tenant_id<>c.tenant_id or e.status<>'posted' or e.entry_date<>c.posting_date)) then raise exception 'INS_CANCELLATION_INCOMPLETE: journal state/date mismatch'; end if;
 end if;
 return new;
end $$;
revoke all on function public.ins_cancellation_complete_guard() from public,anon,authenticated;
create constraint trigger ins_cancellation_complete after insert or update on public.ins_policy_cancellations deferrable initially deferred for each row execute function public.ins_cancellation_complete_guard();

-- The original documents cannot subsequently be independently voided, nor may
-- a generic cash/credit writer pay new refund/recovery open items without checks.
create function public.ins_cancellation_finance_lock_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if tg_table_name='fin_credit_notes' then
  if new.status is distinct from old.status and exists(select 1 from ins_cancellation_credit_links where credit_note_id=old.id) then raise exception 'INS_CANCELLATION_LOCKED: linked credit cannot be voided independently'; end if;
 elsif tg_table_name='journal_entries' then
  if new.status is distinct from old.status then
   perform p.id from ins_policies p where exists(select 1 from fin_settlements s join fin_allocations a on a.settlement_id=s.id join ins_policy_cash_items k on k.id=a.open_item_id
    where k.source_id=p.id and old.id in(s.journal_entry_id,s.void_journal_entry_id)) or exists(select 1 from ins_commission_events e join ins_commission_entries ce on ce.id=e.entry_id where ce.policy_id=p.id and e.journal_entry_id=old.id) order by p.id for update;
   if exists(select 1 from ins_cancellation_journals where journal_entry_id=old.id)
    or exists(select 1 from fin_settlements s join fin_allocations a on a.settlement_id=s.id join ins_policy_cash_items k on k.id=a.open_item_id
      join ins_policy_cancellations c on c.policy_id=k.source_id and c.status='posted' where old.id in(s.journal_entry_id,s.void_journal_entry_id))
    or exists(select 1 from ins_cancellation_insurer_adjustments a join ins_commission_events e on e.entry_id=a.original_commission_entry_id where e.journal_entry_id=old.id)
    or exists(select 1 from ins_cancellation_insurer_adjustments a join ins_commission_transfers t on t.id=(a.original_commission_state->>'transfer_id')::uuid where old.id in(t.journal_entry_id,t.void_journal_entry_id)) then
    raise exception 'INS_CANCELLATION_LOCKED: linked or original cash/commission journal cannot be voided independently'; end if;
  end if;
 elsif tg_table_name='fin_settlements' then
  if new.status is distinct from old.status then
   perform p.id from ins_policies p join ins_policy_cash_items k on k.source_id=p.id join fin_allocations a on a.open_item_id=k.id where a.settlement_id=old.id order by p.id for update of p;
   if exists(select 1 from fin_allocations a join ins_policy_cash_items k on k.id=a.open_item_id join ins_policy_cancellations c on c.policy_id=k.source_id and c.status='posted' where a.settlement_id=old.id) then raise exception 'INS_CANCELLATION_LOCKED: historical cash is preserved after cancellation'; end if;
  end if;
 elsif tg_table_name='ins_commission_transfers' then
  if new.status is distinct from old.status and exists(select 1 from ins_cancellation_insurer_adjustments a join ins_policy_cancellations c on c.id=a.cancellation_id and c.status='posted' where (a.original_commission_state->>'transfer_id')::uuid=old.id) then raise exception 'INS_CANCELLATION_LOCKED: historical commission transfer is preserved; recover the clawback separately'; end if;
 elsif tg_table_name='fin_allocations' then
  if exists(select 1 from fin_open_items where id=new.open_item_id and source_type in('ins_cancellation_client_refund','ins_cancellation_insurer_recovery')) then raise exception 'INS_CANCELLATION_CASH_REQUIRED: separately approved, funded cash workflow required'; end if;
 elsif tg_table_name='fin_credit_applications' then
  if exists(select 1 from fin_open_items where id=new.open_item_id and source_type in('ins_cancellation_client_refund','ins_cancellation_insurer_recovery')) then raise exception 'INS_CANCELLATION_LOCKED: cancellation balances cannot be generically credited'; end if;
 end if;
 return new;
end $$;
revoke all on function public.ins_cancellation_finance_lock_guard() from public,anon,authenticated;
create trigger ins_cancellation_note_lock before update on public.fin_credit_notes for each row execute function public.ins_cancellation_finance_lock_guard();
create trigger ins_cancellation_journal_lock before update on public.journal_entries for each row execute function public.ins_cancellation_finance_lock_guard();
create trigger ins_cancellation_settlement_lock before update on public.fin_settlements for each row execute function public.ins_cancellation_finance_lock_guard();
create trigger ins_cancellation_transfer_lock before update on public.ins_commission_transfers for each row execute function public.ins_cancellation_finance_lock_guard();
create trigger ins_cancellation_allocation_lock before insert on public.fin_allocations for each row execute function public.ins_cancellation_finance_lock_guard();
create trigger ins_cancellation_new_credit_lock before insert on public.fin_credit_applications for each row execute function public.ins_cancellation_finance_lock_guard();

-- Projection only: historical commission entries and transfer amounts are not
-- rewritten. Adjusted balances/status come from the immutable cancellation case.
create or replace view public.ins_commission_ledger with(security_invoker=true) as
select e.id,e.tenant_id,e.policy_id,p.policy_no,coalesce(s.insurer_id,p.insurer_id) as insurer_id,p.client_id,
 coalesce(a.retained_commission,e.amount)::numeric(18,2) as amount,coalesce(a.retained_commission_status,e.status) as status,coalesce(e.earned_on,case when a.retained_commission_status='earned' then c.posting_date end) as earned_on,e.transfer_id,t.transfer_no,t.transfer_date,e.created_at,e.updated_at,
 e.insurer_share_id,(coalesce(s.premium_amount,p.gross_premium)-coalesce(a.return_premium,0))::numeric(18,2) as allocated_premium,
 coalesce(s.commission_rate_pct,p.commission_rate_pct) as commission_rate_pct,
 case when coalesce(a.retained_commission_status,e.status) in('earned','transferred') then coalesce(a.retained_commission,e.amount) else 0 end as earned_commission,
 case when coalesce(a.retained_commission_status,e.status)='transferred' then 0 else coalesce(a.retained_commission,e.amount) end as untransferred_commission
from ins_commission_entries e join ins_policies p on p.id=e.policy_id
left join ins_policy_insurer_shares s on s.id=e.insurer_share_id and s.tenant_id=e.tenant_id
left join ins_commission_transfers t on t.id=e.transfer_id
left join ins_cancellation_insurer_adjustments a on a.original_commission_entry_id=e.id
left join ins_policy_cancellations c on c.id=a.cancellation_id
where p.status<>'reversed';
create or replace view public.ins_commission_position with(security_invoker=true) as
select tenant_id,coalesce(sum(amount) filter(where status='deferred'),0) as unearned_amount,
 coalesce(sum(amount) filter(where status='earned'),0) as earned_in_client_money,
 coalesce(sum(amount) filter(where status='transferred'),0) as transferred_amount
from ins_commission_ledger group by tenant_id;

-- Cancellation cash is deliberately a separate authorization path. An old
-- commission batch must not transfer unadjusted historical amounts for it.
create or replace function public.ins_transfer_earned_commission(
  p_from_bank_account_id uuid,
  p_to_bank_account_id   uuid,
  p_transfer_date        date,
  p_entry_ids            uuid[] default null,
  p_notes                text default null
)
returns public.ins_commission_transfers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_from     fin_bank_accounts%rowtype;
  v_to       fin_bank_accounts%rowtype;
  v_ids      uuid[];
  v_total    numeric(18,2);
  v_max_date date;
  v_trust    numeric;
  v_id       uuid := gen_random_uuid();
  v_no       text;
  v_je       journal_entries;
  v_tr       ins_commission_transfers%rowtype;
  v_desc     text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can transfer commission' using errcode = '42501';
  end if;
  if v_tenant is null then
    raise exception 'INS_FORBIDDEN: no company context' using errcode = '42501';
  end if;
  if p_transfer_date is null or p_transfer_date > current_date + 1 then
    raise exception 'INS_TRANSFER_INPUT: the transfer date is required and cannot be in the future';
  end if;
  if p_from_bank_account_id is null or p_to_bank_account_id is null
     or p_from_bank_account_id = p_to_bank_account_id then
    raise exception 'INS_TRANSFER_INPUT: choose a client-money bank account and a different operating bank account';
  end if;

  select * into v_from from fin_bank_accounts where id = p_from_bank_account_id and tenant_id = v_tenant for share;
  select * into v_to   from fin_bank_accounts where id = p_to_bank_account_id   and tenant_id = v_tenant for share;
  if v_from.id is null or v_to.id is null then
    raise exception 'INS_TRANSFER_BANK: bank account not found in this company';
  end if;
  if v_from.kind <> 'client_money' or v_to.kind <> 'operating' then
    raise exception 'INS_TRANSFER_BANK: commission moves from a client-money account to an operating account';
  end if;
  if not v_from.is_active or not v_to.is_active then
    raise exception 'INS_TRANSFER_BANK: both bank accounts must be active';
  end if;
  if v_from.gl_account_id is null or v_to.gl_account_id is null or v_from.gl_account_id = v_to.gl_account_id then
    raise exception 'INS_TRANSFER_BANK: each bank account needs its own mapped GL account';
  end if;
  if v_from.currency <> fin_ledger_currency(v_tenant) or v_to.currency <> fin_ledger_currency(v_tenant) then
    raise exception 'INS_TRANSFER_BANK: only % bank accounts are supported until multi-currency is designed',
      fin_ledger_currency(v_tenant);
  end if;

  select array_agg(e.id order by e.id), sum(e.amount), max(e.earned_on)
    into v_ids, v_total, v_max_date
    from ins_commission_entries e
   where e.tenant_id = v_tenant and e.status = 'earned'
     and not exists(select 1 from ins_policy_cancellations c where c.policy_id=e.policy_id and c.status='posted')
     and (p_entry_ids is null or e.id = any (p_entry_ids));
  if v_ids is null then
    raise exception 'INS_TRANSFER_NOTHING: there is no earned commission to transfer';
  end if;
  if p_entry_ids is not null and cardinality(v_ids) <> cardinality(
       (select array_agg(distinct x) from unnest(p_entry_ids) x)) then
    raise exception 'INS_TRANSFER_ENTRIES: every selected entry must be earned and not yet transferred';
  end if;
  perform 1 from ins_commission_entries where id = any (v_ids) order by id for update;

  if p_transfer_date < v_max_date then
    raise exception 'INS_TRANSFER_DATE: the transfer date cannot be before commission was earned (%)', v_max_date;
  end if;

  select coalesce(sum(l.debit - l.credit), 0) into v_trust
    from journal_entry_lines l
   where l.tenant_id = v_tenant and l.gl_account_id = v_from.gl_account_id;
  if v_trust < v_total then
    raise exception 'INS_TRANSFER_TRUST_SHORT: client-money account % holds % in the ledger, less than the % to transfer',
      v_from.name, v_trust, v_total;
  end if;

  v_no   := next_doc_number(v_tenant, 'ins_commission_transfer', 'CTR');
  v_desc := 'Commission transfer ' || v_no;

  v_je := post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_to.gl_account_id,   'debit',  v_total, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_from.gl_account_id, 'credit', v_total, 'description', v_desc)));

  insert into ins_commission_transfers (
    id, tenant_id, transfer_no, from_bank_account_id, to_bank_account_id,
    transfer_date, amount, currency, notes, journal_entry_id
  ) values (
    v_id, v_tenant, v_no, v_from.id, v_to.id,
    p_transfer_date, v_total, v_from.currency, nullif(btrim(p_notes), ''), v_je.id
  ) returning * into v_tr;

  update ins_commission_entries
     set status = 'transferred', transfer_id = v_id, updated_at = now()
   where id = any (v_ids);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transferred', e.amount, v_je.id, v_id
    from ins_commission_entries e where e.id = any (v_ids);

  return v_tr;
end;
$$;
select public.apply_tenant_read_only_guard();

alter function public.ins_transfer_earned_commission(uuid,uuid,date,uuid[],text) rename to platform_ins_transfer_before_cancellation_impl;
revoke all on function public.platform_ins_transfer_before_cancellation_impl(uuid,uuid,date,uuid[],text) from public,anon,authenticated;
create function public.ins_transfer_earned_commission(p_from_bank_account_id uuid,p_to_bank_account_id uuid,p_transfer_date date,p_entry_ids uuid[] default null,p_notes text default null)
returns public.ins_commission_transfers language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: insurance manager required' using errcode='42501'; end if;
 perform p.id from ins_policies p where p.tenant_id=get_my_tenant_id() and exists(select 1 from ins_commission_entries e where e.policy_id=p.id and e.status='earned' and (p_entry_ids is null or e.id=any(p_entry_ids))) order by p.id for update;
 return platform_ins_transfer_before_cancellation_impl(p_from_bank_account_id,p_to_bank_account_id,p_transfer_date,p_entry_ids,p_notes);
end $$;
revoke all on function public.ins_transfer_earned_commission(uuid,uuid,date,uuid[],text) from public,anon;
grant execute on function public.ins_transfer_earned_commission(uuid,uuid,date,uuid[],text) to authenticated;

create function public.ins_policy_cancellation_context(p_policy_id uuid,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; sn ins_policy_financial_snapshots%rowtype; shares jsonb; charge jsonb; charges jsonb:='[]'; parts jsonb; cases jsonb; accounts jsonb:='[]';
begin
 if auth.uid() is null or not(can_access_insurance() or is_finance_team_member('finance')) then raise exception 'INS_FORBIDDEN: Insurance or Finance required' using errcode='42501'; end if;
 if p_offset is null or p_offset<0 then raise exception 'INS_REPORT_PAGE: invalid offset'; end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 select * into sn from ins_policy_financial_snapshots where policy_id=p.id;
 shares:=sn.snapshot->'shares';
 if shares is null or shares='[]'::jsonb then shares:=jsonb_build_array(jsonb_build_object('insurer_id',p.insurer_id,'premium_amount',p.gross_premium,'commission_amount',p.commission_amount,'commission_rate_pct',p.commission_rate_pct,'share_pct',100)); end if;
 select jsonb_agg(x||jsonb_build_object('premium_amount',x->>'premium_amount','commission_amount',x->>'commission_amount','commission_rate_pct',x->>'commission_rate_pct','insurer_name',i.name)) into shares
 from jsonb_array_elements(shares) x join ins_insurers i on i.id=(x->>'insurer_id')::uuid and i.tenant_id=p.tenant_id;
 for charge in select value from jsonb_array_elements(coalesce(sn.snapshot->'charges','[]')) loop
  parts:='[]';
  if charge->>'kind'='insurer_pass_through' then
   if charge->>'recipient_mode'='one_insurer' then parts:=jsonb_build_array(jsonb_build_object('insurer_id',charge->>'recipient_insurer_id','amount',charge->>'amount'));
   else
    with bases as(select x->>'insurer_id' as insurer_id,trunc((charge->>'amount')::numeric*(x->>'share_pct')::numeric/100,2) as base,
     (charge->>'amount')::numeric*(x->>'share_pct')::numeric/100-trunc((charge->>'amount')::numeric*(x->>'share_pct')::numeric/100,2) as fraction from jsonb_array_elements(shares) x),
    ranked as(select *,row_number() over(order by fraction desc,insurer_id collate "C") as rank,round(((charge->>'amount')::numeric-sum(base) over())*100) as cents from bases)
    select jsonb_agg(jsonb_build_object('insurer_id',insurer_id,'amount',(base+case when rank<=cents then .01 else 0 end)::text)) into parts from ranked;
   end if;
   select jsonb_agg(x||jsonb_build_object('insurer_name',i.name)) into parts from jsonb_array_elements(parts) x join ins_insurers i on i.id=(x->>'insurer_id')::uuid and i.tenant_id=p.tenant_id;
  end if;
  charges:=charges||jsonb_build_array(charge||jsonb_build_object('amount',charge->>'amount','vat_amount',coalesce(charge->>'vat_amount','0'),'original_allocations',parts));
 end loop;
 select coalesce(jsonb_agg(to_jsonb(q)||jsonb_build_object(
  'insurer_adjustments',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('insurer_name',i.name,'payable_credit',a.payable_credit::text,'recovery_due',a.recovery_due::text,'retained_commission',a.retained_commission::text,'transferred_clawback_due',a.transferred_clawback_due::text)) from ins_cancellation_insurer_adjustments a join ins_insurers i on i.id=a.insurer_id where a.cancellation_id=q.id),'[]'::jsonb),
  'credits',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('credit_note_no',n.credit_note_no,'amount',l.amount::text,'journal_entry_id',n.journal_entry_id)) from ins_cancellation_credit_links l join fin_credit_notes n on n.id=l.credit_note_id where l.cancellation_id=q.id),'[]'::jsonb),
  'journals',coalesce((select jsonb_agg(to_jsonb(j)) from ins_cancellation_journals j where j.cancellation_id=q.id),'[]'::jsonb)) order by q.proposed_at desc,q.id),'[]'::jsonb) into cases
 from(select * from ins_policy_cancellations where policy_id=p.id order by proposed_at desc,id limit 20 offset p_offset) q;
 if is_finance_team_member('finance') and effective_user_id()=auth.uid() then
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'account_code',g.account_code) order by g.account_code),'[]'::jsonb) into accounts from gl_accounts g
   where g.tenant_id=p.tenant_id and g.is_active and g.account_type='asset' and not g.is_control_account
    and not exists(select 1 from gl_posting_rules r where r.tenant_id=p.tenant_id and r.gl_account_id=g.id)
    and not exists(select 1 from fin_bank_accounts b where b.tenant_id=p.tenant_id and b.gl_account_id=g.id);
 end if;
 return jsonb_build_object('policy_id',p.id,'policy_no',p.policy_no,'policy_status',p.status,'currency',p.currency,'inception_date',p.inception_date,'expiry_date',p.expiry_date,
  'actor_id',auth.uid(),'can_propose',effective_user_id()=auth.uid() and (can_manage_insurance() or is_finance_team_member('finance')),
  'can_finance',effective_user_id()=auth.uid() and is_finance_team_member('finance'),'has_live_case',exists(select 1 from ins_policy_cancellations where policy_id=p.id and status in('proposed','prepared','posted')),'has_claims',exists(select 1 from ins_claims where policy_id=p.id),
  'insurers',shares,'charges',charges,'cases',cases,'offset',p_offset,'has_more',(select count(*)>p_offset+20 from ins_policy_cancellations where policy_id=p.id),'clearing_accounts',accounts);
end $$;
revoke all on function public.ins_policy_cancellation_context(uuid,integer) from public,anon;
grant execute on function public.ins_policy_cancellation_context(uuid,integer) to authenticated;

alter function public.ins_policy_cash_position(uuid) rename to platform_ins_cash_position_before_cancellation;
revoke all on function public.platform_ins_cash_position_before_cancellation(uuid) from public,anon,authenticated;
create function public.ins_policy_cash_position(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
 v:=platform_ins_cash_position_before_cancellation(p_policy_id);
 if v->>'policy_status'='cancelled' then
  if jsonb_typeof(v->'shares')='array' then v:=jsonb_set(v,'{shares}',coalesce((select jsonb_agg(x||jsonb_build_object('maximum_remittance',0)) from jsonb_array_elements(v->'shares') x),'[]'::jsonb)); end if;
  v:=v||jsonb_build_object('can_prepare',false,'maximum_remittance',0,'cash_notice','Policy cancelled. Use the cancellation-specific recovery/refund workflow; cancellation approval did not authorize cash.'); end if;
 return v;
end $$;
revoke all on function public.ins_policy_cash_position(uuid) from public,anon;
grant execute on function public.ins_policy_cash_position(uuid) to authenticated;

-- Append negative broker-fee/VAT credit rows at the cancellation posting date.
-- Original invoice rows are retained, so period totals reconcile to accrual GL.
create or replace view public.ins_broker_fee_tax_report with(security_invoker=true) as
select c.id as charge_id,c.tenant_id,c.policy_id,p.policy_no,p.currency,p.inception_date as invoice_date,
 c.description,c.amount as fee_amount,c.vat_mode,c.vat_rate_pct,coalesce(c.vat_amount,0) as vat_amount,
 c.amount+coalesce(c.vat_amount,0) as invoice_line_total,sn.journal_entry_id
from ins_policy_charges c join ins_policies p on p.id=c.policy_id and p.tenant_id=c.tenant_id
join ins_policy_financial_snapshots sn on sn.policy_id=p.id and sn.extended where c.kind='broker_fee'
union all
select ch.id,c.tenant_id,c.policy_id,p.policy_no,p.currency,c.posting_date,
 ('Cancellation credit '||c.cancellation_no||': '||ch.description)::text,(-(x->>'refund_base')::numeric)::numeric(18,2),ch.vat_mode,ch.vat_rate_pct,
 -(x->>'refund_vat')::numeric,-((x->>'refund_base')::numeric+(x->>'refund_vat')::numeric),c.journal_entry_id
from ins_policy_cancellations c join ins_policies p on p.id=c.policy_id and p.tenant_id=c.tenant_id
cross join lateral jsonb_array_elements(c.calculation->'charges') x
join ins_policy_charges ch on ch.id=(x->>'charge_id')::uuid and ch.tenant_id=c.tenant_id
where c.status='posted' and x->>'kind'='broker_fee' and ((x->>'refund_base')::numeric>0 or (x->>'refund_vat')::numeric>0);

create or replace function public.ins_insurer_commission_statement_data(p_insurer_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare policies jsonb; ledger jsonb;
begin
 if not can_access_insurance() then raise exception 'INS_FORBIDDEN: Insurance access required' using errcode='42501'; end if;
 if not exists(select 1 from ins_insurers where id=p_insurer_id and tenant_id=get_my_tenant_id()) then raise exception 'INS_NOT_FOUND: insurer'; end if;
 select coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('gross_premium',coalesce(s.premium_amount,p.gross_premium)-coalesce(adj.return_premium,0),
  'commission_rate_pct',coalesce(s.commission_rate_pct,p.commission_rate_pct),'commission_amount',coalesce(s.commission_amount,p.commission_amount)-coalesce(adj.commission_clawback,0),
  'net_premium_to_insurer',coalesce(s.payable_amount,p.net_premium_to_insurer)-coalesce(adj.total_insurer_credit,0),'insurer_id',p_insurer_id,
  'ins_clients',jsonb_build_object('bd_clients',jsonb_build_object('name',b.name)))),'[]'::jsonb) into policies
 from ins_policies p left join ins_policy_insurer_shares s on s.policy_id=p.id and s.insurer_id=p_insurer_id
  and exists(select 1 from ins_policy_financial_snapshots sn where sn.policy_id=p.id and sn.extended)
 left join ins_cancellation_insurer_adjustments adj on adj.insurer_id=p_insurer_id and adj.cancellation_id in(select cx.id from ins_policy_cancellations cx where cx.policy_id=p.id and cx.status='posted')
 join ins_clients c on c.id=p.client_id join bd_clients b on b.id=c.client_id
 where p.tenant_id=get_my_tenant_id() and p.status<>'draft' and (s.id is not null or
  (p.insurer_id=p_insurer_id and not exists(select 1 from ins_policy_financial_snapshots sn where sn.policy_id=p.id and sn.extended)));
 select coalesce(jsonb_agg(to_jsonb(l)),'[]'::jsonb) into ledger from ins_commission_ledger l where tenant_id=get_my_tenant_id() and insurer_id=p_insurer_id;
 return jsonb_build_object('policies',policies,'ledger',ledger);
end $$;
