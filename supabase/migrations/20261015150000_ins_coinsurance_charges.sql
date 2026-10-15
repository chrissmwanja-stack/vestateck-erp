-- Additive co-insurance and charge accounting. Existing single-insurer/no-charge
-- policies continue through the unmodified legacy bind implementation.
-- No discounts/loadings, separate levy payees, multi-insurer claim contributions,
-- or complex cancellation/reversal accounting are introduced here.

create table public.ins_policy_insurer_shares (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(id) on delete cascade,
 policy_id uuid not null,
 insurer_id uuid not null,
 is_lead boolean not null default false,
 share_pct numeric(7,4) not null check(share_pct>0 and share_pct<=100),
 commission_rate_pct numeric(7,4) not null check(commission_rate_pct>=0 and commission_rate_pct<100),
 insurer_policy_no text,
 premium_amount numeric(18,2),
 pass_through_amount numeric(18,2),
 commission_amount numeric(18,2),
 payable_amount numeric(18,2),
 reviewed boolean not null default false,
 unique(tenant_id,id), unique(policy_id,insurer_id),
 foreign key(tenant_id,policy_id) references public.ins_policies(tenant_id,id) on delete cascade,
 foreign key(tenant_id,insurer_id) references public.ins_insurers(tenant_id,id)
);
create index ins_policy_insurer_shares_insurer_idx on public.ins_policy_insurer_shares(tenant_id,insurer_id);
alter table public.gl_accounts add constraint gl_accounts_tenant_id_id_coinsurance_key unique(tenant_id,id);
create table public.ins_policy_charges (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(id) on delete cascade,
 policy_id uuid not null,
 kind text not null check(kind in ('insurer_pass_through','broker_fee')),
 description text not null check(length(btrim(description))>0),
 amount numeric(18,2) check(amount>=0),
 recipient_mode text not null check(recipient_mode in ('all_insurers','one_insurer','broker')),
 recipient_insurer_id uuid,
 vat_mode text not null default 'not_calculated' check(vat_mode in ('not_calculated','exclusive')),
 vat_rate_pct numeric(7,4),
 vat_amount numeric(18,2),
 income_gl_account_id uuid,
 reviewed boolean not null default false,
 unique(tenant_id,id),
 foreign key(tenant_id,policy_id) references public.ins_policies(tenant_id,id) on delete cascade,
 foreign key(tenant_id,recipient_insurer_id) references public.ins_insurers(tenant_id,id),
 foreign key(tenant_id,income_gl_account_id) references public.gl_accounts(tenant_id,id),
 check((kind='broker_fee' and recipient_mode='broker' and recipient_insurer_id is null)
    or (kind='insurer_pass_through' and vat_mode='not_calculated' and
      ((recipient_mode='all_insurers' and recipient_insurer_id is null)
       or (recipient_mode='one_insurer' and recipient_insurer_id is not null)))),
 check((vat_mode='not_calculated' and vat_rate_pct is null)
    or (vat_mode='exclusive' and vat_rate_pct>0 and vat_rate_pct<=100))
);
create index ins_policy_charges_policy_idx on public.ins_policy_charges(tenant_id,policy_id);
create index ins_policy_charges_income_idx on public.ins_policy_charges(income_gl_account_id);
create index ins_policy_charges_recipient_idx on public.ins_policy_charges(recipient_insurer_id);
create table public.ins_policy_financial_snapshots (
 policy_id uuid primary key,
 tenant_id uuid not null references public.tenants(id) on delete cascade,
 extended boolean not null,
 invoice_total numeric(18,2) not null check(invoice_total>0),
 broker_fee_total numeric(18,2) not null,
 vat_total numeric(18,2) not null,
 snapshot jsonb not null,
 journal_entry_id uuid not null references public.journal_entries(id),
 bound_by uuid not null,
 bound_at timestamptz not null default now(),
 foreign key(tenant_id,policy_id) references public.ins_policies(tenant_id,id)
);
create index ins_policy_financial_snapshots_tenant_idx on public.ins_policy_financial_snapshots(tenant_id);
create index ins_policy_financial_snapshots_journal_idx on public.ins_policy_financial_snapshots(journal_entry_id);

alter table public.ins_policy_insurer_shares enable row level security;
alter table public.ins_policy_charges enable row level security;
alter table public.ins_policy_financial_snapshots enable row level security;
revoke all on public.ins_policy_insurer_shares,public.ins_policy_charges,public.ins_policy_financial_snapshots from public,anon,authenticated;
grant select on public.ins_policy_insurer_shares,public.ins_policy_charges,public.ins_policy_financial_snapshots to authenticated;
create policy ins_policy_insurer_shares_select on public.ins_policy_insurer_shares for select to authenticated
 using(tenant_id=get_my_tenant_id() and (can_access_insurance() or is_finance_team_member('finance')));
create policy ins_policy_charges_select on public.ins_policy_charges for select to authenticated
 using(tenant_id=get_my_tenant_id() and (can_access_insurance() or is_finance_team_member('finance')));
create policy ins_policy_financial_snapshots_select on public.ins_policy_financial_snapshots for select to authenticated
 using(tenant_id=get_my_tenant_id() and (can_access_insurance() or is_finance_team_member('finance')));

-- Bound configuration is immutable even through alternate privileged writers.
create function public.ins_financial_configuration_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare pid uuid;
begin
 if tg_table_name='ins_policy_financial_snapshots' then
   if tg_op<>'INSERT' then raise exception 'INS_FINANCIAL_IMMUTABLE: bind snapshot cannot be changed or deleted'; end if;
   return new;
 end if;
 pid:=case when tg_op='DELETE' then old.policy_id else new.policy_id end;
 perform id from ins_policies where id=pid for update;
 if exists(select 1 from ins_policies where id=pid and status<>'draft') then
   raise exception 'INS_FINANCIAL_IMMUTABLE: insurer shares and charge lines are locked after bind';
 end if;
 if tg_op='UPDATE' and (new.policy_id is distinct from old.policy_id or new.tenant_id is distinct from old.tenant_id) then
   raise exception 'INS_FINANCIAL_IMMUTABLE: configuration cannot move between policies';
 end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
revoke all on function public.ins_financial_configuration_guard() from public,anon,authenticated;
create trigger ins_share_configuration_guard before insert or update or delete on public.ins_policy_insurer_shares
 for each row execute function public.ins_financial_configuration_guard();
create trigger ins_charge_configuration_guard before insert or update or delete on public.ins_policy_charges
 for each row execute function public.ins_financial_configuration_guard();
create trigger ins_snapshot_immutable before insert or update or delete on public.ins_policy_financial_snapshots
 for each row execute function public.ins_financial_configuration_guard();

alter table public.ins_commission_entries drop constraint ins_commission_entries_policy_key;
alter table public.ins_commission_entries add column insurer_share_id uuid;
alter table public.ins_commission_entries add constraint ins_commission_entries_share_fk foreign key(tenant_id,insurer_share_id)
 references public.ins_policy_insurer_shares(tenant_id,id);
