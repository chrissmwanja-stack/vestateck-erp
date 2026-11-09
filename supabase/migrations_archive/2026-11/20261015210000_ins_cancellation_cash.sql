-- Dedicated, independently approved cancellation cash; never an automatic
-- consequence of cancellation approval. Native Finance settlements are the cash
-- ledger. Requests and events are immutable authorization/audit evidence.
do $$ declare d text; begin
 select pg_get_constraintdef(oid) into d from pg_constraint where conrelid='journal_entries'::regclass and conname='journal_entries_source_type_check';
 alter table journal_entries drop constraint journal_entries_source_type_check;
 execute 'alter table journal_entries add constraint journal_entries_source_type_check check ('||substring(d from 8 for length(d)-8)||' or source_type=''ins_cancellation_cash'')';
end $$;
create table public.ins_cancellation_cash_requests (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references public.tenants(id),cancellation_id uuid not null,
 kind text not null check(kind in('recovery','premium_receipt','refund','remittance','commission_return','commission_withdrawal','void')),
 adjustment_id uuid,bank_account_id uuid not null,to_bank_account_id uuid,amount numeric(18,2) not null check(amount>0),
 cash_date date not null,reference text not null check(length(btrim(reference)) between 3 and 200),notes text not null check(length(btrim(notes)) between 5 and 2000),request_key uuid not null,
 status text not null default 'pending' check(status in('pending','posting','posted','rejected','cancelled','voided')),
 maker_id uuid not null,created_at timestamptz not null default now(),checker_id uuid,checked_at timestamptz,decision_reason text,
 settlement_id uuid unique,to_settlement_id uuid unique,operation_txid bigint,voids_request_id uuid,voided_by_request_id uuid,
 unique(tenant_id,id),unique(tenant_id,request_key),
 foreign key(tenant_id,cancellation_id) references public.ins_policy_cancellations(tenant_id,id),
 foreign key(tenant_id,adjustment_id) references public.ins_cancellation_insurer_adjustments(tenant_id,id),
 foreign key(tenant_id,bank_account_id) references public.fin_bank_accounts(tenant_id,id),
 foreign key(tenant_id,to_bank_account_id) references public.fin_bank_accounts(tenant_id,id),
 foreign key(tenant_id,settlement_id) references public.fin_settlements(tenant_id,id) deferrable initially deferred,
 foreign key(tenant_id,to_settlement_id) references public.fin_settlements(tenant_id,id) deferrable initially deferred,
 foreign key(tenant_id,voids_request_id) references public.ins_cancellation_cash_requests(tenant_id,id),
 foreign key(tenant_id,voided_by_request_id) references public.ins_cancellation_cash_requests(tenant_id,id),
 check(checker_id is null or checker_id<>maker_id),check((status='posting')=(operation_txid is not null)),
 check(status not in('posting','posted','voided') or(checker_id is not null and checked_at is not null)),
 check(status not in('posted','voided') or kind='void' or settlement_id is not null),
 check((kind='void')=(voids_request_id is not null)),
 check((status='voided')=(voided_by_request_id is not null)),
 check(to_bank_account_id is null or to_bank_account_id<>bank_account_id)
);
create index ins_cancellation_cash_case_idx on public.ins_cancellation_cash_requests(tenant_id,cancellation_id,created_at);
create index ins_cancellation_cash_adjustment_idx on public.ins_cancellation_cash_requests(adjustment_id);
create index ins_cancellation_cash_bank_idx on public.ins_cancellation_cash_requests(bank_account_id);
create index ins_cancellation_cash_to_bank_idx on public.ins_cancellation_cash_requests(to_bank_account_id);
create index ins_cancellation_cash_voided_idx on public.ins_cancellation_cash_requests(voided_by_request_id);
create unique index ins_cancellation_cash_one_void on public.ins_cancellation_cash_requests(voids_request_id) where status in('pending','posting','posted');
create table public.ins_cancellation_cash_journals (
 tenant_id uuid not null references public.tenants(id),request_id uuid not null,journal_entry_id uuid primary key references public.journal_entries(id),purpose text not null,
 foreign key(tenant_id,request_id) references public.ins_cancellation_cash_requests(tenant_id,id)
);
create index ins_cancellation_cash_journals_request_idx on public.ins_cancellation_cash_journals(tenant_id,request_id);
create table public.ins_cancellation_cash_events (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references public.tenants(id),request_id uuid not null,
 event text not null,actor_id uuid not null,occurred_at timestamptz not null default now(),detail jsonb not null default '{}',
 foreign key(tenant_id,request_id) references public.ins_cancellation_cash_requests(tenant_id,id)
);
create index ins_cancellation_cash_events_request_idx on public.ins_cancellation_cash_events(tenant_id,request_id,occurred_at);
create table public.ins_cancellation_commission_events (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references public.tenants(id),request_id uuid not null,adjustment_id uuid not null,
 amount numeric(18,2) not null check(amount<>0),journal_entry_id uuid not null references public.journal_entries(id),
 unique(request_id,adjustment_id),
 foreign key(tenant_id,request_id) references public.ins_cancellation_cash_requests(tenant_id,id),
 foreign key(tenant_id,adjustment_id) references public.ins_cancellation_insurer_adjustments(tenant_id,id)
);
create index ins_cancellation_commission_events_adjust_idx on public.ins_cancellation_commission_events(adjustment_id);
create index ins_cancellation_commission_events_journal_idx on public.ins_cancellation_commission_events(journal_entry_id);
do $$ declare t text; begin
 foreach t in array array['ins_cancellation_cash_requests','ins_cancellation_cash_journals','ins_cancellation_cash_events','ins_cancellation_commission_events'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('create policy %I on public.%I for select to authenticated using(tenant_id=get_my_tenant_id() and(can_access_insurance() or is_finance_team_member(''finance'')))',t||'_select',t);
 end loop;
end $$;

-- Both exact-zero bank evidence and posted book cash are needed. Neither AR,
-- income reversals, a pending receipt nor an unmatched transfer is funding.
create function public.platform_ins_cancellation_cash_proven(p_settlement_id uuid) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from fin_settlements s join bank_reconciliations r on r.settlement_id=s.id
 join bank_statement_lines l on l.id=r.bank_statement_line_id and l.tenant_id=s.tenant_id
 join fin_bank_accounts b on b.id=s.bank_account_id
 where s.id=p_settlement_id and s.status='posted' and r.variance=0 and r.matched_by is not null
 and l.bank_account=b.name and l.currency=s.currency and l.amount=case s.direction when 'in' then s.amount else -s.amount end)
$$;
create function public.platform_ins_cancellation_cash_movements(p_case uuid)
returns table(bank_id uuid,amount numeric,proven_amount numeric) language sql stable security definer set search_path=public,pg_temp as $$
 with c as(select * from ins_policy_cancellations where id=p_case),
 original as(select s.bank_account_id as bank_id,case s.direction when 'in' then a.amount else -a.amount end as amount,
 case when s.direction='out' or platform_ins_cancellation_cash_proven(s.id) then case s.direction when 'in' then a.amount else -a.amount end else 0 end as proven_amount
 from c join ins_policy_cash_items k on k.source_id=c.policy_id join fin_allocations a on a.open_item_id=k.id join fin_settlements s on s.id=a.settlement_id and s.status='posted'
 where not exists(select 1 from ins_cancellation_cash_requests q where s.id in(q.settlement_id,q.to_settlement_id))),
 withdrawn as(select t.from_bank_account_id as bank_id,-e.amount as amount,-e.amount as proven_amount
 from c join ins_commission_entries e on e.policy_id=c.policy_id and e.status='transferred' join ins_commission_transfers t on t.id=e.transfer_id and t.status='posted'),
 new_cash as(select s.bank_account_id as bank_id,case s.direction when 'in' then s.amount else -s.amount end as amount,
 case when s.direction='out' or(platform_ins_cancellation_cash_proven(s.id) and(q.kind<>'commission_return' or platform_ins_cancellation_cash_proven(q.settlement_id))) then case s.direction when 'in' then s.amount else -s.amount end else 0 end as proven_amount
 from ins_cancellation_cash_requests q join fin_settlements s on s.id in(q.settlement_id,q.to_settlement_id) and s.status='posted'
 join fin_bank_accounts b on b.id=s.bank_account_id and b.kind='client_money'
 where q.cancellation_id=p_case and q.kind<>'void' and q.status in('posted','posting'))
 select * from original union all select * from withdrawn union all select * from new_cash
