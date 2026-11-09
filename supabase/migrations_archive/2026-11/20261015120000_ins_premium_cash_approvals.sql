-- Policy cash uses the existing Finance settlements, allocations and journals.
-- Requests are approval/audit evidence, NOT a second cash ledger.
-- All policy allocations require an exact, transaction-bound approval context.

create table public.ins_policy_cash_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  policy_id uuid not null,
  kind text not null check (kind in ('receipt','remittance')),
  bank_account_id uuid not null,
  amount numeric(18,2) not null check (amount > 0),
  cash_date date not null,
  reference text,
  notes text,
  request_key uuid not null,
  status text not null default 'pending' check (status in ('pending','posting','posted','rejected','cancelled')),
  maker_id uuid not null,
  created_at timestamptz not null default now(),
  checker_id uuid,
  checked_at timestamptz,
  decision_reason text,
  settlement_id uuid unique,
  operation_txid bigint,
  unique (tenant_id, request_key),
  foreign key (tenant_id, policy_id) references public.ins_policies(tenant_id,id),
  foreign key (tenant_id, bank_account_id) references public.fin_bank_accounts(tenant_id,id),
  foreign key (tenant_id, settlement_id) references public.fin_settlements(tenant_id,id),
  check (checker_id is null or checker_id <> maker_id),
  check (
    (status='pending' and checker_id is null and checked_at is null and settlement_id is null and operation_txid is null)
    or (status='posting' and checker_id is not null and checked_at is not null and operation_txid is not null)
    or (status='posted' and checker_id is not null and checked_at is not null and settlement_id is not null and operation_txid is null)
    or (status='rejected' and checker_id is not null and checked_at is not null and settlement_id is null and operation_txid is null and length(btrim(decision_reason)) >= 5)
    or (status='cancelled' and checker_id is null and checked_at is not null and settlement_id is null and operation_txid is null and length(btrim(decision_reason)) >= 5)
  )
);
create index ins_policy_cash_requests_policy_idx on public.ins_policy_cash_requests(tenant_id,policy_id,created_at);
create index ins_policy_cash_requests_bank_idx on public.ins_policy_cash_requests(bank_account_id);
alter table public.ins_policy_cash_requests enable row level security;
revoke all on public.ins_policy_cash_requests from public, anon, authenticated;
grant select on public.ins_policy_cash_requests to authenticated;
create policy ins_policy_cash_requests_select on public.ins_policy_cash_requests for select to authenticated
  using (tenant_id=get_my_tenant_id() and (can_access_insurance() or is_finance_team_member('finance')));

-- No impersonation and no insurance-manager fallback for cash authority.
create function public.ins_policy_cash_require_finance() returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null or effective_user_id() is distinct from auth.uid()
     or not is_finance_team_member('finance') then
    raise exception 'INS_CASH_FORBIDDEN: an authorized Finance user, acting as themselves, is required' using errcode='42501';
  end if;
end $$;
revoke all on function public.ins_policy_cash_require_finance() from public, anon, authenticated;

-- Private calculation. The caller takes the policy lock before any money change.
-- Credit notes are allocations, but are not cash: count posted settlements only.
create function public.ins_policy_cash_totals(p_policy_id uuid) returns jsonb
language sql security definer set search_path=public,pg_temp as $$
  with money as (
    select coalesce(sum(a.amount) filter (where i.source_type='ins_policy_premium' and s.direction='in'),0) as collected,
           coalesce(sum(a.amount) filter (where i.source_type='ins_policy_insurer' and s.direction='out'),0) as remitted
    from fin_open_items i join fin_allocations a on a.open_item_id=i.id and a.tenant_id=i.tenant_id
    join fin_settlements s on s.id=a.settlement_id and s.tenant_id=a.tenant_id and s.status='posted'
    where i.source_id=p_policy_id and i.source_type in ('ins_policy_premium','ins_policy_insurer')
  ), transferred as (
    select coalesce(sum(e.amount),0) as amount from ins_commission_entries e
    join ins_commission_transfers t on t.id=e.transfer_id and t.tenant_id=e.tenant_id and t.status='posted'
    where e.policy_id=p_policy_id and e.status='transferred'
  ), outstanding as (
    select coalesce(sum(b.outstanding_amount) filter (where b.source_type='ins_policy_premium'),0) as client_due,
           coalesce(sum(b.outstanding_amount) filter (where b.source_type='ins_policy_insurer'),0) as insurer_due
    from fin_open_item_balances b where b.source_id=p_policy_id
      and b.source_type in ('ins_policy_premium','ins_policy_insurer')
  )
  select jsonb_build_object('collected',m.collected,'remitted',m.remitted,'commission_transferred',t.amount,
    'available_allocated_funds',greatest(m.collected-m.remitted-t.amount,0),
    'client_outstanding',greatest(o.client_due,0),'insurer_outstanding',greatest(o.insurer_due,0),
    'maximum_remittance',least(greatest(m.collected-m.remitted-t.amount,0),greatest(o.insurer_due,0)))
  from money m cross join transferred t cross join outstanding o;