create unique index ins_commission_entries_legacy_policy_key on public.ins_commission_entries(policy_id) where insurer_share_id is null;
create unique index ins_commission_entries_share_key on public.ins_commission_entries(insurer_share_id) where insurer_share_id is not null;
alter table public.ins_policy_cash_requests add column insurer_share_id uuid;
alter table public.ins_policy_cash_requests add constraint ins_policy_cash_requests_share_fk foreign key(tenant_id,insurer_share_id)
 references public.ins_policy_insurer_shares(tenant_id,id);
create index ins_policy_cash_requests_share_idx on public.ins_policy_cash_requests(insurer_share_id);

create function public.ins_set_policy_financial_configuration(p_policy_id uuid,p_shares jsonb,p_charges jsonb)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; x jsonb; lead_id uuid; n integer; total numeric;
begin
 if not can_manage_insurance() or effective_user_id() is distinct from auth.uid() then
   raise exception 'INS_FORBIDDEN: an Insurance manager acting as themselves is required' using errcode='42501';
 end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 if p.status<>'draft' then raise exception 'INS_FINANCIAL_IMMUTABLE: only drafts can be configured'; end if;
 if jsonb_typeof(p_shares) is distinct from 'array' or jsonb_typeof(p_charges) is distinct from 'array'
    or jsonb_array_length(p_shares)>30 or jsonb_array_length(p_charges)>100 then raise exception 'INS_CONFIG_INPUT: invalid configuration arrays'; end if;
 -- Existing IDs are draft-only; bound IDs never change and are used by allocations.
 delete from ins_policy_charges where policy_id=p.id;
 delete from ins_policy_insurer_shares where policy_id=p.id;
 for x in select * from jsonb_array_elements(p_shares) loop
   if (x->>'share_pct')::numeric is null or (x->>'share_pct')::numeric<>round((x->>'share_pct')::numeric,4)
      or (x->>'commission_rate_pct')::numeric is null or (x->>'commission_rate_pct')::numeric<>round((x->>'commission_rate_pct')::numeric,4)
      or not exists(select 1 from ins_insurers where id=(x->>'insurer_id')::uuid and tenant_id=p.tenant_id and is_active) then
     raise exception 'INS_CONFIG_INPUT: active insurer, share and commission rate are required (maximum four decimals)';
   end if;
   insert into ins_policy_insurer_shares(tenant_id,policy_id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,reviewed)
   values(p.tenant_id,p.id,(x->>'insurer_id')::uuid,coalesce((x->>'is_lead')::boolean,false),
    (x->>'share_pct')::numeric,(x->>'commission_rate_pct')::numeric,nullif(btrim(x->>'insurer_policy_no'),''),coalesce((x->>'reviewed')::boolean,false));
 end loop;
 select count(*) filter(where is_lead),sum(share_pct) into n,total from ins_policy_insurer_shares where policy_id=p.id;
 if jsonb_array_length(p_shares)>0 and (n<>1 or total<>100) then raise exception 'INS_SHARE_TOTAL: shares must total exactly 100%% with exactly one lead insurer'; end if;
 if jsonb_array_length(p_shares)=0 and jsonb_array_length(p_charges)>0 then raise exception 'INS_SHARE_REQUIRED: charges require explicit insurer allocation'; end if;
 for x in select * from jsonb_array_elements(p_charges) loop
   if (x->>'amount')::numeric is not null and ((x->>'amount')::numeric<>round((x->>'amount')::numeric,2) or (x->>'amount')::numeric>9999999999999999.99) then
     raise exception 'INS_CONFIG_INPUT: charge amounts need at most two decimals';
   end if;
   if (x->>'vat_rate_pct')::numeric is not null and (x->>'vat_rate_pct')::numeric<>round((x->>'vat_rate_pct')::numeric,4) then
     raise exception 'INS_CONFIG_INPUT: VAT rate accepts at most four decimals';
   end if;
   if x->>'recipient_mode'='one_insurer' and not exists(select 1 from ins_policy_insurer_shares where policy_id=p.id and insurer_id=(x->>'recipient_insurer_id')::uuid) then
     raise exception 'INS_CHARGE_RECIPIENT: intended insurer must participate in this policy';
   end if;
   insert into ins_policy_charges(tenant_id,policy_id,kind,description,amount,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,reviewed)
   values(p.tenant_id,p.id,x->>'kind',x->>'description',(x->>'amount')::numeric,x->>'recipient_mode',(x->>'recipient_insurer_id')::uuid,
    coalesce(x->>'vat_mode','not_calculated'),(x->>'vat_rate_pct')::numeric,(x->>'income_gl_account_id')::uuid,coalesce((x->>'reviewed')::boolean,false));
 end loop;
 select insurer_id into lead_id from ins_policy_insurer_shares where policy_id=p.id and is_lead;
 if lead_id is not null then
   perform set_config('ins.via_rpc','on',true);
   update ins_policies set insurer_id=lead_id,
    commission_rate_pct=case when jsonb_array_length(p_shares)=1 then (select commission_rate_pct from ins_policy_insurer_shares where policy_id=p.id) else commission_rate_pct end
    where id=p.id;
 end if;