$$;
-- Fail closed on an unattributed bank shortfall: a manual bank reduction
-- must not make one policy consume another policy's or a claim's native cash.
create function public.platform_ins_cancellation_cash_banks_sound(p_case uuid) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
 select not exists(select 1 from fin_bank_accounts b
 where b.kind='client_money' and b.id in(select bank_id from platform_ins_cancellation_cash_movements(p_case))
 and (select coalesce(sum(l.debit-l.credit),0) from journal_entry_lines l join journal_entries j on j.id=l.journal_entry_id and j.status='posted' where l.gl_account_id=b.gl_account_id and j.tenant_id=b.tenant_id)
 < greatest((select coalesce(sum(case f.direction when 'in' then f.amount else -f.amount end),0) from fin_settlements f where f.bank_account_id=b.id and f.tenant_id=b.tenant_id and f.status='posted')+
 (select coalesce(sum(case when t.to_bank_account_id=b.id then t.amount else -t.amount end),0) from ins_commission_transfers t where b.id in(t.from_bank_account_id,t.to_bank_account_id) and t.status='posted'),0))
$$;

create function public.platform_ins_cancellation_cash_position(p_case uuid,p_bank uuid default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; a ins_cancellation_insurer_adjustments%rowtype; b fin_bank_accounts%rowtype; sn ins_policy_financial_snapshots%rowtype;
 original_gross numeric; retained_total numeric; collected numeric; ratio numeric; refund_due numeric; fees numeric; reserve_comm numeric:=0; earned_hold numeric:=0;
 cash numeric; bank_cash numeric; raw_bank_cash numeric; book numeric; due numeric; recovered numeric; returned numeric; withdrawn numeric; spent numeric; funded numeric; hold numeric; paid numeric;
 parts jsonb:='[]'; part jsonb; original_premium numeric; original_pass numeric; original_commission numeric; sound boolean;
begin
 select * into c from ins_policy_cancellations where id=p_case;
 if not found or c.status<>'posted' then raise exception 'INS_CXL_CASH_STATE: posted cancellation required'; end if;
 select * into sn from ins_policy_financial_snapshots where policy_id=c.policy_id;
 select coalesce(sn.invoice_total,p.gross_premium),p.gross_premium into original_gross,original_premium from ins_policies p where p.id=c.policy_id;
 retained_total:=original_gross-(c.calculation->>'invoice_credit')::numeric;
 select coalesce(sum(al.amount),0) into collected from ins_policy_cash_items k join fin_allocations al on al.open_item_id=k.id
 join fin_settlements s on s.id=al.settlement_id and s.status='posted' and s.direction='in'
 where k.source_id=c.policy_id and k.source_type='ins_policy_premium' and platform_ins_cancellation_cash_proven(s.id);
 ratio:=case when retained_total=0 then 0 else least(greatest(collected-(c.calculation->>'client_refund_due')::numeric,0)/retained_total,1) end;
 select coalesce(outstanding_amount,0) into refund_due from fin_open_item_balances where id=c.refund_item_id;
 refund_due:=coalesce(refund_due,0);
 fees:=coalesce(sn.broker_fee_total,0)+coalesce(sn.vat_total,0)-coalesce((select sum((x->>'refund_base')::numeric+(x->>'refund_vat')::numeric) from jsonb_array_elements(c.calculation->'charges') x where x->>'kind'='broker_fee'),0);
 select coalesce(sum(proven_amount),0),coalesce(sum(proven_amount) filter(where bank_id=p_bank),0),coalesce(sum(amount) filter(where bank_id=p_bank),0)
 into cash,bank_cash,raw_bank_cash from platform_ins_cancellation_cash_movements(c.id);
 select * into b from fin_bank_accounts where id=p_bank and tenant_id=c.tenant_id;
 select coalesce(sum(l.debit-l.credit),0) into book from journal_entry_lines l join journal_entries j on j.id=l.journal_entry_id and j.status='posted'
 where j.tenant_id=c.tenant_id and l.gl_account_id=b.gl_account_id;
 sound:=platform_ins_cancellation_cash_banks_sound(c.id);
 for a in select * from ins_cancellation_insurer_adjustments where cancellation_id=c.id order by insurer_id loop
  select coalesce(outstanding_amount,0) into due from fin_open_item_balances where id=a.original_item_id;
  select coalesce(sum(s.amount),0) into recovered from ins_cancellation_cash_requests q join fin_settlements s on s.id=q.settlement_id and s.status='posted'
   where q.adjustment_id=a.id and q.kind='recovery' and platform_ins_cancellation_cash_proven(s.id);
  select coalesce(sum(q.amount),0) into returned from ins_cancellation_cash_requests q where q.adjustment_id=a.id and q.kind='commission_return' and q.status='posted'
   and platform_ins_cancellation_cash_proven(q.settlement_id) and platform_ins_cancellation_cash_proven(q.to_settlement_id);
  select coalesce(sum(q.amount),0) into withdrawn from ins_cancellation_cash_requests q where q.adjustment_id=a.id and q.kind='commission_withdrawal' and q.status='posted';
  select coalesce(sum(al.amount),0) into paid from fin_allocations al join fin_settlements s on s.id=al.settlement_id and s.status='posted' where al.open_item_id=a.original_item_id;
  select coalesce(s.premium_amount,p.gross_premium),coalesce(s.pass_through_amount,0),coalesce(s.commission_amount,p.commission_amount)
    into original_premium,original_pass,original_commission from ins_policies p left join ins_policy_insurer_shares s on s.id=a.insurer_share_id where p.id=c.policy_id;
  funded:=trunc((original_premium+original_pass-a.return_premium-a.pass_through_refund)*ratio,2);
  spent:=paid-recovered+case when a.retained_commission_status='transferred' then original_commission else 0 end-returned+withdrawn;
  hold:=greatest(a.retained_commission-case when a.retained_commission_status='transferred' then a.retained_commission else withdrawn end,0);
  reserve_comm:=reserve_comm+hold;
  if due=0 then earned_hold:=earned_hold+hold; end if;
  parts:=parts||jsonb_build_array(jsonb_build_object('adjustment_id',a.id,'insurer_id',a.insurer_id,'insurer_name',(select name from ins_insurers where id=a.insurer_id),
   'outstanding',due::text,'recovery_due',coalesce((select outstanding_amount from fin_open_item_balances where id=a.recovery_item_id),0)::text,
   'commission_return_due',(a.transferred_clawback_due-coalesce((select sum(amount) from ins_cancellation_cash_requests where adjustment_id=a.id and kind='commission_return' and status='posted'),0))::text,
   'retained_commission',a.retained_commission::text,'commission_withdrawal_due',case when due=0 then hold::text else '0.00' end,
   'funded_gross',funded::text,'spent',spent::text,'funding_cap',greatest(funded-spent,0)::text,'commission_status',case when a.retained_commission_status='transferred' or(withdrawn>=a.retained_commission and a.retained_commission>0) then 'transferred' when due=0 then 'earned' else 'deferred' end));
 end loop;
 return jsonb_build_object('cancellation_id',c.id,'policy_id',c.policy_id,'currency',(select currency from ins_policies where id=c.policy_id),
  'retained_invoice',retained_total::text,'proven_client_collections',collected::text,'funding_ratio',ratio::text,'proven_cash',cash::text,
  'bank_proven_cash',bank_cash::text,'bank_raw_cash',raw_bank_cash::text,'bank_book_cash',book::text,'client_refund_outstanding',refund_due::text,
  'retained_fee_vat_reserve',fees::text,'commission_reserve',reserve_comm::text,'earned_commission_reserve',earned_hold::text,
  'insurer_payable_reserve',coalesce((select sum((x->>'outstanding')::numeric) from jsonb_array_elements(parts) x),0)::text,
  'bank_funding_sound',sound,
 'maximum_refund',case when sound then greatest(least(refund_due,cash-coalesce((select sum((x->>'outstanding')::numeric) from jsonb_array_elements(parts) x),0)-reserve_comm-fees,bank_cash,book),0)::text else '0.00' end,
  'client_premium_outstanding',coalesce((select outstanding_amount from fin_open_item_balances where source_type='ins_policy_premium' and source_id=c.policy_id),0)::text,'insurers',(select jsonb_agg(x||jsonb_build_object(
 'maximum_remittance',case when sound then greatest(least((x->>'outstanding')::numeric,(x->>'funding_cap')::numeric,cash-refund_due-trunc(fees*ratio,2)-earned_hold,bank_cash,book),0)::text else '0.00' end,
 'maximum_commission_withdrawal',case when sound then greatest(least((x->>'commission_withdrawal_due')::numeric,(x->>'funding_cap')::numeric,cash-refund_due-coalesce((select sum((y->>'outstanding')::numeric) from jsonb_array_elements(parts) y),0)-fees-(reserve_comm-(x->>'commission_withdrawal_due')::numeric),bank_cash,book),0)::text else '0.00' end,
 'maximum_commission_return',greatest(least((x->>'commission_return_due')::numeric,book),0)::text)) from jsonb_array_elements(parts) x));
end $$;

create function public.platform_ins_cancellation_cash_bank(p_id uuid,p_tenant uuid,p_kind text) returns public.fin_bank_accounts
language plpgsql security definer set search_path=public,pg_temp as $$
declare b fin_bank_accounts%rowtype;
begin
 select * into b from fin_bank_accounts where id=p_id and tenant_id=p_tenant;
 if not found or not b.is_active or b.kind<>p_kind or b.currency<>fin_ledger_currency(p_tenant)
 or not exists(select 1 from gl_accounts g where g.id=b.gl_account_id and g.tenant_id=b.tenant_id and g.is_active and g.account_type='asset')
 or exists(select 1 from fin_bank_accounts other where other.id<>b.id and other.gl_account_id=b.gl_account_id)
 or exists(select 1 from gl_posting_rules r where r.tenant_id=b.tenant_id and r.gl_account_id=b.gl_account_id and
  ((p_kind='client_money' and r.account_role in('bank','cash')) or(p_kind='operating' and r.account_role='client_money_bank'))) then
 raise exception 'INS_CXL_CASH_BANK: active ledger-currency % bank with a unique, segregated asset GL required',p_kind; end if;
 return b;
end $$;
create function public.platform_ins_cancellation_cash_validate(p_case uuid,p_kind text,p_adjustment uuid,p_bank uuid,p_to_bank uuid,p_amount numeric,p_date date) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; a ins_cancellation_insurer_adjustments%rowtype; v jsonb; sh jsonb; b fin_bank_accounts%rowtype; dest fin_bank_accounts%rowtype;
 cap numeric:=0; item uuid; original_transfer ins_commission_transfers%rowtype;
begin
 perform ins_policy_cash_require_finance();
 select * into c from ins_policy_cancellations where id=p_case and tenant_id=get_my_tenant_id();
 if not found or c.status<>'posted' or not exists(select 1 from ins_policies where id=c.policy_id and status='cancelled') then raise exception 'INS_CXL_CASH_STATE: posted cancellation and cancelled policy required'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>9999999999999999.99 or p_date is distinct from current_date then raise exception 'INS_CXL_CASH_INPUT: positive exact-cent amount and current accounting date required'; end if;
 if p_kind is null or p_kind not in('recovery','premium_receipt','refund','remittance','commission_return','commission_withdrawal') then raise exception 'INS_CXL_CASH_INPUT: unsupported cash kind'; end if;
 if exists(select 1 from accounting_periods where tenant_id=c.tenant_id and status='closed' and current_date between period_start and period_end) then raise exception 'INS_CXL_CASH_PERIOD: current period closed'; end if;
 if p_kind in('recovery','remittance','commission_return','commission_withdrawal') then
 select * into a from ins_cancellation_insurer_adjustments where id=p_adjustment and cancellation_id=c.id;
 if not found then raise exception 'INS_CXL_CASH_INSURER: select an adjustment from this cancellation'; end if;
 elsif p_adjustment is not null then raise exception 'INS_CXL_CASH_INPUT: this action has no insurer adjustment'; end if;
 b:=platform_ins_cancellation_cash_bank(p_bank,c.tenant_id,case when p_kind='commission_return' then 'operating' else 'client_money' end);
 if p_kind in('commission_return','commission_withdrawal') then
 dest:=platform_ins_cancellation_cash_bank(p_to_bank,c.tenant_id,case p_kind when 'commission_return' then 'client_money' else 'operating' end);
 if b.id=dest.id or b.gl_account_id=c.clearing_gl_account_id or dest.gl_account_id=c.clearing_gl_account_id then raise exception 'INS_CXL_CASH_BANK: distinct banks and clearing GL required'; end if;
 elsif p_to_bank is not null then raise exception 'INS_CXL_CASH_INPUT: no destination bank for an external settlement'; end if;
 v:=platform_ins_cancellation_cash_position(c.id,b.id);
 if a.id is not null then select x into sh from jsonb_array_elements(v->'insurers') x where x->>'adjustment_id'=a.id::text; end if;
 case p_kind
 when 'recovery' then item:=a.recovery_item_id; cap:=(sh->>'recovery_due')::numeric;
 when 'premium_receipt' then select id into item from fin_open_items where source_type='ins_policy_premium' and source_id=c.policy_id; cap:=(v->>'client_premium_outstanding')::numeric;
 when 'refund' then
 item:=c.refund_item_id;
 cap:=least((v->>'client_refund_outstanding')::numeric,greatest((v->>'proven_cash')::numeric-(v->>'insurer_payable_reserve')::numeric-(v->>'commission_reserve')::numeric-(v->>'retained_fee_vat_reserve')::numeric,0));
 when 'remittance' then
 item:=a.original_item_id;
 cap:=least((sh->>'outstanding')::numeric,(sh->>'funding_cap')::numeric,greatest((v->>'proven_cash')::numeric-(v->>'client_refund_outstanding')::numeric-trunc((v->>'retained_fee_vat_reserve')::numeric*(v->>'funding_ratio')::numeric,2)-(v->>'earned_commission_reserve')::numeric,0));
 when 'commission_return' then
 select * into original_transfer from ins_commission_transfers where id=(a.original_commission_state->>'transfer_id')::uuid and status='posted';
 if original_transfer.id is null or original_transfer.to_bank_account_id<>b.id then raise exception 'INS_CXL_CASH_BANK: return commission from its original operating bank'; end if;
 cap:=least((sh->>'commission_return_due')::numeric,greatest((v->>'bank_book_cash')::numeric,0));
 when 'commission_withdrawal' then
 cap:=least((sh->>'commission_withdrawal_due')::numeric,(sh->>'funding_cap')::numeric,
 greatest((v->>'proven_cash')::numeric-(v->>'client_refund_outstanding')::numeric-(v->>'insurer_payable_reserve')::numeric-(v->>'retained_fee_vat_reserve')::numeric-((v->>'commission_reserve')::numeric-(sh->>'commission_withdrawal_due')::numeric),0));
 end case;
 if p_kind in('refund','remittance','commission_withdrawal') then
 if not(v->>'bank_funding_sound')::boolean then raise exception 'INS_CXL_CASH_FUNDS: unattributed client-bank shortfall; protect other policies and claims, Finance review required'; end if;
 cap:=least(cap,greatest((v->>'bank_proven_cash')::numeric,0),greatest((v->>'bank_book_cash')::numeric,0)); end if;
 if cap is null or p_amount>cap then raise exception 'INS_CXL_CASH_FUNDS: maximum % is %, requested %; refresh balances and reconcile actual funds first',p_kind,coalesce(cap,0),p_amount; end if;
 if item is not null then
  perform id from fin_open_items where id=item for update;
  if get_posting_account(c.tenant_id,(select control_role from fin_open_items where id=item)) is distinct from
   (c.accounting_mappings->>case p_kind when 'refund' then 'refund_payable' when 'remittance' then 'payable' else 'ar' end)::uuid then raise exception 'INS_CXL_CASH_MAPPING: original control mapping changed'; end if;
 end if;
 return item;
end $$;

create function public.platform_ins_cancellation_cash_authorized(p_item uuid,p_settlement uuid,p_amount numeric) returns boolean
language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; target uuid;
begin
 select * into q from ins_cancellation_cash_requests where settlement_id=p_settlement and status='posting' and operation_txid=txid_current() and checker_id=auth.uid() and maker_id<>auth.uid() and tenant_id=get_my_tenant_id();
 if not found then return false; end if;
 perform ins_policy_cash_require_finance();
 select * into c from ins_policy_cancellations where id=q.cancellation_id and status='posted';
 target:=case q.kind when 'refund' then c.refund_item_id when 'premium_receipt' then(select id from fin_open_items where source_type='ins_policy_premium' and source_id=c.policy_id)
 when 'recovery' then(select recovery_item_id from ins_cancellation_insurer_adjustments where id=q.adjustment_id and cancellation_id=c.id)
 when 'remittance' then(select original_item_id from ins_cancellation_insurer_adjustments where id=q.adjustment_id and cancellation_id=c.id) end;
 return c.id is not null and target=p_item and q.amount=p_amount and exists(select 1 from fin_settlements s join fin_open_items i on i.id=p_item where s.id=p_settlement and s.amount=q.amount and s.bank_account_id=q.bank_account_id and s.settlement_date=q.cash_date and s.party_account_id=i.party_account_id and s.direction=case q.kind when 'refund' then 'out' when 'remittance' then 'out' else 'in' end) and not exists(select 1 from fin_allocations where settlement_id=p_settlement);
end $$;
create function public.platform_ins_cancellation_cash_void_authorized(p_settlement uuid) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from ins_cancellation_cash_requests target join ins_cancellation_cash_requests v on v.voids_request_id=target.id and v.cancellation_id=target.cancellation_id
 where p_settlement in(target.settlement_id,target.to_settlement_id) and target.status='posted' and v.status='posting' and v.operation_txid=txid_current() and v.checker_id=auth.uid() and v.maker_id<>auth.uid() and v.tenant_id=get_my_tenant_id())
