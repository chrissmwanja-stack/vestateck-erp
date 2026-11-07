-- =====================================================================
-- In-force import, step 3: opening position.
--
-- After ins_import_commit_policies creates the policies, this posts the
-- opening position per batch and currency:
--   Dr  ar_control open item per policy (full billed premium, carrying
--       the inception date so ageing works)
--   Cr  insurer_payable open item per policy share (net premium)
--   Cr  unearned commission per policy (Option A: one deferred
--       ins_commission_entries row for the unearned remainder; policies
--       whose insurer net is already fully remitted at cut-over carry no
--       deferred entry — their commission is in the opening result)
--   balancing line to the opening_balance_clearing account, which must
--   net to zero.
-- Receipts and remittances are stored as HISTORY ONLY (never posted —
-- their cash is already in the opening bank balances) and reconciled
-- against the batch control totals.
-- =====================================================================

alter table public.ins_import_batches
  add column if not exists control_totals jsonb not null default '[]'::jsonb;

create table if not exists public.ins_import_receipts (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  batch_id     uuid not null references public.ins_import_batches(id) on delete cascade,
  policy_id    uuid not null,
  receipt_date date not null,
  reference    text,
  amount       numeric(18,2) not null check (amount > 0),
  created_at   timestamptz not null default now(),
  constraint ins_import_receipts_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete cascade
);

create table if not exists public.ins_import_remittances (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  batch_id   uuid not null references public.ins_import_batches(id) on delete cascade,
  policy_id  uuid not null,
  remit_date date not null,
  reference  text,
  amount     numeric(18,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  constraint ins_import_remittances_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete cascade
);

create index if not exists ins_import_receipts_batch_idx on public.ins_import_receipts (tenant_id, batch_id);
create index if not exists ins_import_remittances_batch_idx on public.ins_import_remittances (tenant_id, batch_id);

alter table public.ins_import_receipts enable row level security;
alter table public.ins_import_remittances enable row level security;
create policy "ins_import_receipts_select" on public.ins_import_receipts
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());
create policy "ins_import_remittances_select" on public.ins_import_remittances
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());
revoke all on public.ins_import_receipts, public.ins_import_remittances from public, anon;

-- Post the opening position for a committed batch. Idempotent: a batch
-- with an opening journal is skipped.
create or replace function public.ins_import_post_opening_position(p_batch_id uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  b public.ins_import_batches;
  pol record;
  v_je journal_entries;
  v_lines jsonb := '[]'::jsonb;
  v_desc text;
  v_ar_gl uuid; v_pay_gl uuid; v_unearned_gl uuid; v_clearing_gl uuid;
  v_ar_acc uuid; v_ins_acc uuid;
  v_comm numeric; v_net numeric;
  v_total_ar numeric := 0; v_total_pay numeric := 0; v_total_unearned numeric := 0;
  v_posted boolean := false;
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
  if exists (select 1 from public.ins_import_receipts where batch_id = p_batch_id)
     or exists (select 1 from public.journal_entries
                 where tenant_id = v_tenant and source_type = 'ins_import_opening'
                   and source_id = p_batch_id) then
    return jsonb_build_object('already_posted', true, 'batch_id', p_batch_id);
  end if;

  v_ar_gl       := public.get_posting_account(v_tenant, 'ar_control');
  v_pay_gl      := public.get_posting_account(v_tenant, 'insurer_payable');
  v_unearned_gl := public.get_posting_account(v_tenant, 'unearned_commission');
  v_clearing_gl := public.get_posting_account(v_tenant, 'opening_balance_clearing');
  if v_ar_gl is null or v_pay_gl is null or v_unearned_gl is null or v_clearing_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: chart needs ar_control, insurer_payable, unearned_commission, opening_balance_clearing';
  end if;

  set local ins.via_rpc = 'on';

  for pol in
    select p.id, p.policy_no, p.inception_date, p.gross_premium, p.currency,
           p.commission_amount, p.client_id, p.insurer_id
    from public.ins_policies p
    where p.tenant_id = v_tenant and p.import_batch_id = p_batch_id
    order by p.policy_no
  loop
    v_comm := coalesce(pol.commission_amount, 0);
    v_net  := pol.gross_premium - v_comm;

    v_ar_acc  := public.ins_ensure_client_account(pol.client_id);
    v_ins_acc := public.ins_ensure_insurer_account(pol.insurer_id);

    v_desc := 'Opening position (import ' || left(p_batch_id::text, 8) || '): ' || pol.policy_no;

    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ar_gl, 'debit', pol.gross_premium, 'currency', pol.currency, 'description', v_desc));
    v_total_ar := v_total_ar + pol.gross_premium;

    perform public.fin_create_open_item_fx(
      v_tenant, v_ar_acc, 'ar_control', 'ins_policy_premium', pol.id,
      pol.policy_no, pol.inception_date, b.cut_over_date, pol.gross_premium,
      'Opening receivable: ' || pol.policy_no, pol.currency, null);

    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_pay_gl, 'credit', v_net, 'currency', pol.currency, 'description', v_desc));
    v_total_pay := v_total_pay + v_net;

    perform public.fin_create_open_item_fx(
      v_tenant, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', pol.id,
      pol.policy_no, pol.inception_date, b.cut_over_date, v_net,
      'Opening payable: ' || pol.policy_no, pol.currency, null);

    if v_comm > 0 then
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object('gl_account_id', v_unearned_gl, 'credit', v_comm, 'currency', pol.currency,
                           'description', v_desc || ' - unearned commission'));
      v_total_unearned := v_total_unearned + v_comm;
      insert into public.ins_commission_entries (tenant_id, policy_id, amount, status)
      values (v_tenant, pol.id, v_comm, 'deferred');
    end if;
  end loop;

  -- balancing line to opening_balance_clearing (plug must net the batch to zero)
  v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('gl_account_id', v_clearing_gl,
      'debit', greatest(v_total_pay + v_total_unearned - v_total_ar, 0),
      'credit', greatest(v_total_ar - v_total_pay - v_total_unearned, 0),
      'currency', (select distinct currency from public.ins_policies where tenant_id = v_tenant and import_batch_id = p_batch_id),
      'description', 'Opening balance clearing (import ' || left(p_batch_id::text, 8) || ')'));

  v_je := public.post_journal_entry(v_tenant, 'ins_import_opening', p_batch_id, b.cut_over_date,
    'Opening position for import batch ' || left(p_batch_id::text, 8), v_lines);
  v_posted := true;
  reset ins.via_rpc;

  return jsonb_build_object(
    'already_posted', false, 'batch_id', p_batch_id, 'journal_entry_id', v_je.id,
    'ar_total', v_total_ar, 'payable_total', v_total_pay, 'unearned_total', v_total_unearned);