end $$;
revoke all on function public.ins_set_policy_financial_configuration(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.ins_set_policy_financial_configuration(uuid,jsonb,jsonb) to authenticated;

alter function public.ins_bind_policy(uuid) rename to platform_ins_bind_policy_legacy_impl;
revoke all on function public.platform_ins_bind_policy_legacy_impl(uuid) from public,anon,authenticated;
create function public.ins_bind_policy(p_policy_id uuid) returns public.ins_policies
language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; s ins_policy_insurer_shares%rowtype; c ins_policy_charges%rowtype;
 n integer; leads integer; pct numeric; extended boolean; premium_used numeric:=0; part numeric;
 comm numeric:=0; payable numeric:=0; fees numeric:=0; vat numeric:=0; total numeric; ar uuid; insurer_account uuid;
 ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid; vat_gl uuid; lines jsonb; je journal_entries%rowtype; snap jsonb;
begin
 if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode='42501'; end if;
 select * into p from ins_policies where id=p_policy_id for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 perform assert_tenant_access(p.tenant_id);
 if p.status<>'draft' then raise exception 'INS_NOT_DRAFT: policy'; end if;
 select count(*),count(*) filter(where is_lead),sum(share_pct) into n,leads,pct from ins_policy_insurer_shares where policy_id=p.id;
 extended:=n>1 or exists(select 1 from ins_policy_charges where policy_id=p.id);
 if n>0 then
  if pct<>100 or leads<>1 then raise exception 'INS_SHARE_TOTAL: exactly 100%% and one lead required'; end if;
  if exists(select 1 from ins_policy_insurer_shares sh join ins_insurers i on i.id=sh.insurer_id where sh.policy_id=p.id and (not sh.reviewed or not i.is_active)) then
    raise exception 'INS_CONFIG_REVIEW: review every insurer share before binding';
  end if;
  if p.insurer_id is distinct from (select insurer_id from ins_policy_insurer_shares where policy_id=p.id and is_lead) then
    raise exception 'INS_SHARE_LEAD: policy insurer must match the configured lead';
  end if;
 end if;
 if not extended then
   if n=1 then
    if (select commission_rate_pct from ins_policy_insurer_shares where policy_id=p.id) is distinct from p.commission_rate_pct then
     raise exception 'INS_LEGACY_RATE: the single-insurer path uses the policy header rate (maximum two decimals)'; end if;
    update ins_policy_insurer_shares set premium_amount=p.gross_premium,pass_through_amount=0,commission_amount=round(p.gross_premium*p.commission_rate_pct/100,2),
     payable_amount=p.gross_premium-round(p.gross_premium*p.commission_rate_pct/100,2) where policy_id=p.id;
   end if;
   -- This function body, its journal and its TWO open items are unchanged.
   p:=platform_ins_bind_policy_legacy_impl(p.id);
   insert into ins_policy_financial_snapshots(policy_id,tenant_id,extended,invoice_total,broker_fee_total,vat_total,snapshot,journal_entry_id,bound_by)
   values(p.id,p.tenant_id,false,p.gross_premium,0,0,jsonb_build_object('policy',to_jsonb(p),'shares',coalesce((select jsonb_agg(to_jsonb(x)) from ins_policy_insurer_shares x where policy_id=p.id),'[]'::jsonb),'charges','[]'::jsonb,'open_items',(select jsonb_agg(to_jsonb(i)) from fin_open_items i where i.source_id=p.id and i.source_type in('ins_policy_premium','ins_policy_insurer'))),p.journal_entry_id,auth.uid());
   return p;
 end if;
 if p.gross_premium<=0 or p.currency<>fin_ledger_currency(p.tenant_id) then raise exception 'INS_CONFIG_INPUT: positive premium in ledger currency required'; end if;
 if exists(select 1 from ins_policy_charges where policy_id=p.id and (not reviewed or amount is null)) then
   raise exception 'INS_CONFIG_REVIEW: review charges and enter current amounts, including an explicit zero where intended';
 end if;
 if n=0 then raise exception 'INS_SHARE_REQUIRED: charges require insurer configuration'; end if;
 -- Largest-remainder allocation: exact cents, closest proportional amounts,
 -- deterministic insurer-ID tie-breaks; the lead has no rounding privilege.
 with amounts as (
  select id,insurer_id,trunc(p.gross_premium*share_pct/100,2) as base,
   p.gross_premium*share_pct/100-trunc(p.gross_premium*share_pct/100,2) as fraction
  from ins_policy_insurer_shares where policy_id=p.id
 ), ranked as(select *,row_number() over(order by fraction desc,insurer_id) as rank,
  round((p.gross_premium-sum(base) over())*100) as cents from amounts)
 update ins_policy_insurer_shares sh set premium_amount=r.base+case when r.rank<=r.cents then .01 else 0 end,
  pass_through_amount=0 from ranked r where sh.id=r.id;
 if exists(select 1 from ins_policy_insurer_shares where policy_id=p.id and premium_amount<=0) then
  raise exception 'INS_SHARE_TOO_SMALL: every insurer needs at least one cent of premium'; end if;
 update ins_policy_insurer_shares set commission_amount=round(premium_amount*commission_rate_pct/100,2) where policy_id=p.id;
 select sum(premium_amount) into premium_used from ins_policy_insurer_shares where policy_id=p.id;
 for c in select * from ins_policy_charges where policy_id=p.id order by id loop
   if c.kind='broker_fee' then
     fees:=fees+c.amount;
     part:=case c.vat_mode when 'exclusive' then round(c.amount*c.vat_rate_pct/100,2) else 0 end;
     vat:=vat+part;
     update ins_policy_charges set vat_amount=part where id=c.id;
   elsif c.recipient_mode='one_insurer' then
     update ins_policy_insurer_shares set pass_through_amount=pass_through_amount+c.amount where policy_id=p.id and insurer_id=c.recipient_insurer_id;
     if not found then raise exception 'INS_CHARGE_RECIPIENT: recipient does not participate'; end if;
   else
     with amounts as (
      select id,insurer_id,trunc(c.amount*share_pct/100,2) as base,
       c.amount*share_pct/100-trunc(c.amount*share_pct/100,2) as fraction
      from ins_policy_insurer_shares where policy_id=p.id
     ), ranked as(select *,row_number() over(order by fraction desc,insurer_id) as rank,
      round((c.amount-sum(base) over())*100) as cents from amounts)
     update ins_policy_insurer_shares sh set pass_through_amount=sh.pass_through_amount+r.base+case when r.rank<=r.cents then .01 else 0 end
      from ranked r where sh.id=r.id;
   end if;
 end loop;
 update ins_policy_insurer_shares set payable_amount=premium_amount-commission_amount+pass_through_amount where policy_id=p.id;
 select sum(commission_amount),sum(payable_amount) into comm,payable from ins_policy_insurer_shares where policy_id=p.id;
 total:=p.gross_premium+coalesce((select sum(amount) from ins_policy_charges where policy_id=p.id),0)+vat;
 if premium_used<>p.gross_premium or total<>payable+comm+fees+vat then raise exception 'INS_FINANCIAL_TOTAL: allocation does not reconcile'; end if;
 ar_gl:=get_posting_account(p.tenant_id,'ar_control'); pay_gl:=get_posting_account(p.tenant_id,'insurer_payable');
 unearned_gl:=get_posting_account(p.tenant_id,'unearned_commission'); income_gl:=get_posting_account(p.tenant_id,'commission_income');
 vat_gl:=get_posting_account(p.tenant_id,'vat_output');
 if ar_gl is null or pay_gl is null or (comm>0 and (unearned_gl is null or income_gl is null))
    or (vat>0 and vat_gl is null) then raise exception 'INS_POSTING_RULE_MISSING: configure receivables, insurer payable, commission and (when charged) vat_output'; end if;
 if exists(select 1 from ins_policy_charges chg where chg.policy_id=p.id and chg.kind='broker_fee' and chg.amount>0
   and not exists(select 1 from gl_accounts g where g.id=chg.income_gl_account_id and g.tenant_id=p.tenant_id and g.account_type='revenue' and g.is_active)) then
   raise exception 'INS_POSTING_RULE_MISSING: each broker fee needs an explicit active revenue account'; end if;
 if vat>0 and not exists(select 1 from gl_accounts where id=vat_gl and tenant_id=p.tenant_id and account_type='liability' and is_active) then raise exception 'INS_POSTING_RULE_MISSING: vat_output must map to active tax liability'; end if;
 ar:=ins_ensure_client_account(p.client_id);
 lines:=jsonb_build_array(jsonb_build_object('gl_account_id',ar_gl,'debit',total),jsonb_build_object('gl_account_id',pay_gl,'credit',payable));
 if comm>0 then lines:=lines||jsonb_build_object('gl_account_id',unearned_gl,'credit',comm); end if;
 for c in select * from ins_policy_charges where policy_id=p.id and kind='broker_fee' and amount>0 order by id loop
  lines:=lines||jsonb_build_object('gl_account_id',c.income_gl_account_id,'credit',c.amount);
 end loop;
 if vat>0 then lines:=lines||jsonb_build_object('gl_account_id',vat_gl,'credit',vat); end if;
 je:=post_journal_entry(p.tenant_id,'ins_policy_bind',p.id,p.inception_date,'Bind '||p.policy_no||' (insurer shares and charges)',lines);
 perform fin_create_open_item(p.tenant_id,ar,'ar_control','ins_policy_premium',p.id,p.policy_no,p.inception_date,p.inception_date,total,'Premium and charges: '||p.policy_no);
 for s in select * from ins_policy_insurer_shares where policy_id=p.id order by insurer_id loop
   insurer_account:=ins_ensure_insurer_account(s.insurer_id);
   if s.payable_amount<=0 then raise exception 'INS_FINANCIAL_TOTAL: each insurer payable must be positive'; end if;
   perform fin_create_open_item(p.tenant_id,insurer_account,'insurer_payable','ins_policy_share_insurer',s.id,p.policy_no,p.inception_date,p.inception_date,s.payable_amount,'Insurer share: '||p.policy_no);
   if s.commission_amount>0 then insert into ins_commission_entries(tenant_id,policy_id,insurer_share_id,amount) values(p.tenant_id,p.id,s.id,s.commission_amount); end if;
 end loop;
 perform set_config('ins.via_rpc','on',true);
 update ins_policies set status='active',commission_amount=comm,net_premium_to_insurer=p.gross_premium-comm,bound_at=now(),bound_by=auth.uid(),journal_entry_id=je.id where id=p.id returning * into p;
 if p.renewal_of_id is not null then update ins_policies set status='renewed' where id=p.renewal_of_id and tenant_id=p.tenant_id and status='active'; end if;
 snap:=jsonb_build_object('policy',to_jsonb(p),'shares',(select jsonb_agg(to_jsonb(x) order by insurer_id) from ins_policy_insurer_shares x where policy_id=p.id),
  'charges',coalesce((select jsonb_agg(to_jsonb(x) order by id) from ins_policy_charges x where policy_id=p.id),'[]'::jsonb),
  'open_items',(select jsonb_agg(to_jsonb(i)) from fin_open_items i where tenant_id=p.tenant_id and ((source_type='ins_policy_premium' and source_id=p.id)
    or(source_type='ins_policy_share_insurer' and source_id in(select id from ins_policy_insurer_shares where policy_id=p.id)))));
 insert into ins_policy_financial_snapshots(policy_id,tenant_id,extended,invoice_total,broker_fee_total,vat_total,snapshot,journal_entry_id,bound_by)
 values(p.id,p.tenant_id,true,total,fees,vat,snap,je.id,auth.uid());
 return p;
end $$;
revoke all on function public.ins_bind_policy(uuid) from public,anon;
grant execute on function public.ins_bind_policy(uuid) to authenticated;

-- Renewals copy structure, NOT historical monetary charges or review approval.
alter function public.ins_create_renewal_draft(uuid) rename to platform_ins_create_renewal_legacy_impl;
revoke all on function public.platform_ins_create_renewal_legacy_impl(uuid) from public,anon,authenticated;
create function public.ins_create_renewal_draft(p_policy_id uuid) returns public.ins_policies
language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype;
begin
 p:=platform_ins_create_renewal_legacy_impl(p_policy_id);
 insert into ins_policy_insurer_shares(tenant_id,policy_id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,reviewed)
 select tenant_id,p.id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,false from ins_policy_insurer_shares where policy_id=p_policy_id;
 insert into ins_policy_charges(tenant_id,policy_id,kind,description,amount,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,reviewed)
 select tenant_id,p.id,kind,description,null,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,false from ins_policy_charges where policy_id=p_policy_id;
 return p;
end $$;
revoke all on function public.ins_create_renewal_draft(uuid) from public,anon;
grant execute on function public.ins_create_renewal_draft(uuid) to authenticated;

alter function public.ins_policy_reversal_context(uuid,boolean) rename to platform_ins_policy_reversal_legacy_context;
revoke all on function public.platform_ins_policy_reversal_legacy_context(uuid,boolean) from public,anon,authenticated;
create function public.ins_policy_reversal_context(p_policy_id uuid,p_in_progress boolean default false) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not can_manage_insurance() or not exists(select 1 from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id()) then
   raise exception 'INS_FORBIDDEN: policy access required' using errcode='42501';
 end if;
 perform id from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if (select count(*) from ins_policy_insurer_shares where policy_id=p_policy_id)>1 or exists(select 1 from ins_policy_charges where policy_id=p_policy_id) then
   raise exception 'INS_REVERSAL_COMPLEX: co-insurance or ANY charge line (including zero) requires the future cancellation workflow';
 end if;
 return platform_ins_policy_reversal_legacy_context(p_policy_id,p_in_progress);
end $$;
revoke all on function public.ins_policy_reversal_context(uuid,boolean) from public,anon,authenticated;

-- Private normalization for shared cash controls: expose each share payable as
-- a policy insurer item WITHOUT changing its real Finance source/party identity.
create view public.ins_policy_cash_items with(security_invoker=true) as
select i.id,i.tenant_id,i.party_account_id,i.side,i.control_role,
 case i.source_type when 'ins_policy_share_insurer' then 'ins_policy_insurer' else i.source_type end as source_type,
 case i.source_type when 'ins_policy_share_insurer' then s.policy_id else i.source_id end as source_id,
 s.id as insurer_share_id
from public.fin_open_items i left join public.ins_policy_insurer_shares s
 on i.source_type='ins_policy_share_insurer' and s.id=i.source_id and s.tenant_id=i.tenant_id;
revoke all on public.ins_policy_cash_items from public,anon,authenticated;

-- Floor partial funding to cents. The final full collection releases the exact
-- remaining cents. Broker fees and their VAT never fund insurer remittances.
-- Receipts are allocated across invoice components pro rata; there is no hidden
-- commission reserve or priority for the lead insurer.
create function public.ins_share_cash_totals(p_share_id uuid) returns jsonb
language sql security definer set search_path=public,pg_temp as $$
 with s as(select * from ins_policy_insurer_shares where id=p_share_id),
 cash as(select coalesce(sum(a.amount),0) as collected from s join fin_open_items i on i.source_id=s.policy_id and i.source_type='ins_policy_premium' and i.tenant_id=s.tenant_id
   join fin_allocations a on a.open_item_id=i.id join fin_settlements f on f.id=a.settlement_id and f.status='posted' and f.direction='in'),
 item as(select i.id,i.amount from s join fin_open_items i on i.source_id=s.id and i.source_type='ins_policy_share_insurer' and i.tenant_id=s.tenant_id),
 paid as(select coalesce(sum(a.amount),0) as amount from item i join fin_allocations a on a.open_item_id=i.id join fin_settlements f on f.id=a.settlement_id and f.status='posted' and f.direction='out'),
 withdrawn as(select coalesce(sum(e.amount),0) as amount from s join ins_commission_entries e on e.insurer_share_id=s.id and e.status='transferred'
   join ins_commission_transfers t on t.id=e.transfer_id and t.status='posted'),
 calc as(select s.*,c.collected,p.amount as remitted,w.amount as withdrawn,
   trunc((s.premium_amount+s.pass_through_amount)*least(c.collected/nullif(sn.invoice_total,0),1),2) as funded,
   coalesce((select outstanding_amount from fin_open_item_balances where id=(select id from item)),0) as outstanding
   from s cross join cash c cross join paid p cross join withdrawn w join ins_policy_financial_snapshots sn on sn.policy_id=s.policy_id)
 select jsonb_build_object('share_id',id,'insurer_id',insurer_id,'share_pct',share_pct,'premium_amount',premium_amount,
  'pass_through_amount',pass_through_amount,'commission_amount',commission_amount,'funded',funded,'remitted',remitted,
  'commission_transferred',withdrawn,'available_allocated_funds',greatest(funded-remitted-withdrawn,0),
  'outstanding',outstanding,'maximum_remittance',least(greatest(funded-remitted-withdrawn,0),greatest(outstanding,0))) from calc;
$$;
revoke all on function public.ins_share_cash_totals(uuid) from public,anon,authenticated;

-- Reuse the old calculation for old policies, preserving their funding rules.
alter function public.ins_policy_cash_totals(uuid) rename to platform_ins_policy_cash_legacy_totals;
revoke all on function public.platform_ins_policy_cash_legacy_totals(uuid) from public,anon,authenticated;
create function public.ins_policy_cash_totals(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare sn ins_policy_financial_snapshots%rowtype; v jsonb; sh jsonb; shares jsonb:='[]'; c numeric; due numeric;
 remitted numeric:=0; withdrawn numeric:=0; available numeric:=0; liability numeric:=0; cap numeric:=0;
begin
 select * into sn from ins_policy_financial_snapshots where policy_id=p_policy_id;
 if sn.policy_id is null or not sn.extended then return platform_ins_policy_cash_legacy_totals(p_policy_id); end if;
 select coalesce(sum(a.amount),0) into c from fin_open_items i join fin_allocations a on a.open_item_id=i.id
  join fin_settlements f on f.id=a.settlement_id and f.status='posted' and f.direction='in'
  where i.source_id=p_policy_id and i.source_type='ins_policy_premium';
 select outstanding_amount into due from fin_open_item_balances where source_id=p_policy_id and source_type='ins_policy_premium';
 for sh in select ins_share_cash_totals(s.id)||jsonb_build_object('insurer_name',i.name,'is_lead',s.is_lead) from ins_policy_insurer_shares s
  join ins_insurers i on i.id=s.insurer_id where s.policy_id=p_policy_id order by s.insurer_id
 loop
  shares:=shares||jsonb_build_array(sh); remitted:=remitted+(sh->>'remitted')::numeric;
  withdrawn:=withdrawn+(sh->>'commission_transferred')::numeric; available:=available+(sh->>'available_allocated_funds')::numeric;
  liability:=liability+(sh->>'outstanding')::numeric; cap:=cap+(sh->>'maximum_remittance')::numeric;
 end loop;
 return jsonb_build_object('collected',c,'remitted',remitted,'commission_transferred',withdrawn,'available_allocated_funds',available,
  'insurer_outstanding',liability,'client_outstanding',coalesce(due,0),'maximum_remittance',cap,'shares',shares,
  'invoice_total',sn.invoice_total,'broker_fee_collected',trunc(sn.broker_fee_total*least(c/sn.invoice_total,1),2),
  'vat_collected',trunc(sn.vat_total*least(c/sn.invoice_total,1),2));
end $$;
revoke all on function public.ins_policy_cash_totals(uuid) from public,anon,authenticated;

-- The legacy private validator is retained for old items and all receipts.
alter function public.ins_policy_cash_validate(uuid,text,uuid,numeric,date) rename to platform_ins_policy_cash_legacy_validate;
revoke all on function public.platform_ins_policy_cash_legacy_validate(uuid,text,uuid,numeric,date) from public,anon,authenticated;
create function public.ins_policy_cash_validate(p_policy_id uuid,p_kind text,p_bank_id uuid,p_amount numeric,p_date date,p_share_id uuid default null)
returns public.fin_open_items language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; b fin_bank_accounts%rowtype; i fin_open_items%rowtype; v jsonb;
begin
 perform ins_policy_cash_require_finance();
 if p_kind is distinct from 'remittance' or not exists(select 1 from ins_policy_financial_snapshots where policy_id=p_policy_id and extended) then
   if p_share_id is not null then raise exception 'INS_SHARE_INPUT: share selection applies only to co-insurance/charge remittances'; end if;
   return platform_ins_policy_cash_legacy_validate(p_policy_id,p_kind,p_bank_id,p_amount,p_date);
 end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>9999999999999999.99 then raise exception 'INS_CASH_INPUT: invalid amount'; end if;
 if p_date is null or p_date>current_date then raise exception 'INS_CASH_DATE: invalid cash date'; end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 if p.status not in('active','renewed') then raise exception 'INS_CASH_STATE: bound, non-reversed policy required'; end if;
 perform f.id from fin_open_items f join ins_policy_cash_items m on m.id=f.id where m.source_id=p.id and f.tenant_id=p.tenant_id
  and m.source_type in('ins_policy_premium','ins_policy_insurer') order by f.id for update of f;
 select * into b from fin_bank_accounts where id=p_bank_id and tenant_id=p.tenant_id for share;
 if not found or b.kind<>'client_money' or not b.is_active or b.gl_account_id is null or b.currency<>p.currency then raise exception 'INS_CASH_BANK: active mapped client-money bank required'; end if;
 if not exists(select 1 from ins_policy_insurer_shares where id=p_share_id and policy_id=p.id and tenant_id=p.tenant_id) then raise exception 'INS_SHARE_INPUT: select a participating insurer'; end if;
 select * into i from fin_open_items where source_id=p_share_id and source_type='ins_policy_share_insurer' and tenant_id=p.tenant_id;
 if not found then raise exception 'INS_CASH_ITEM: insurer payable missing'; end if;
 v:=ins_share_cash_totals(p_share_id);
 if p_amount>(v->>'maximum_remittance')::numeric then raise exception 'INS_CASH_CAP: remittance exceeds this insurer share pro-rata funding or outstanding payable'; end if;
 return i;
end $$;
revoke all on function public.ins_policy_cash_validate(uuid,text,uuid,numeric,date,uuid) from public,anon,authenticated;

create function public.ins_submit_policy_share_cash_request(p_policy_id uuid,p_insurer_share_id uuid,p_bank_account_id uuid,
 p_amount numeric,p_cash_date date,p_request_key uuid,p_reference text default null,p_notes text default null)
returns public.ins_policy_cash_requests language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_policy_cash_requests%rowtype;
begin
 perform ins_policy_cash_require_finance();
 if p_request_key is null then raise exception 'INS_CASH_INPUT: request key required'; end if;
 perform id from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 select * into q from ins_policy_cash_requests where tenant_id=get_my_tenant_id() and request_key=p_request_key;
 if found then
  if q.maker_id<>auth.uid() or q.policy_id<>p_policy_id or q.kind<>'remittance' or q.insurer_share_id is distinct from p_insurer_share_id
   or q.bank_account_id is distinct from p_bank_account_id or q.amount is distinct from p_amount or q.cash_date is distinct from p_cash_date
   or q.reference is distinct from nullif(btrim(p_reference),'') or q.notes is distinct from nullif(btrim(p_notes),'') then raise exception 'INS_CASH_RETRY_CONFLICT: request key already used'; end if;
  return q;
 end if;
 perform ins_policy_cash_validate(p_policy_id,'remittance',p_bank_account_id,p_amount,p_cash_date,p_insurer_share_id);
 insert into ins_policy_cash_requests(tenant_id,policy_id,kind,insurer_share_id,bank_account_id,amount,cash_date,request_key,reference,notes,maker_id)
 values(get_my_tenant_id(),p_policy_id,'remittance',p_insurer_share_id,p_bank_account_id,p_amount,p_cash_date,p_request_key,nullif(btrim(p_reference),''),nullif(btrim(p_notes),''),auth.uid()) returning * into q;
 return q;
end $$;
revoke all on function public.ins_submit_policy_share_cash_request(uuid,uuid,uuid,numeric,date,uuid,text,text) from public,anon;
grant execute on function public.ins_submit_policy_share_cash_request(uuid,uuid,uuid,numeric,date,uuid,text,text) to authenticated;

create or replace function public.ins_policy_cash_allocation_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare m record; s fin_settlements%rowtype; q ins_policy_cash_requests%rowtype;
begin
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

-- A partial receipt may fund the net payable, but not yet this share's commission.
create or replace function public.ins_policy_cash_commission_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
 if new.status='transferred' and old.status<>'transferred' then
  perform id from ins_policies where id=new.policy_id and tenant_id=new.tenant_id for update;
  v:=case when new.insurer_share_id is null then ins_policy_cash_totals(new.policy_id) else ins_share_cash_totals(new.insurer_share_id) end;
  if (v->>'available_allocated_funds')::numeric<new.amount then raise exception 'INS_CASH_COMMISSION_UNFUNDED: this insurer share has insufficient collected commission funds'; end if;
 end if;
 return new;
end $$;

-- Existing control extended through the private policy/share item mapping.
create or replace function public.ins_decide_policy_cash_request(p_request_id uuid,p_decision text,p_reason text default null)
returns public.ins_policy_cash_requests
language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_policy_cash_requests%rowtype; i fin_open_items%rowtype; s fin_settlements%rowtype; pid uuid;
begin
  perform ins_policy_cash_require_finance();
  if p_decision is null or p_decision not in ('approve','reject','cancel') then raise exception 'INS_CASH_INPUT: invalid decision'; end if;
  select policy_id into pid from ins_policy_cash_requests where id=p_request_id and tenant_id=get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: cash request'; end if;
  perform id from ins_policies where id=pid and tenant_id=get_my_tenant_id() for update;
  select * into q from ins_policy_cash_requests where id=p_request_id and tenant_id=get_my_tenant_id() for update;
  if p_decision='cancel' then
    if q.maker_id<>auth.uid() then raise exception 'INS_CASH_MAKER: only the maker can cancel a pending request'; end if;
  elsif q.maker_id=auth.uid() then raise exception 'INS_CASH_SELF_APPROVAL: another Finance user must check the request';
  end if;
  -- A lost response may be retried by the same checker, without reposting.
  if q.status='posted' and p_decision='approve' and q.checker_id=auth.uid() then return q; end if;
  if q.status<>'pending' then raise exception 'INS_CASH_DECIDED: request is no longer pending'; end if;
  if p_decision in ('reject','cancel') then
    if p_reason is null or length(btrim(p_reason))<5 then raise exception 'INS_CASH_REASON: at least five characters are required'; end if;
    update ins_policy_cash_requests set status=case p_decision when 'reject' then 'rejected' else 'cancelled' end,
      checker_id=case when p_decision='reject' then auth.uid() else null end,checked_at=now(),decision_reason=btrim(p_reason)
      where id=q.id returning * into q;
    return q;
  end if;
  i := ins_policy_cash_validate(q.policy_id,q.kind,q.bank_account_id,q.amount,q.cash_date,q.insurer_share_id);
  update ins_policy_cash_requests set status='posting',checker_id=auth.uid(),checked_at=now(),operation_txid=txid_current()
    where id=q.id;
  s := platform_fin_record_settlement_impl(q.tenant_id,q.bank_account_id,
    case q.kind when 'receipt' then 'in' else 'out' end,i.party_account_id,q.amount,q.cash_date,
    jsonb_build_array(jsonb_build_object('open_item_id',i.id,'amount',q.amount)),q.reference,q.notes);
  -- Allocation trigger binds the exact settlement to this approval context.
  update ins_policy_cash_requests set status='posted',operation_txid=null
    where id=q.id and settlement_id=s.id returning * into q;
  if not found then raise exception 'INS_CASH_CONTEXT: approved allocation was not recorded'; end if;
  return q;
end $$;

-- Existing control extended through the private policy/share item mapping.
create or replace function public.ins_policy_cash_void_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare x record; v jsonb;
begin
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

-- Existing control extended through the private policy/share item mapping.
create or replace function public.ins_policy_cash_reconciliation_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare sid uuid; s fin_settlements%rowtype; q ins_policy_cash_requests%rowtype;
begin
  if tg_op='UPDATE' and exists(select 1 from fin_allocations a join ins_policy_cash_items i on i.id=a.open_item_id
    where a.settlement_id in (old.settlement_id,new.settlement_id)
      and i.source_type in ('ins_policy_premium','ins_policy_insurer')) then
    raise exception 'INS_CASH_RECONCILIATION: policy matches are immutable; unmatch and rematch';
  end if;
  sid := case when tg_op='DELETE' then old.settlement_id else new.settlement_id end;
  if sid is null or not exists(select 1 from fin_allocations a join ins_policy_cash_items i on i.id=a.open_item_id
    where a.settlement_id=sid and i.source_type in ('ins_policy_premium','ins_policy_insurer')) then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  perform ins_policy_cash_require_finance();
  select * into s from fin_settlements where id=sid and tenant_id=get_my_tenant_id() for update;
  if not found or s.status<>'posted' then raise exception 'INS_CASH_RECONCILIATION: posted settlement in this company required'; end if;
  select * into q from ins_policy_cash_requests where settlement_id=s.id and tenant_id=s.tenant_id;
  if auth.uid()=s.created_by or auth.uid()=q.maker_id or auth.uid()=q.checker_id then
    raise exception 'INS_CASH_THIRD_PERSON: reconciliation requires a third Finance user, not the maker, checker or poster' using errcode='42501';
  end if;
  if tg_op<>'DELETE' then
    if new.tenant_id<>s.tenant_id or new.matched_by is distinct from auth.uid() then
      raise exception 'INS_CASH_RECONCILIATION: the reconciler must be the acting Finance user';
    end if;
    return new;
  end if;
  return old;
end $$;

-- Existing control extended through the private policy/share item mapping.
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

-- Existing control extended through the private policy/share item mapping.
create or replace function public.ins_policy_cash_reconciliation_audit() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare sid uuid; snapshot jsonb;
begin
  sid := case when tg_op='DELETE' then old.settlement_id else new.settlement_id end;
  if sid is null then return null; end if;
  snapshot := case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  insert into ins_policy_cash_reconciliation_events(tenant_id,policy_id,settlement_id,event,actor_id,reconciliation_snapshot)
    select distinct i.tenant_id,i.source_id,sid,case tg_op when 'DELETE' then 'unmatched' else 'matched' end,auth.uid(),snapshot
    from fin_allocations a join ins_policy_cash_items i on i.id=a.open_item_id and i.tenant_id=a.tenant_id
    where a.settlement_id=sid and i.source_type in ('ins_policy_premium','ins_policy_insurer');
  return null;
end $$;

-- Existing control extended through the private policy/share item mapping.
create or replace function public.ins_policy_cash_position(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; requests jsonb; result jsonb;
begin
  if auth.uid() is null or not (can_access_insurance() or is_finance_team_member('finance')) then
    raise exception 'INS_CASH_FORBIDDEN: Insurance or Finance access required' using errcode='42501';
  end if;
  select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  result := ins_policy_cash_totals(p.id);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'kind',q.kind,'amount',q.amount,'cash_date',q.cash_date,'reference',q.reference,'notes',q.notes,
    'status',case when s.status='void' then 'void' else q.status end,
    'maker_id',q.maker_id,'checker_id',q.checker_id,'created_at',q.created_at,'checked_at',q.checked_at,
    'decision_reason',q.decision_reason,'bank_account_id',q.bank_account_id,'bank_name',b.name,
    'insurer_share_id',q.insurer_share_id,'insurer_name',(select i.name from ins_policy_insurer_shares sh join ins_insurers i on i.id=sh.insurer_id where sh.id=q.insurer_share_id),'settlement_id',q.settlement_id,'settlement_no',s.settlement_no,
    'reconciled',r.id is not null,'reconciled_by',r.matched_by,'reconciled_at',r.matched_at
  ) order by q.created_at desc,q.id), '[]'::jsonb) into requests
  from ins_policy_cash_requests q join fin_bank_accounts b on b.id=q.bank_account_id and b.tenant_id=q.tenant_id
  left join fin_settlements s on s.id=q.settlement_id and s.tenant_id=q.tenant_id
  left join bank_reconciliations r on r.settlement_id=s.id and r.tenant_id=q.tenant_id
  where q.policy_id=p.id and q.tenant_id=p.tenant_id;
  return result || jsonb_build_object('policy_id',p.id,'policy_status',p.status,'currency',p.currency,'requests',requests,
    'commission_amount',p.commission_amount,
    'commission_status',(select case when count(*)=1 then min(e.status) when count(*)>1 then 'per insurer share' else null end from ins_commission_entries e where e.policy_id=p.id and e.tenant_id=p.tenant_id),
    'can_prepare',is_finance_team_member('finance') and effective_user_id()=auth.uid(), 'actor_id',auth.uid());