$$;

create function public.ins_submit_cancellation_cash(p_cancellation_id uuid,p_kind text,p_adjustment_id uuid,p_bank_account_id uuid,p_to_bank_account_id uuid,p_amount numeric,p_cash_date date,p_reference text,p_notes text,p_request_key uuid)
returns public.ins_cancellation_cash_requests language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype;
begin
 perform ins_policy_cash_require_finance();
 select * into c from ins_policy_cancellations where id=p_cancellation_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cancellation'; end if;
 perform id from ins_policies where id=c.policy_id for update;
 select * into q from ins_cancellation_cash_requests where tenant_id=c.tenant_id and request_key=p_request_key;
 if found then
 if q.maker_id<>auth.uid() or (q.cancellation_id,q.kind,q.adjustment_id,q.bank_account_id,q.to_bank_account_id,q.amount,q.cash_date,q.reference,q.notes) is distinct from
 (p_cancellation_id,p_kind,p_adjustment_id,p_bank_account_id,p_to_bank_account_id,p_amount,p_cash_date,btrim(p_reference),btrim(p_notes)) then raise exception 'INS_CXL_CASH_RETRY: request key belongs to different inputs'; end if;
 return q; end if;
 if p_request_key is null or p_reference is null or length(btrim(p_reference)) not between 3 and 200 or p_notes is null or length(btrim(p_notes)) not between 5 and 2000 then raise exception 'INS_CXL_CASH_INPUT: request key, reference and detailed purpose required'; end if;
 perform platform_ins_cancellation_cash_validate(c.id,p_kind,p_adjustment_id,p_bank_account_id,p_to_bank_account_id,p_amount,p_cash_date);
 insert into ins_cancellation_cash_requests(tenant_id,cancellation_id,kind,adjustment_id,bank_account_id,to_bank_account_id,amount,cash_date,reference,notes,request_key,maker_id)
 values(c.tenant_id,c.id,p_kind,p_adjustment_id,p_bank_account_id,p_to_bank_account_id,p_amount,p_cash_date,btrim(p_reference),btrim(p_notes),p_request_key,auth.uid()) returning * into q;
 insert into ins_cancellation_cash_events(tenant_id,request_id,event,actor_id) values(c.tenant_id,q.id,'submitted',auth.uid());
 return q;