end $$;

-- Store staged receipts/remittances as history (never posted).
create or replace function public.ins_import_record_history(
  p_batch_id uuid, p_receipts jsonb, p_remittances jsonb
)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  r jsonb; n integer := 0;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ins_import_batches where id = p_batch_id and tenant_id = v_tenant) then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;
  set local ins.via_rpc = 'on';
  for r in select * from jsonb_array_elements(coalesce(p_receipts, '[]'::jsonb)) loop
    insert into public.ins_import_receipts (tenant_id, batch_id, policy_id, receipt_date, reference, amount)
    values (v_tenant, p_batch_id, (r->>'policy_id')::uuid, (r->>'receipt_date')::date,
            r->>'reference', (r->>'amount')::numeric);
    n := n + 1;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_remittances, '[]'::jsonb)) loop
    insert into public.ins_import_remittances (tenant_id, batch_id, policy_id, remit_date, reference, amount)
    values (v_tenant, p_batch_id, (r->>'policy_id')::uuid, (r->>'remit_date')::date,
            r->>'reference', (r->>'amount')::numeric);
    n := n + 1;
  end loop;
  reset ins.via_rpc;
  return jsonb_build_object('recorded', n);
end $$;

-- Reconciliation: staged/imported totals vs the batch control totals.
create or replace function public.ins_import_reconciliation(p_batch_id uuid)
returns table (currency text, measure text, imported_amount numeric, control_amount numeric, match boolean)
language plpgsql stable security definer set search_path = pg_catalog, public
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ins_import_batches where id = p_batch_id and tenant_id = v_tenant) then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;
  return query
  with imp as (
    select p.currency,
           sum(p.gross_premium) as gross,
           sum(coalesce(p.commission_amount, 0)) as comm,
           coalesce((select sum(r.amount) from public.ins_import_receipts r
                      where r.batch_id = p_batch_id and r.tenant_id = v_tenant), 0) as receipts,
           coalesce((select sum(r.amount) from public.ins_import_remittances r
                      where r.batch_id = p_batch_id and r.tenant_id = v_tenant), 0) as remits
    from public.ins_policies p
    where p.tenant_id = v_tenant and p.import_batch_id = p_batch_id
    group by p.currency
  ),
  ctl as (
    select c->>'currency' as currency,
           (c->>'gross_premium')::numeric as gross,
           (c->>'commission')::numeric as comm,
           (c->>'receipts')::numeric as receipts,
           (c->>'remittances')::numeric as remits
    from public.ins_import_batches b,
         jsonb_array_elements(coalesce(b.control_totals, '[]'::jsonb)) c
    where b.id = p_batch_id and b.tenant_id = v_tenant
  )
  select i.currency, m.measure, m.amt, coalesce(c."value", 0), (m.amt = coalesce(c."value", 0))
  from imp i
  cross join lateral (values
    ('gross_premium', i.gross), ('commission', i.comm),
    ('receipts_to_date', i.receipts), ('remittances_to_date', i.remits)) m(measure, amt)
  left join lateral (select case m.measure
      when 'gross_premium' then c.gross when 'commission' then c.comm
      when 'receipts_to_date' then c.receipts when 'remittances_to_date' then c.remits end as "value"
    from ctl c where c.currency = i.currency) c on true;
end $$;

revoke all on function public.ins_import_post_opening_position(uuid) from public, anon;
revoke all on function public.ins_import_record_history(uuid, jsonb, jsonb) from public, anon;
revoke all on function public.ins_import_reconciliation(uuid) from public, anon;
grant execute on function public.ins_import_post_opening_position(uuid) to authenticated;
grant execute on function public.ins_import_record_history(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.ins_import_reconciliation(uuid) to authenticated;