end $$;

-- Recognize/reverse commission independently for the exact insurer item.
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

-- Recognize/reverse commission independently for the exact insurer item.
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

-- Existing ledger columns retain order/types; the insurer is now the actual
-- participant, not invariably the policy's lead. New details are appended.
create or replace view public.ins_commission_ledger with(security_invoker=true) as
select e.id,e.tenant_id,e.policy_id,p.policy_no,coalesce(s.insurer_id,p.insurer_id) as insurer_id,p.client_id,
 e.amount,e.status,e.earned_on,e.transfer_id,t.transfer_no,t.transfer_date,e.created_at,e.updated_at,
 e.insurer_share_id,coalesce(s.premium_amount,p.gross_premium) as allocated_premium,
 coalesce(s.commission_rate_pct,p.commission_rate_pct) as commission_rate_pct,
 case when e.status in('earned','transferred') then e.amount else 0 end as earned_commission,
 case when e.status='transferred' then 0 else e.amount end as untransferred_commission
from ins_commission_entries e join ins_policies p on p.id=e.policy_id
left join ins_policy_insurer_shares s on s.id=e.insurer_share_id and s.tenant_id=e.tenant_id
left join ins_commission_transfers t on t.id=e.transfer_id where p.status<>'reversed';

-- Narrow report reads protect Finance/Insurance visibility without opening the
-- underlying client master or generic Finance allocation tables to new roles.
create function public.ins_policy_financial_details(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; v jsonb;
begin
 if not(can_access_insurance() or is_finance_team_member('finance')) or auth.uid() is null then raise exception 'INS_FORBIDDEN: Insurance or Finance access required' using errcode='42501'; end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 select jsonb_build_object('policy_id',p.id,'policy_no',p.policy_no,'status',p.status,'currency',p.currency,'gross_premium',p.gross_premium,
  'shares',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('insurer_name',i.name) order by s.insurer_id) from ins_policy_insurer_shares s join ins_insurers i on i.id=s.insurer_id where s.policy_id=p.id),'[]'::jsonb),
  'charges',coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from ins_policy_charges c where c.policy_id=p.id),'[]'::jsonb),
  'snapshot',(select to_jsonb(sn) from ins_policy_financial_snapshots sn where sn.policy_id=p.id),
  'can_configure',can_manage_insurance() and effective_user_id()=auth.uid(),
  'client_name',(select b.name from ins_clients c join bd_clients b on b.id=c.client_id where c.id=p.client_id)) into v;
 return v;