end $$;
create function public.ins_submit_cancellation_cash_void(p_request_id uuid,p_reason text,p_request_key uuid) returns public.ins_cancellation_cash_requests
language plpgsql security definer set search_path=public,pg_temp as $$
declare target ins_cancellation_cash_requests%rowtype; q ins_cancellation_cash_requests%rowtype;
begin
 perform ins_policy_cash_require_finance();
 select * into target from ins_cancellation_cash_requests where id=p_request_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cash request'; end if;
 perform p.id from ins_policies p join ins_policy_cancellations c on c.policy_id=p.id where c.id=target.cancellation_id for update of p;
 select * into q from ins_cancellation_cash_requests where tenant_id=target.tenant_id and request_key=p_request_key;
 if found then if q.maker_id<>auth.uid() or q.voids_request_id is distinct from target.id or q.notes is distinct from btrim(p_reason) then raise exception 'INS_CXL_CASH_RETRY: different void inputs'; end if; return q; end if;
 if target.kind='void' or target.status<>'posted' or p_request_key is null or p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then raise exception 'INS_CXL_CASH_VOID: posted cash and detailed reason required'; end if;
 insert into ins_cancellation_cash_requests(tenant_id,cancellation_id,kind,adjustment_id,bank_account_id,to_bank_account_id,amount,cash_date,reference,notes,request_key,maker_id,voids_request_id)
 values(target.tenant_id,target.cancellation_id,'void',target.adjustment_id,target.bank_account_id,target.to_bank_account_id,target.amount,current_date,'Void '||target.id,btrim(p_reason),p_request_key,auth.uid(),target.id) returning * into q;
 insert into ins_cancellation_cash_events(tenant_id,request_id,event,actor_id) values(q.tenant_id,q.id,'void_requested',auth.uid()); return q;
end $$;

create function public.platform_ins_cancellation_cash_emit(p_request uuid,p_item uuid,p_second boolean default false) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; i fin_open_items%rowtype; s fin_settlements%rowtype; b fin_bank_accounts%rowtype;
 sid uuid:=gen_random_uuid(); party uuid; direction text; control uuid; je journal_entries%rowtype; lines jsonb;
begin
 select * into q from ins_cancellation_cash_requests where id=p_request and tenant_id=get_my_tenant_id() and status='posting' and operation_txid=txid_current() and checker_id=auth.uid() and maker_id<>auth.uid();
 if not found then raise exception 'INS_CXL_CASH_CONTEXT: exact checker transaction required'; end if;
 perform ins_policy_cash_require_finance(); select * into c from ins_policy_cancellations where id=q.cancellation_id;
 select * into b from fin_bank_accounts where id=case when p_second then q.to_bank_account_id else q.bank_account_id end;
 direction:=case when p_second then 'in' when q.kind in('refund','remittance','commission_return','commission_withdrawal') then 'out' else 'in' end;
 if p_item is not null then select * into i from fin_open_items where id=p_item; party:=i.party_account_id;
 control:=(c.accounting_mappings->>case q.kind when 'refund' then 'refund_payable' when 'remittance' then 'payable' else 'ar' end)::uuid;
 else select party_account_id into party from fin_open_items where source_type='ins_policy_premium' and source_id=c.policy_id; control:=c.clearing_gl_account_id; end if;
 if p_second then update ins_cancellation_cash_requests set to_settlement_id=sid where id=q.id; else update ins_cancellation_cash_requests set settlement_id=sid where id=q.id; end if;
 insert into fin_settlements(id,tenant_id,settlement_no,direction,bank_account_id,party_account_id,amount,currency,settlement_date,reference,notes)
 values(sid,q.tenant_id,next_doc_number(q.tenant_id,'fin_settlement','STL'),direction,b.id,party,q.amount,b.currency,q.cash_date,q.reference,q.notes);
 if p_item is not null then insert into fin_allocations(tenant_id,settlement_id,open_item_id,amount) values(q.tenant_id,sid,p_item,q.amount); end if;
 lines:=jsonb_build_array(jsonb_build_object('gl_account_id',b.gl_account_id,case direction when 'in' then 'debit' else 'credit' end,q.amount),jsonb_build_object('gl_account_id',control,case direction when 'in' then 'credit' else 'debit' end,q.amount));
 je:=post_journal_entry(q.tenant_id,'ins_cancellation_cash',sid,q.cash_date,'Cancellation cash '||q.kind||': '||q.reference,lines);
 insert into ins_cancellation_cash_journals values(q.tenant_id,q.id,je.id,case when p_second then 'destination_cash' else 'cash' end);
 update fin_settlements set journal_entry_id=je.id where id=sid;
 return sid;