$$;
revoke all on function public.ins_policy_cash_totals(uuid) from public, anon, authenticated;

-- Read-only projection for Insurance and Finance. No general Finance table grants
-- are added for Insurance users. The actual bank matcher remains in Finance.
create function public.ins_policy_cash_position(p_policy_id uuid) returns jsonb
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
    'settlement_id',q.settlement_id,'settlement_no',s.settlement_no,
    'reconciled',r.id is not null,'reconciled_by',r.matched_by,'reconciled_at',r.matched_at
  ) order by q.created_at desc,q.id), '[]'::jsonb) into requests
  from ins_policy_cash_requests q join fin_bank_accounts b on b.id=q.bank_account_id and b.tenant_id=q.tenant_id
  left join fin_settlements s on s.id=q.settlement_id and s.tenant_id=q.tenant_id
  left join bank_reconciliations r on r.settlement_id=s.id and r.tenant_id=q.tenant_id
  where q.policy_id=p.id and q.tenant_id=p.tenant_id;
  return result || jsonb_build_object('policy_id',p.id,'policy_status',p.status,'currency',p.currency,'requests',requests,
    'commission_amount',p.commission_amount,
    'commission_status',(select e.status from ins_commission_entries e where e.policy_id=p.id and e.tenant_id=p.tenant_id),
    'can_prepare',is_finance_team_member('finance') and effective_user_id()=auth.uid(), 'actor_id',auth.uid());
end $$;

create function public.ins_policy_cash_bank_accounts() returns setof public.fin_bank_accounts
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform ins_policy_cash_require_finance();
  return query select b.* from fin_bank_accounts b where b.tenant_id=get_my_tenant_id()
    and b.kind='client_money' and b.is_active and b.gl_account_id is not null
    and b.currency=fin_ledger_currency(b.tenant_id) order by b.name;
end $$;

-- Private validation is repeated at approval (pending requests reserve no cash).
create function public.ins_policy_cash_validate(p_policy_id uuid,p_kind text,p_bank_id uuid,p_amount numeric,p_date date)
returns public.fin_open_items language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; b fin_bank_accounts%rowtype; i fin_open_items%rowtype; v jsonb; cap numeric;
begin
  perform ins_policy_cash_require_finance();
  if p_kind is null or p_kind not in ('receipt','remittance') or p_amount is null or p_amount<=0
     or p_amount<>round(p_amount,2) or p_amount>9999999999999999.99 then
    raise exception 'INS_CASH_INPUT: choose receipt/remittance and a positive amount with at most two decimals';
  end if;
  if p_date is null or p_date>current_date then raise exception 'INS_CASH_DATE: cash date must not be in the future'; end if;
  select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status not in ('active','renewed') then raise exception 'INS_CASH_STATE: only bound, non-reversed policies accept cash'; end if;
  -- Same policy/item lock order as reversal. Serializes receipts, remittances,
  -- voids and commission withdrawals for this policy across different banks.
  perform id from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type in ('ins_policy_premium','ins_policy_insurer') order by id for update;
  select * into b from fin_bank_accounts where id=p_bank_id and tenant_id=p.tenant_id for share;
  if not found or b.kind<>'client_money' or not b.is_active or b.gl_account_id is null or b.currency<>p.currency then
    raise exception 'INS_CASH_BANK: an active mapped client-money bank in the policy currency is required';
  end if;
  select * into i from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type=case p_kind when 'receipt' then 'ins_policy_premium' else 'ins_policy_insurer' end;
  if not found then raise exception 'INS_CASH_ITEM: policy open item missing'; end if;
  v := ins_policy_cash_totals(p.id);
  cap := case p_kind when 'receipt' then (v->>'client_outstanding')::numeric else (v->>'maximum_remittance')::numeric end;
  if p_amount>cap then
    raise exception 'INS_CASH_CAP: requested % exceeds available %; remittances are capped by allocated collections and outstanding insurer liability',p_amount,cap;
  end if;
  return i;