end $$;
revoke all on function public.ins_policy_financial_details(uuid) from public,anon;
grant execute on function public.ins_policy_financial_details(uuid) to authenticated;

-- Policy-shaped statement rows preserve the existing statement arithmetic while
-- projecting each selected insurer's allocated premium, rate and payable.
create function public.ins_insurer_commission_statement_data(p_insurer_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare policies jsonb; ledger jsonb;
begin
 if not can_access_insurance() then raise exception 'INS_FORBIDDEN: Insurance access required' using errcode='42501'; end if;
 if not exists(select 1 from ins_insurers where id=p_insurer_id and tenant_id=get_my_tenant_id()) then raise exception 'INS_NOT_FOUND: insurer'; end if;
 select coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('gross_premium',coalesce(s.premium_amount,p.gross_premium),
  'commission_rate_pct',coalesce(s.commission_rate_pct,p.commission_rate_pct),'commission_amount',coalesce(s.commission_amount,p.commission_amount),
  'net_premium_to_insurer',coalesce(s.payable_amount,p.net_premium_to_insurer),'insurer_id',p_insurer_id,
  'ins_clients',jsonb_build_object('bd_clients',jsonb_build_object('name',b.name)))),'[]'::jsonb) into policies
 from ins_policies p left join ins_policy_insurer_shares s on s.policy_id=p.id and s.insurer_id=p_insurer_id
  and exists(select 1 from ins_policy_financial_snapshots sn where sn.policy_id=p.id and sn.extended)
 join ins_clients c on c.id=p.client_id join bd_clients b on b.id=c.client_id
 where p.tenant_id=get_my_tenant_id() and p.status<>'draft' and (s.id is not null or
  (p.insurer_id=p_insurer_id and not exists(select 1 from ins_policy_financial_snapshots sn where sn.policy_id=p.id and sn.extended)));
 select coalesce(jsonb_agg(to_jsonb(l)),'[]'::jsonb) into ledger from ins_commission_ledger l where tenant_id=get_my_tenant_id() and insurer_id=p_insurer_id;
 return jsonb_build_object('policies',policies,'ledger',ledger);