end $$;
create function public.platform_ins_cancellation_cash_recognize(p_request uuid,p_adjustment uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; a ins_cancellation_insurer_adjustments%rowtype; outstanding numeric; recognized numeric; delta numeric; je journal_entries%rowtype;
begin
 select * into q from ins_cancellation_cash_requests where id=p_request and status='posting' and operation_txid=txid_current() and checker_id=auth.uid() and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_CXL_CASH_CONTEXT: recognition requires current checker'; end if;
 select * into a from ins_cancellation_insurer_adjustments where id=p_adjustment and cancellation_id=q.cancellation_id;
 if not found or a.retained_commission_status<>'deferred' or a.retained_commission=0 then return; end if;
 select * into c from ins_policy_cancellations where id=q.cancellation_id;
 select outstanding_amount into outstanding from fin_open_item_balances where id=a.original_item_id;
 select coalesce(sum(amount),0) into recognized from ins_cancellation_commission_events where adjustment_id=a.id;
 delta:=case when outstanding=0 then a.retained_commission else 0 end-recognized;
 if delta=0 then return; end if;
 je:=post_journal_entry(q.tenant_id,'ins_cancellation_cash',q.id,current_date,'Retained commission recognition: '||q.reference,
 jsonb_build_array(jsonb_build_object('gl_account_id',(c.accounting_mappings->>'unearned')::uuid,'debit',greatest(delta,0),'credit',greatest(-delta,0)),jsonb_build_object('gl_account_id',(c.accounting_mappings->>'income')::uuid,'credit',greatest(delta,0),'debit',greatest(-delta,0))));
 insert into ins_cancellation_cash_journals values(q.tenant_id,q.id,je.id,'retained_commission_recognition');
 insert into ins_cancellation_commission_events(tenant_id,request_id,adjustment_id,amount,journal_entry_id) values(q.tenant_id,q.id,a.id,delta,je.id);
end $$;

create function public.ins_decide_cancellation_cash(p_request_id uuid,p_decision text,p_reason text) returns public.ins_cancellation_cash_requests
language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_cancellation_cash_requests%rowtype; target ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; s fin_settlements%rowtype; item uuid; v jsonb;
begin
 perform ins_policy_cash_require_finance();
 if p_decision is null or p_decision not in('approve','reject','cancel') or p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then raise exception 'INS_CXL_CASH_INPUT: decision and detailed review note required'; end if;
 select cx.* into c from ins_policy_cancellations cx join ins_cancellation_cash_requests r on r.cancellation_id=cx.id where r.id=p_request_id and r.tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cash request'; end if;
 -- All actors lock policy, banks in UUID order, request, then items/settlements.
 perform id from ins_policies where id=c.policy_id for update;
 perform id from fin_bank_accounts where tenant_id=c.tenant_id order by id for update;
 perform pg_advisory_xact_lock(hashtextextended('ins-cxl-cash-book:'||c.tenant_id::text,0));
 select * into q from ins_cancellation_cash_requests where id=p_request_id for update;
 if(p_decision='cancel' and q.maker_id<>auth.uid()) or(p_decision<>'cancel' and q.maker_id=auth.uid()) then raise exception 'INS_CXL_CASH_SELF_APPROVAL: maker cannot act as checker'; end if;
 if p_decision='approve' and q.status in('posted','voided') and q.checker_id=auth.uid() then return q; end if;
 if q.status<>'pending' then raise exception 'INS_CXL_CASH_STATE: pending request required'; end if;
 if p_decision in('reject','cancel') then
 update ins_cancellation_cash_requests set status=case p_decision when 'reject' then 'rejected' else 'cancelled' end,checker_id=case p_decision when 'reject' then auth.uid() end,checked_at=now(),decision_reason=btrim(p_reason) where id=q.id returning * into q;
 else
 if q.cash_date<>current_date or exists(select 1 from accounting_periods where tenant_id=c.tenant_id and status='closed' and current_date between period_start and period_end) then raise exception 'INS_CXL_CASH_PERIOD: current open posting date required; cancel and recreate stale-date requests'; end if;
 if q.kind<>'void' then item:=platform_ins_cancellation_cash_validate(c.id,q.kind,q.adjustment_id,q.bank_account_id,q.to_bank_account_id,q.amount,q.cash_date); end if;
 update ins_cancellation_cash_requests set status='posting',checker_id=auth.uid(),checked_at=now(),decision_reason=btrim(p_reason),operation_txid=txid_current() where id=q.id returning * into q;
 if q.kind='void' then
 select * into target from ins_cancellation_cash_requests where id=q.voids_request_id and cancellation_id=c.id and status='posted' for update;
 if not found then raise exception 'INS_CXL_CASH_VOID: target is not posted'; end if;
 if exists(select 1 from bank_reconciliations where settlement_id in(target.settlement_id,target.to_settlement_id)) then raise exception 'INS_CXL_CASH_MATCHED: unmatch both legs before requesting a void'; end if;
 if target.kind in('recovery','premium_receipt','commission_return') and exists(select 1 from ins_cancellation_cash_requests where cancellation_id=c.id and status='posted' and kind in('refund','remittance','commission_withdrawal')) then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: reverse downstream cancellation payments first'; end if;
 if target.kind='remittance' and exists(select 1 from ins_cancellation_cash_requests where adjustment_id=target.adjustment_id and kind='commission_withdrawal' and status='posted') then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: return the retained commission withdrawal first'; end if;
 if target.kind in('recovery','premium_receipt','commission_return') then
 v:=platform_ins_cancellation_cash_position(c.id,case target.kind when 'commission_return' then target.to_bank_account_id else target.bank_account_id end);
 if least((v->>'bank_raw_cash')::numeric,(v->>'bank_book_cash')::numeric)<target.amount then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: receipt cash is no longer available at its bank'; end if;
 elsif target.kind='commission_withdrawal' then
 v:=platform_ins_cancellation_cash_position(c.id,target.to_bank_account_id);
 if(v->>'bank_book_cash')::numeric<target.amount then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: operating cash is no longer available'; end if;
 end if;
 s:=platform_fin_void_settlement_impl(c.tenant_id,target.settlement_id,q.notes,current_date);
 insert into ins_cancellation_cash_journals values(c.tenant_id,q.id,s.void_journal_entry_id,'cash_void');
 if target.to_settlement_id is not null then
 s:=platform_fin_void_settlement_impl(c.tenant_id,target.to_settlement_id,q.notes,current_date);
 insert into ins_cancellation_cash_journals values(c.tenant_id,q.id,s.void_journal_entry_id,'destination_void'); end if;
 update ins_cancellation_cash_requests set status='voided',voided_by_request_id=q.id where id=target.id;
 if target.kind='remittance' then perform platform_ins_cancellation_cash_recognize(q.id,target.adjustment_id); end if;
 else
 perform platform_ins_cancellation_cash_emit(q.id,item);
 if q.kind in('commission_return','commission_withdrawal') then perform platform_ins_cancellation_cash_emit(q.id,null,true); end if;
 if q.kind='remittance' then perform platform_ins_cancellation_cash_recognize(q.id,q.adjustment_id); end if;
 end if;
 update ins_cancellation_cash_requests set status='posted',operation_txid=null where id=q.id returning * into q;
 end if;
 insert into ins_cancellation_cash_events(tenant_id,request_id,event,actor_id,detail) values(c.tenant_id,q.id,q.status,auth.uid(),jsonb_build_object('reason',p_reason));
 return q;
end $$;

-- Reconciliation runs in the existing Finance bank workbench. Both internal
-- transfer legs require an independent, exact match before return cash is usable.
create function public.ins_cancellation_cash_reconciliation_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare sid uuid; q ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; s fin_settlements%rowtype; row_json jsonb; b fin_bank_accounts%rowtype; l bank_statement_lines%rowtype;
begin
 sid:=case when tg_op='DELETE' then old.settlement_id else new.settlement_id end;
 if tg_op='UPDATE' and exists(select 1 from ins_cancellation_cash_requests where old.settlement_id in(settlement_id,to_settlement_id) or new.settlement_id in(settlement_id,to_settlement_id)) then raise exception 'INS_CXL_CASH_MATCH: matches are immutable; unmatch/rematch'; end if;
 select * into q from ins_cancellation_cash_requests where sid in(settlement_id,to_settlement_id) and kind<>'void';
 if found then select * into c from ins_policy_cancellations where id=q.cancellation_id;
 else select cx.* into c from ins_policy_cancellations cx join ins_policy_cash_items k on k.source_id=cx.policy_id join fin_allocations a on a.open_item_id=k.id where a.settlement_id=sid and cx.status='posted' limit 1; end if;
 if c.id is null then if tg_op='DELETE' then return old; else return new; end if; end if;
 perform ins_policy_cash_require_finance(); perform id from ins_policies where id=c.policy_id for update;
 select * into s from fin_settlements where id=sid for update;
 if q.id is not null then
 if auth.uid() in(q.maker_id,q.checker_id,s.created_by) then raise exception 'INS_CXL_CASH_THIRD_PERSON: a third distinct Finance reconciler is required' using errcode='42501'; end if;
 if tg_op<>'DELETE' then
 select * into b from fin_bank_accounts where id=s.bank_account_id; select * into l from bank_statement_lines where id=new.bank_statement_line_id;
 if s.status<>'posted' or q.status<>'posted' or new.matched_by is distinct from auth.uid() or new.tenant_id<>s.tenant_id or new.variance is distinct from 0 or l.tenant_id<>s.tenant_id or l.bank_account<>b.name or l.currency<>s.currency or l.amount<>(case s.direction when 'in' then s.amount else -s.amount end) then raise exception 'INS_CXL_CASH_MATCH: exact bank, currency, amount and acting reconciler required'; end if;
 end if;
 end if;
 if tg_op='DELETE' and(s.direction='in' or q.kind='commission_return') and exists(select 1 from ins_cancellation_cash_requests where cancellation_id=c.id and status='posted' and kind in('refund','remittance','commission_withdrawal')) then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: reverse downstream cancellation payments before removing funding evidence'; end if;
 if q.id is not null then insert into ins_cancellation_cash_events(tenant_id,request_id,event,actor_id,detail) values(c.tenant_id,q.id,case tg_op when 'DELETE' then 'unmatched' else 'matched' end,auth.uid(),case tg_op when 'DELETE' then to_jsonb(old) else to_jsonb(new) end); end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
create trigger ins_cancellation_cash_reconciliation before insert or update or delete on public.bank_reconciliations for each row execute function public.ins_cancellation_cash_reconciliation_guard();

create function public.ins_cancellation_cash_evidence_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare keys text[]:=array['status','checker_id','checked_at','decision_reason','settlement_id','to_settlement_id','operation_txid','voided_by_request_id'];
begin
 if tg_op='DELETE' or tg_table_name<>'ins_cancellation_cash_requests' then raise exception 'INS_CXL_CASH_IMMUTABLE: evidence cannot be rewritten'; end if;
 if(to_jsonb(old)-keys) is distinct from(to_jsonb(new)-keys) then raise exception 'INS_CXL_CASH_IMMUTABLE: request instructions cannot change'; end if;
 perform ins_policy_cash_require_finance();
 if old.status='posted' and new.status='voided' and exists(select 1 from ins_cancellation_cash_requests v where v.id=new.voided_by_request_id and v.voids_request_id=old.id and v.status='posting' and v.operation_txid=txid_current() and v.checker_id=auth.uid()) then return new; end if;
 if old.status='pending' and new.status in('posting','rejected','cancelled') then
 if(new.status='cancelled' and old.maker_id=auth.uid()) or(new.status<>'cancelled' and new.checker_id=auth.uid() and old.maker_id<>auth.uid()) then return new; end if;
 elsif old.status='posting' and new.status in('posting','posted') and old.operation_txid=txid_current() and old.checker_id=auth.uid() then return new;
 end if;
 raise exception 'INS_CXL_CASH_IMMUTABLE: invalid evidence transition';
end $$;
create trigger ins_cancellation_cash_request_guard before update or delete on public.ins_cancellation_cash_requests for each row execute function public.ins_cancellation_cash_evidence_guard();
do $$ declare t text; begin foreach t in array array['ins_cancellation_cash_journals','ins_cancellation_cash_events','ins_cancellation_commission_events'] loop
 execute format('create trigger ins_cancellation_cash_immutable before update or delete on public.%I for each row execute function public.ins_cancellation_cash_evidence_guard()',t); end loop; end $$;
create function public.ins_cancellation_cash_complete_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; s fin_settlements%rowtype;
begin
 select * into q from ins_cancellation_cash_requests where id=new.id; select * into c from ins_policy_cancellations where id=q.cancellation_id;
 if q.status='posting' then raise exception 'INS_CXL_CASH_INCOMPLETE: transaction cannot commit while posting'; end if;
 if q.status in('posted','voided') and q.kind<>'void' then
 if(q.kind in('commission_return','commission_withdrawal'))<>(q.to_settlement_id is not null) then raise exception 'INS_CXL_CASH_INCOMPLETE: internal transfers need both legs'; end if;
 for s in select * from fin_settlements where id in(q.settlement_id,q.to_settlement_id) loop
 if s.amount<>q.amount or s.created_by<>q.checker_id or s.journal_entry_id is null or s.status<>(case q.status when 'voided' then 'void' else 'posted' end) then raise exception 'INS_CXL_CASH_INCOMPLETE: settlement differs from approval'; end if;
 if q.kind in('commission_return','commission_withdrawal') then
 if exists(select 1 from fin_allocations where settlement_id=s.id) then raise exception 'INS_CXL_CASH_INCOMPLETE: internal transfers cannot settle third-party balances'; end if;
 elsif(select coalesce(sum(amount),0) from fin_allocations where settlement_id=s.id)<>q.amount then raise exception 'INS_CXL_CASH_INCOMPLETE: exact allocation required'; end if;
 end loop;
 if(select coalesce(sum(l.debit-l.credit),0) from ins_cancellation_cash_journals j join journal_entry_lines l on l.journal_entry_id=j.journal_entry_id where j.request_id=q.id and l.gl_account_id=c.clearing_gl_account_id)<>0 then raise exception 'INS_CXL_CASH_INCOMPLETE: transfer clearing must net to zero'; end if;
 end if; return null;
end $$;
create constraint trigger ins_cancellation_cash_complete after insert or update on public.ins_cancellation_cash_requests deferrable initially deferred for each row execute function public.ins_cancellation_cash_complete_guard();

create function public.ins_cancellation_cash_history_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if tg_table_name='fin_settlements' then
 if new.status is distinct from old.status and exists(select 1 from ins_cancellation_cash_requests where old.id in(settlement_id,to_settlement_id)) and not platform_ins_cancellation_cash_void_authorized(old.id) then raise exception 'INS_CXL_CASH_VOID_REQUIRED: independent cancellation cash void approval required'; end if;
 elsif new.status is distinct from old.status and exists(select 1 from ins_cancellation_cash_journals where journal_entry_id=old.id) then raise exception 'INS_CXL_CASH_IMMUTABLE: cash journals cannot be independently voided'; end if;
 return new;
end $$;
create trigger ins_cancellation_cash_settlement_history before update on public.fin_settlements for each row execute function public.ins_cancellation_cash_history_guard();
create trigger ins_cancellation_cash_journal_history before update on public.journal_entries for each row execute function public.ins_cancellation_cash_history_guard();

create function public.ins_cancellation_cash_context(p_policy_id uuid,p_bank_account_id uuid default null,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; v jsonb; rows jsonb; banks jsonb:='[]';
begin
 if auth.uid() is null or not(can_access_insurance() or is_finance_team_member('finance')) then raise exception 'INS_FORBIDDEN: Insurance or Finance required' using errcode='42501'; end if;
 if p_bank_account_id is not null and(not is_finance_team_member('finance') or effective_user_id() is distinct from auth.uid()) then raise exception 'INS_CXL_CASH_BANK: bank-book views require acting Finance membership' using errcode='42501'; end if;
 if p_offset is null or p_offset<0 then raise exception 'INS_CXL_CASH_INPUT: invalid page'; end if;
 select * into c from ins_policy_cancellations where policy_id=p_policy_id and tenant_id=get_my_tenant_id() and status='posted';
 if not found then return jsonb_build_object('policy_id',p_policy_id,'available',false); end if;
 if p_bank_account_id is not null and not exists(select 1 from fin_bank_accounts where id=p_bank_account_id and tenant_id=c.tenant_id) then raise exception 'INS_CXL_CASH_BANK: bank outside this company'; end if;
 v:=platform_ins_cancellation_cash_position(c.id,p_bank_account_id);
 select coalesce(jsonb_agg(to_jsonb(q)||jsonb_build_object('amount',q.amount::text,
 'matched',platform_ins_cancellation_cash_proven(q.settlement_id),'destination_matched',platform_ins_cancellation_cash_proven(q.to_settlement_id),
 'void_requested',exists(select 1 from ins_cancellation_cash_requests vr where vr.voids_request_id=q.id and vr.status in('pending','posting','posted')),'settlement_no',(select settlement_no from fin_settlements where id=q.settlement_id),'destination_settlement_no',(select settlement_no from fin_settlements where id=q.to_settlement_id),
 'journals',coalesce((select jsonb_agg(to_jsonb(j)) from ins_cancellation_cash_journals j where j.request_id=q.id),'[]'::jsonb)) order by q.created_at desc,q.id),'[]'::jsonb) into rows
 from(select * from ins_cancellation_cash_requests where cancellation_id=c.id order by created_at desc,id limit 25 offset p_offset) q;
 if is_finance_team_member('finance') and effective_user_id()=auth.uid() then select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'kind',kind,'currency',currency) order by name),'[]'::jsonb) into banks from fin_bank_accounts where tenant_id=c.tenant_id and is_active and currency=fin_ledger_currency(c.tenant_id); end if;
 return v||jsonb_build_object('available',true,'selected_bank_id',p_bank_account_id,'actor_id',auth.uid(),'can_finance',is_finance_team_member('finance') and effective_user_id()=auth.uid(),'cancellation_no',c.cancellation_no,'banks',banks,'requests',rows,'offset',p_offset,'has_more',(select count(*)>p_offset+25 from ins_cancellation_cash_requests where cancellation_id=c.id));