end $$;
revoke all on function public.ins_policy_cash_validate(uuid,text,uuid,numeric,date) from public, anon, authenticated;

create function public.ins_submit_policy_cash_request(
  p_policy_id uuid,p_kind text,p_bank_account_id uuid,p_amount numeric,p_cash_date date,p_request_key uuid,
  p_reference text default null,p_notes text default null
) returns public.ins_policy_cash_requests
language plpgsql security definer set search_path=public,pg_temp as $$
declare q ins_policy_cash_requests%rowtype;
begin
  perform ins_policy_cash_require_finance();
  if p_request_key is null then raise exception 'INS_CASH_INPUT: request key required'; end if;
  -- The policy lock also serializes equal retry keys for this policy.
  perform id from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  select * into q from ins_policy_cash_requests where tenant_id=get_my_tenant_id() and request_key=p_request_key;
  if found then
    if q.maker_id<>auth.uid() or q.policy_id<>p_policy_id or q.kind is distinct from p_kind
       or q.bank_account_id is distinct from p_bank_account_id or q.amount is distinct from p_amount
       or q.cash_date is distinct from p_cash_date or q.reference is distinct from nullif(btrim(p_reference),'')
       or q.notes is distinct from nullif(btrim(p_notes),'') then
      raise exception 'INS_CASH_RETRY_CONFLICT: request key already used with a different payload';
    end if;
    return q;
  end if;
  perform ins_policy_cash_validate(p_policy_id,p_kind,p_bank_account_id,p_amount,p_cash_date);
  insert into ins_policy_cash_requests(tenant_id,policy_id,kind,bank_account_id,amount,cash_date,request_key,reference,notes,maker_id)
  values(get_my_tenant_id(),p_policy_id,p_kind,p_bank_account_id,p_amount,p_cash_date,p_request_key,
    nullif(btrim(p_reference),''),nullif(btrim(p_notes),''),auth.uid()) returning * into q;
  return q;
end $$;

create function public.ins_decide_policy_cash_request(p_request_id uuid,p_decision text,p_reason text default null)
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
  i := ins_policy_cash_validate(q.policy_id,q.kind,q.bank_account_id,q.amount,q.cash_date);
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

-- The generic Finance RPC (and any alternate allocation writer) cannot bypass
-- maker/checker. No client-settable GUC grants this exemption.
create function public.ins_policy_cash_allocation_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare i fin_open_items%rowtype; s fin_settlements%rowtype; q ins_policy_cash_requests%rowtype;
begin
  select * into i from fin_open_items where id=new.open_item_id and tenant_id=new.tenant_id;
  if i.source_type not in ('ins_policy_premium','ins_policy_insurer') then return new; end if;
  perform ins_policy_cash_require_finance();
  select * into s from fin_settlements where id=new.settlement_id and tenant_id=new.tenant_id;
  select * into q from ins_policy_cash_requests where tenant_id=new.tenant_id and policy_id=i.source_id
    and status='posting' and operation_txid=txid_current() and checker_id=auth.uid()
    and maker_id<>auth.uid() and bank_account_id=s.bank_account_id and amount=new.amount
    and amount=s.amount and cash_date=s.settlement_date
    and kind=case i.source_type when 'ins_policy_premium' then 'receipt' else 'remittance' end
    and (settlement_id is null or settlement_id=s.id) for update;
  if q.id is null or s.direction<>(case q.kind when 'receipt' then 'in' else 'out' end)
     or s.party_account_id<>i.party_account_id or exists(select 1 from fin_allocations where settlement_id=s.id) then
    raise exception 'INS_CASH_APPROVAL_REQUIRED: use the policy cash request and independent Finance approval workflow';
  end if;
  perform ins_policy_cash_validate(q.policy_id,q.kind,q.bank_account_id,q.amount,q.cash_date);
  update ins_policy_cash_requests set settlement_id=s.id where id=q.id;
  return new;