end $$;
revoke all on function public.ins_insurer_commission_statement_data(uuid) from public,anon;
grant execute on function public.ins_insurer_commission_statement_data(uuid) to authenticated;

-- Insurance fee VAT is explicit, accrual-based on bind date and independent of
-- settlement collection. 'not_calculated' is NOT represented as VAT exempt.
create view public.ins_broker_fee_tax_report with(security_invoker=true) as
select c.id as charge_id,c.tenant_id,c.policy_id,p.policy_no,p.currency,p.inception_date as invoice_date,
 c.description,c.amount as fee_amount,c.vat_mode,c.vat_rate_pct,coalesce(c.vat_amount,0) as vat_amount,
 c.amount+coalesce(c.vat_amount,0) as invoice_line_total,sn.journal_entry_id
from ins_policy_charges c join ins_policies p on p.id=c.policy_id and p.tenant_id=c.tenant_id
join ins_policy_financial_snapshots sn on sn.policy_id=p.id and sn.extended
where c.kind='broker_fee';
revoke all on public.ins_broker_fee_tax_report from public,anon,authenticated;
grant select on public.ins_broker_fee_tax_report to authenticated;

select public.apply_tenant_read_only_guard();

-- Narrow account picker; no general Finance access is granted to Insurance staff.
create function public.ins_policy_charge_income_accounts() returns table(id uuid,account_code text,name text)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode='42501'; end if;
 return query select g.id,g.account_code,g.name from gl_accounts g where tenant_id=get_my_tenant_id() and account_type='revenue' and is_active order by g.account_code;