end $$;

-- Explicit privileges: no client can manufacture the private posting context.
do $$ declare r record; begin
 for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and
 (p.proname like 'platform_ins_cancellation_cash_%' or p.proname in('ins_cancellation_cash_reconciliation_guard','ins_cancellation_cash_evidence_guard','ins_cancellation_cash_complete_guard','ins_cancellation_cash_history_guard')) loop execute format('revoke all on function %s from public,anon,authenticated',r.f); end loop;
end $$;
revoke all on function public.ins_submit_cancellation_cash(uuid,text,uuid,uuid,uuid,numeric,date,text,text,uuid),public.ins_submit_cancellation_cash_void(uuid,text,uuid),public.ins_decide_cancellation_cash(uuid,text,text),public.ins_cancellation_cash_context(uuid,uuid,integer) from public,anon;
grant execute on function public.ins_submit_cancellation_cash(uuid,text,uuid,uuid,uuid,numeric,date,text,text,uuid),public.ins_submit_cancellation_cash_void(uuid,text,uuid),public.ins_decide_cancellation_cash(uuid,text,text),public.ins_cancellation_cash_context(uuid,uuid,integer) to authenticated;

create or replace function public.ins_policy_cash_allocation_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare m record; s fin_settlements%rowtype; q ins_policy_cash_requests%rowtype;
begin
 if platform_ins_cancellation_cash_authorized(new.open_item_id,new.settlement_id,new.amount) then return new; end if;
 select * into m from ins_policy_cash_items where id=new.open_item_id and tenant_id=new.tenant_id;
 if m.source_type not in('ins_policy_premium','ins_policy_insurer') then return new; end if;
 perform ins_policy_cash_require_finance();
 select * into s from fin_settlements where id=new.settlement_id and tenant_id=new.tenant_id;
 select * into q from ins_policy_cash_requests where tenant_id=new.tenant_id and policy_id=m.source_id
  and insurer_share_id is not distinct from m.insurer_share_id
  and status='posting' and operation_txid=txid_current() and checker_id=auth.uid() and maker_id<>auth.uid()
  and bank_account_id=s.bank_account_id and amount=new.amount and amount=s.amount and cash_date=s.settlement_date
  and kind=case m.source_type when 'ins_policy_premium' then 'receipt' else 'remittance' end
  and(settlement_id is null or settlement_id=s.id) for update;
 if q.id is null or s.direction<>(case q.kind when 'receipt' then 'in' else 'out' end)
  or s.party_account_id<>m.party_account_id or exists(select 1 from fin_allocations where settlement_id=s.id) then
   raise exception 'INS_CASH_APPROVAL_REQUIRED: independent Finance approval required for this insurer payable';
 end if;
 perform ins_policy_cash_validate(q.policy_id,q.kind,q.bank_account_id,q.amount,q.cash_date,q.insurer_share_id);
 update ins_policy_cash_requests set settlement_id=s.id where id=q.id;
 return new;