end $$;
revoke all on function public.ins_policy_cash_allocation_guard() from public, anon, authenticated;
create trigger trg_ins_policy_cash_allocation before insert on public.fin_allocations
  for each row execute function public.ins_policy_cash_allocation_guard();

-- Generic Finance voids must not remove receipts already funding insurer
-- remittances or commission withdrawals. Voiding a remittance still uses the
-- existing commission reversal and reconciliation protections.
create function public.ins_policy_cash_void_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare x record; v jsonb;
begin
  if old.status<>'posted' or new.status<>'void' then return new; end if;
  for x in select i.source_id as policy_id,sum(a.amount) as removed
    from fin_allocations a join fin_open_items i on i.id=a.open_item_id and i.tenant_id=a.tenant_id
    where a.settlement_id=old.id and i.source_type='ins_policy_premium'
    group by i.source_id order by i.source_id
  loop
    perform id from ins_policies where id=x.policy_id and tenant_id=old.tenant_id for update;
    v := ins_policy_cash_totals(x.policy_id);
    if (v->>'collected')::numeric-x.removed < (v->>'remitted')::numeric+(v->>'commission_transferred')::numeric then
      raise exception 'INS_CASH_FUNDS_IN_USE: reverse the funded remittances/commission transfers before voiding this receipt';
    end if;
  end loop;
  -- Outgoing voids also serialize with concurrent approvals and receipt voids.
  perform p.id from ins_policies p join fin_open_items i on i.source_id=p.id and i.tenant_id=p.tenant_id
    join fin_allocations a on a.open_item_id=i.id and a.tenant_id=i.tenant_id
    where a.settlement_id=old.id and i.source_type='ins_policy_insurer' order by p.id for update of p;
  return new;
end $$;
revoke all on function public.ins_policy_cash_void_guard() from public, anon, authenticated;
create trigger trg_ins_policy_cash_void before update of status on public.fin_settlements
  for each row execute function public.ins_policy_cash_void_guard();

-- Partial premium receipts may fund the whole net insurer liability without
-- funding commission yet. Preserve recognition rules, but never withdraw another
-- policy's collections as this policy's commission. Existing transfer controls
-- (earned status, banks, GL balance, date, reconciliation) remain in force.
create function public.ins_policy_cash_commission_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
  if new.status='transferred' and old.status<>'transferred' then
    perform id from ins_policies where id=new.policy_id and tenant_id=new.tenant_id for update;
    v := ins_policy_cash_totals(new.policy_id);
    if (v->>'available_allocated_funds')::numeric<new.amount then
      raise exception 'INS_CASH_COMMISSION_UNFUNDED: this policy has insufficient collected funds for its commission withdrawal';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.ins_policy_cash_commission_guard() from public, anon, authenticated;
create trigger trg_ins_policy_cash_commission before update of status on public.ins_commission_entries
  for each row execute function public.ins_policy_cash_commission_guard();