end $$;
revoke all on function public.ins_policy_charge_income_accounts() from public,anon;
grant execute on function public.ins_policy_charge_income_accounts() to authenticated;

create function public.ins_broker_fee_tax_rows(p_date_from date default null,p_date_to date default null)
returns setof public.ins_broker_fee_tax_report
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform ins_policy_cash_require_finance();
 if p_date_from is not null and p_date_to is not null and p_date_from>p_date_to then raise exception 'INS_REPORT_PERIOD: invalid period'; end if;
 return query select r.* from ins_broker_fee_tax_report r where r.tenant_id=get_my_tenant_id()
  and(p_date_from is null or r.invoice_date>=p_date_from) and(p_date_to is null or r.invoice_date<=p_date_to) order by r.invoice_date,r.policy_no,r.charge_id;
end $$;
revoke all on function public.ins_broker_fee_tax_rows(date,date) from public,anon;
grant execute on function public.ins_broker_fee_tax_rows(date,date) to authenticated;

-- Generic credit applications must not become an undocumented cancellation path
-- for complex policies. Legacy single-insurer credit behavior is untouched.
create function public.ins_complex_policy_credit_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if exists(select 1 from ins_policy_cash_items m join ins_policy_financial_snapshots sn on sn.policy_id=m.source_id and sn.tenant_id=m.tenant_id and sn.extended
   where m.id=new.open_item_id and m.tenant_id=new.tenant_id and m.source_type in('ins_policy_premium','ins_policy_insurer')) then
   raise exception 'INS_CANCELLATION_REQUIRED: co-insurance or charge-bearing policy credits require the future cancellation workflow';
 end if;
 return new;