end $$;

create or replace function public.ins_cancellation_finance_lock_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if tg_table_name='fin_allocations' then if platform_ins_cancellation_cash_authorized(new.open_item_id,new.settlement_id,new.amount) then return new; end if;
 elsif tg_table_name='fin_settlements' then if platform_ins_cancellation_cash_void_authorized(old.id) then return new; end if; end if;
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

create or replace function public.ins_policy_cash_void_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare x record; v jsonb;
begin
 if platform_ins_cancellation_cash_void_authorized(old.id) then return new; end if;
  if old.status<>'posted' or new.status<>'void' then return new; end if;
  for x in select i.source_id as policy_id,sum(a.amount) as removed
    from fin_allocations a join ins_policy_cash_items i on i.id=a.open_item_id and i.tenant_id=a.tenant_id
    where a.settlement_id=old.id and i.source_type='ins_policy_premium'
    group by i.source_id order by i.source_id
  loop
    perform id from ins_policies where id=x.policy_id and tenant_id=old.tenant_id for update;
    v := ins_policy_cash_totals(x.policy_id);
    if (v->>'collected')::numeric-x.removed < (v->>'remitted')::numeric+(v->>'commission_transferred')::numeric then
      raise exception 'INS_CASH_FUNDS_IN_USE: reverse the funded remittances/commission transfers before voiding this receipt';
    end if;
    if exists(select 1 from ins_policy_insurer_shares sh join ins_policy_financial_snapshots sn on sn.policy_id=sh.policy_id and sn.extended
      where sh.policy_id=x.policy_id and trunc((sh.premium_amount+sh.pass_through_amount)*least(greatest((v->>'collected')::numeric-x.removed,0)/sn.invoice_total,1),2)
        < (ins_share_cash_totals(sh.id)->>'remitted')::numeric+(ins_share_cash_totals(sh.id)->>'commission_transferred')::numeric) then
      raise exception 'INS_CASH_FUNDS_IN_USE: receipt reduction would underfund an individual insurer share';
    end if;

  end loop;
  -- Outgoing voids also serialize with concurrent approvals and receipt voids.
  perform p.id from ins_policies p join ins_policy_cash_items i on i.source_id=p.id and i.tenant_id=p.tenant_id
    join fin_allocations a on a.open_item_id=i.id and a.tenant_id=i.tenant_id
    where a.settlement_id=old.id and i.source_type='ins_policy_insurer' order by p.id for update of p;
  return new;
end $$;

create or replace function public.ins_commission_on_settlement_posted()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r          record;
  v_unearned uuid;
  v_income   uuid;
  v_ev       uuid;
  v_je       journal_entries;
begin
 if exists(select 1 from ins_cancellation_cash_requests where new.id in(settlement_id,to_settlement_id)) then return new; end if;
  if new.direction <> 'out' or new.status <> 'posted' or new.journal_entry_id is null then
    return new;
  end if;

  for r in
    select e.id as entry_id, e.amount, p.policy_no
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type in ('ins_policy_insurer','ins_policy_share_insurer')
    join ins_commission_entries e on ((e.insurer_share_id=i.source_id and i.source_type='ins_policy_share_insurer') or (e.policy_id=i.source_id and e.insurer_share_id is null and i.source_type='ins_policy_insurer')) and e.tenant_id=i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      and e.status = 'deferred'
      and ins_item_paid_amount(i.id) >= i.amount
    order by p.policy_no
    for update of e
  loop
    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: paying the insurer for % earns commission, which needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_ev := gen_random_uuid();
    v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition', v_ev, new.settlement_date,
      'Commission earned on ' || r.policy_no,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_unearned, 'debit',  r.amount, 'description', 'Commission earned on ' || r.policy_no),
        jsonb_build_object('gl_account_id', v_income,   'credit', r.amount, 'description', 'Commission earned on ' || r.policy_no)));

    insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, new.tenant_id, r.entry_id, 'recognised', r.amount, v_je.id, new.id);

    update ins_commission_entries
       set status = 'earned', earned_on = new.settlement_date, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$$;

create or replace function public.ins_commission_on_settlement_voided()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r          record;
  v_unearned uuid;
  v_income   uuid;
  v_ev       uuid;
  v_je       journal_entries;
  v_date     date;
begin
 if exists(select 1 from ins_cancellation_cash_requests where new.id in(settlement_id,to_settlement_id)) then return new; end if;
  if new.direction <> 'out' or old.status <> 'posted' or new.status <> 'void' then
    return new;
  end if;

  select entry_date into v_date from journal_entries where id = new.void_journal_entry_id;
  v_date := coalesce(v_date, current_date);

  for r in
    select e.id as entry_id, e.amount, e.status as entry_status, p.policy_no
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type in ('ins_policy_insurer','ins_policy_share_insurer')
    join ins_commission_entries e on ((e.insurer_share_id=i.source_id and i.source_type='ins_policy_share_insurer') or (e.policy_id=i.source_id and e.insurer_share_id is null and i.source_type='ins_policy_insurer')) and e.tenant_id=i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      and e.status in ('earned', 'transferred')
      and ins_item_paid_amount(i.id) < i.amount
    order by p.policy_no
    for update of e
  loop
    if r.entry_status = 'transferred' then
      raise exception 'INS_COMMISSION_TRANSFERRED: commission on % has already been transferred to the operating account; void that commission transfer first', r.policy_no;
    end if;

    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: reversing commission on % needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_ev := gen_random_uuid();
    v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition_reversal', v_ev, v_date,
      'Commission no longer earned on ' || r.policy_no || ' (settlement voided)',
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_income,   'debit',  r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no),
        jsonb_build_object('gl_account_id', v_unearned, 'credit', r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no)));

    insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, new.tenant_id, r.entry_id, 'recognition_reversed', r.amount, v_je.id, new.id);

    update ins_commission_entries
       set status = 'deferred', earned_on = null, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$$;

create or replace function public.auto_match_bank_statement(p_bank_account text,p_date_from date,p_date_to date)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare tid uuid:=get_my_tenant_id(); line record; n integer; src text; candidate uuid; matched integer:=0;
begin
  if not is_finance_team_member('finance') then raise exception 'not authorized to auto-match bank transactions'; end if;
  for line in select l.id from bank_statement_lines l left join bank_reconciliations r on r.bank_statement_line_id=l.id
    where l.tenant_id=tid and l.bank_account=p_bank_account and l.statement_date between p_date_from and p_date_to
      and r.id is null order by l.statement_date,l.imported_at,l.id
  loop
    select count(*),min(c.source),(array_agg(c.candidate_id))[1] into n,src,candidate
      from fin_bank_line_candidates(line.id,tid) c;
    if n<>1 then continue; end if;
    if src='settlement' and exists(select 1 from fin_allocations a join ins_policy_cash_items i on i.id=a.open_item_id
      where a.settlement_id=candidate and i.source_type in ('ins_policy_premium','ins_policy_insurer')) then
      if effective_user_id() is distinct from auth.uid() or auth.uid() is null
        or exists(select 1 from fin_settlements s where s.id=candidate and s.created_by=auth.uid())
        or exists(select 1 from ins_policy_cash_requests q where q.settlement_id=candidate
                    and auth.uid() in (q.maker_id,q.checker_id)) then continue; end if;
    end if;
    if src='settlement' and exists(select 1 from ins_cancellation_cash_requests q where candidate in(q.settlement_id,q.to_settlement_id) and (effective_user_id() is distinct from auth.uid() or auth.uid() in(q.maker_id,q.checker_id))) then continue; end if;
    if src='settlement' then
      insert into bank_reconciliations(tenant_id,bank_statement_line_id,settlement_id,match_type,variance,matched_by)
        values(tid,line.id,candidate,'auto',0,auth.uid());
    elsif src in ('transfer_from','transfer_to') then
      insert into bank_reconciliations(tenant_id,bank_statement_line_id,commission_transfer_id,transfer_side,match_type,variance,matched_by)
        values(tid,line.id,candidate,substr(src,10),'auto',0,auth.uid());
    else
      insert into bank_reconciliations(tenant_id,bank_statement_line_id,cash_bank_transaction_id,match_type,variance,matched_by)
        values(tid,line.id,candidate,'auto',0,auth.uid());
    end if;
    matched:=matched+1;
  end loop;
  return matched;