-- Trigger is the backstop for manual, auto and alternate matching paths, and
-- for unmatching. Old generic policy settlements are covered too: their creator
-- is the only historical actor available; do not invent missing approval data.
create function public.ins_policy_cash_reconciliation_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare sid uuid; s fin_settlements%rowtype; q ins_policy_cash_requests%rowtype;
begin
  if tg_op='UPDATE' and exists(select 1 from fin_allocations a join fin_open_items i on i.id=a.open_item_id
    where a.settlement_id in (old.settlement_id,new.settlement_id)
      and i.source_type in ('ins_policy_premium','ins_policy_insurer')) then
    raise exception 'INS_CASH_RECONCILIATION: policy matches are immutable; unmatch and rematch';
  end if;
  sid := case when tg_op='DELETE' then old.settlement_id else new.settlement_id end;
  if sid is null or not exists(select 1 from fin_allocations a join fin_open_items i on i.id=a.open_item_id
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
revoke all on function public.ins_policy_cash_reconciliation_guard() from public, anon, authenticated;
create trigger trg_ins_policy_cash_reconciliation before insert or update or delete on public.bank_reconciliations
  for each row execute function public.ins_policy_cash_reconciliation_guard();

-- Auto-match skips ineligible policy candidates without filtering them out of
-- the ambiguity count (otherwise a conflicting cash-bank duplicate could win).
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
    if src='settlement' and exists(select 1 from fin_allocations a join fin_open_items i on i.id=a.open_item_id
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

revoke all on function public.ins_policy_cash_position(uuid) from public,anon;
revoke all on function public.ins_policy_cash_bank_accounts() from public,anon;
revoke all on function public.ins_submit_policy_cash_request(uuid,text,uuid,numeric,date,uuid,text,text) from public,anon;
revoke all on function public.ins_decide_policy_cash_request(uuid,text,text) from public,anon;
grant execute on function public.ins_policy_cash_position(uuid) to authenticated;
grant execute on function public.ins_policy_cash_bank_accounts() to authenticated;
grant execute on function public.ins_submit_policy_cash_request(uuid,text,uuid,numeric,date,uuid,text,text) to authenticated;
grant execute on function public.ins_decide_policy_cash_request(uuid,text,text) to authenticated;

-- Narrow, paged policy lookup for Finance users without Insurance membership.
create function public.ins_policy_cash_policies(p_search text default '',p_offset integer default 0)
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
           or i.name ilike '%'||coalesce(p_search,'')||'%')
    order by p.created_at desc,p.id limit 50 offset p_offset;
end $$;
revoke all on function public.ins_policy_cash_policies(text,integer) from public,anon;
grant execute on function public.ins_policy_cash_policies(text,integer) to authenticated;

-- Append-only match/unmatch evidence survives deletion of a live match row.
create table public.ins_policy_cash_reconciliation_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  policy_id uuid not null,
  settlement_id uuid not null,
  event text not null check (event in ('matched','unmatched')),
  actor_id uuid not null,
  occurred_at timestamptz not null default now(),
  reconciliation_snapshot jsonb not null,
  foreign key (tenant_id,policy_id) references public.ins_policies(tenant_id,id),
  foreign key (tenant_id,settlement_id) references public.fin_settlements(tenant_id,id)
);
create index ins_policy_cash_reconciliation_events_policy_idx
  on public.ins_policy_cash_reconciliation_events(tenant_id,policy_id,occurred_at);
create index ins_policy_cash_reconciliation_events_settlement_idx
  on public.ins_policy_cash_reconciliation_events(settlement_id);
alter table public.ins_policy_cash_reconciliation_events enable row level security;
revoke all on public.ins_policy_cash_reconciliation_events from public,anon,authenticated;
grant select on public.ins_policy_cash_reconciliation_events to authenticated;
create policy ins_policy_cash_reconciliation_events_select on public.ins_policy_cash_reconciliation_events for select to authenticated
  using (tenant_id=get_my_tenant_id() and (can_access_insurance() or is_finance_team_member('finance')));
create function public.ins_policy_cash_reconciliation_audit() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare sid uuid; snapshot jsonb;
begin
  sid := case when tg_op='DELETE' then old.settlement_id else new.settlement_id end;
  if sid is null then return null; end if;
  snapshot := case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  insert into ins_policy_cash_reconciliation_events(tenant_id,policy_id,settlement_id,event,actor_id,reconciliation_snapshot)
    select distinct i.tenant_id,i.source_id,sid,case tg_op when 'DELETE' then 'unmatched' else 'matched' end,auth.uid(),snapshot
    from fin_allocations a join fin_open_items i on i.id=a.open_item_id and i.tenant_id=a.tenant_id
    where a.settlement_id=sid and i.source_type in ('ins_policy_premium','ins_policy_insurer');
  return null;
end $$;
revoke all on function public.ins_policy_cash_reconciliation_audit() from public,anon,authenticated;
create trigger trg_ins_policy_cash_reconciliation_audit after insert or delete on public.bank_reconciliations
  for each row execute function public.ins_policy_cash_reconciliation_audit();

-- New tenant tables participate in the platform-wide financial write freeze.
select public.apply_tenant_read_only_guard();