end $$;
revoke all on function public.ins_complex_policy_credit_guard() from public,anon,authenticated;
create trigger ins_complex_policy_credit_guard before insert on public.fin_credit_applications
 for each row execute function public.ins_complex_policy_credit_guard();

-- Finance can find a policy by any participating insurer, not only its lead.
create or replace function public.ins_policy_cash_policies(p_search text default '',p_offset integer default 0)
returns table(id uuid,policy_no text,status text,currency text,client_name text,insurer_name text)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform ins_policy_cash_require_finance();
  if p_offset is null or p_offset<0 then raise exception 'INS_CASH_INPUT: invalid page'; end if;
  return query select p.id,p.policy_no,p.status,p.currency,c.name,i.name
    from ins_policies p join ins_clients ic on ic.id=p.client_id and ic.tenant_id=p.tenant_id
    join bd_clients c on c.id=ic.client_id and c.tenant_id=ic.tenant_id
    join ins_insurers i on i.id=p.insurer_id and i.tenant_id=p.tenant_id
    where p.tenant_id=get_my_tenant_id() and p.status<>'draft'
      and (p.policy_no ilike '%'||coalesce(p_search,'')||'%' or c.name ilike '%'||coalesce(p_search,'')||'%'
           or i.name ilike '%'||coalesce(p_search,'')||'%'
           or exists(select 1 from ins_policy_insurer_shares sh join ins_insurers co on co.id=sh.insurer_id and co.tenant_id=sh.tenant_id
              where sh.policy_id=p.id and co.name ilike '%'||coalesce(p_search,'')||'%'))
    order by p.created_at desc,p.id limit 50 offset p_offset;
end $$;