end $$;

-- Take policy lock before the generic matcher takes its settlement lock, in the
-- same order as payment/void approval. Direct table routes still hit the guard.
alter function public.match_bank_statement_line_to_settlement(uuid,uuid) rename to platform_ins_cxl_before_match_settlement;
revoke all on function public.platform_ins_cxl_before_match_settlement(uuid,uuid) from public,anon,authenticated;
create function public.match_bank_statement_line_to_settlement(p_statement_line_id uuid,p_settlement_id uuid) returns public.bank_reconciliations
language plpgsql security definer set search_path=public,pg_temp as $$
declare pid uuid;
begin
 select c.policy_id into pid from ins_policy_cancellations c where c.tenant_id=get_my_tenant_id() and
 (exists(select 1 from ins_cancellation_cash_requests q where q.cancellation_id=c.id and p_settlement_id in(q.settlement_id,q.to_settlement_id)) or exists(select 1 from ins_policy_cash_items k join fin_allocations a on a.open_item_id=k.id where k.source_id=c.policy_id and a.settlement_id=p_settlement_id));
 if pid is not null then perform ins_policy_cash_require_finance(); perform id from ins_policies where id=pid for update; end if;
 return platform_ins_cxl_before_match_settlement(p_statement_line_id,p_settlement_id);
end $$;
revoke all on function public.match_bank_statement_line_to_settlement(uuid,uuid) from public,anon;
grant execute on function public.match_bank_statement_line_to_settlement(uuid,uuid) to authenticated;
alter function public.unmatch_bank_reconciliation(uuid) rename to platform_ins_cxl_before_unmatch;
revoke all on function public.platform_ins_cxl_before_unmatch(uuid) from public,anon,authenticated;
create function public.unmatch_bank_reconciliation(p_reconciliation_id uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare pid uuid; sid uuid;
begin
 select settlement_id into sid from bank_reconciliations where id=p_reconciliation_id and tenant_id=get_my_tenant_id();
 select c.policy_id into pid from ins_policy_cancellations c where c.tenant_id=get_my_tenant_id() and
 (exists(select 1 from ins_cancellation_cash_requests q where q.cancellation_id=c.id and sid in(q.settlement_id,q.to_settlement_id)) or exists(select 1 from ins_policy_cash_items k join fin_allocations a on a.open_item_id=k.id where k.source_id=c.policy_id and a.settlement_id=sid));
 if pid is not null then perform ins_policy_cash_require_finance(); perform id from ins_policies where id=pid for update; end if;
 perform platform_ins_cxl_before_unmatch(p_reconciliation_id);
end $$;
revoke all on function public.unmatch_bank_reconciliation(uuid) from public,anon;
grant execute on function public.unmatch_bank_reconciliation(uuid) to authenticated;

-- Preserve the original entry/transfer, project post-cancellation retained
-- earnings and partial withdrawals using independent immutable evidence.
create or replace view public.ins_commission_ledger with(security_invoker=true) as
select e.id,e.tenant_id,e.policy_id,p.policy_no,coalesce(s.insurer_id,p.insurer_id) as insurer_id,p.client_id,
 coalesce(a.retained_commission,e.amount)::numeric(18,2) as amount,
 case when a.id is null then e.status when a.retained_commission_status='transferred' then 'transferred'
 when coalesce(w.amount,0)>=a.retained_commission and a.retained_commission>0 then 'transferred'
 when a.retained_commission_status='deferred' and coalesce(r.amount,0)=0 then 'deferred' else 'earned' end as status,
 coalesce(e.earned_on,case when a.retained_commission_status='earned' then c.posting_date when coalesce(r.amount,0)>0 then r.earned_on end) as earned_on,
 e.transfer_id,t.transfer_no,t.transfer_date,e.created_at,e.updated_at,
 e.insurer_share_id,(coalesce(s.premium_amount,p.gross_premium)-coalesce(a.return_premium,0))::numeric(18,2) as allocated_premium,
 coalesce(s.commission_rate_pct,p.commission_rate_pct) as commission_rate_pct,
 case when a.id is null then case when e.status in('earned','transferred') then e.amount else 0 end
 when a.retained_commission_status<>'deferred' or coalesce(r.amount,0)>0 then a.retained_commission else 0 end as earned_commission,
 case when a.id is null then case when e.status='transferred' then 0 else e.amount end
 when a.retained_commission_status='transferred' then 0 else greatest(a.retained_commission-coalesce(w.amount,0),0) end as untransferred_commission,c.id as cancellation_id
from ins_commission_entries e join ins_policies p on p.id=e.policy_id
left join ins_policy_insurer_shares s on s.id=e.insurer_share_id and s.tenant_id=e.tenant_id
left join ins_commission_transfers t on t.id=e.transfer_id
left join ins_cancellation_insurer_adjustments a on a.original_commission_entry_id=e.id
left join ins_policy_cancellations c on c.id=a.cancellation_id
left join lateral(select sum(ev.amount) as amount,max(j.entry_date) filter(where ev.amount>0) as earned_on from ins_cancellation_commission_events ev join journal_entries j on j.id=ev.journal_entry_id where ev.adjustment_id=a.id) r on true
left join lateral(select sum(amount) as amount from ins_cancellation_cash_requests where adjustment_id=a.id and kind='commission_withdrawal' and status='posted') w on true
where p.status<>'reversed';
create or replace view public.ins_commission_position with(security_invoker=true) as
select tenant_id,coalesce(sum(amount) filter(where status='deferred'),0) as unearned_amount,
 coalesce(sum(untransferred_commission) filter(where status='earned'),0) as earned_in_client_money,
 coalesce(sum(amount-untransferred_commission) filter(where status in('earned','transferred')),0) as transferred_amount
from ins_commission_ledger group by tenant_id;

-- A concurrent generic/manual bank journal must not slip between checking the
-- actual bank book and posting cancellation cash. One tenant journal mutex,
-- including status changes, also covers bank movements outside this workflow.
create function public.ins_cancellation_cash_book_lock() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare tid uuid;
begin
 tid:=case when tg_op='DELETE' then old.tenant_id else new.tenant_id end;
 if exists(select 1 from ins_policy_cancellations where tenant_id=tid and status='posted') then perform pg_advisory_xact_lock(hashtextextended('ins-cxl-cash-book:'||tid::text,0)); end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
create trigger ins_cancellation_cash_book_lock before insert or update of status or delete on public.journal_entries for each row execute function public.ins_cancellation_cash_book_lock();
create function public.ins_cancellation_cash_bank_history_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if(new.name,new.kind,new.currency,new.gl_account_id) is distinct from(old.name,old.kind,old.currency,old.gl_account_id) and
 (exists(select 1 from ins_cancellation_cash_requests where old.id in(bank_account_id,to_bank_account_id)) or
 exists(select 1 from ins_policy_cancellations c join ins_policy_cash_items k on k.source_id=c.policy_id join fin_allocations a on a.open_item_id=k.id join fin_settlements s on s.id=a.settlement_id where c.status='posted' and s.bank_account_id=old.id) or
 exists(select 1 from ins_cancellation_insurer_adjustments a join ins_commission_transfers t on t.id=(a.original_commission_state->>'transfer_id')::uuid where old.id in(t.from_bank_account_id,t.to_bank_account_id))) then
 raise exception 'INS_CXL_CASH_BANK_HISTORY: cancellation bank identity, currency, kind and GL are immutable; use a separately reviewed bank migration'; end if;
 return new;
end $$;
create trigger ins_cancellation_cash_bank_history before update on public.fin_bank_accounts for each row execute function public.ins_cancellation_cash_bank_history_guard();
revoke all on function public.ins_cancellation_cash_book_lock(),public.ins_cancellation_cash_bank_history_guard() from public,anon,authenticated;
select public.apply_tenant_read_only_guard();
