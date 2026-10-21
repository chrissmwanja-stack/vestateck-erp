-- Production reports (Phase C item 4, first set): the production book and the
-- client statement of account, plus the branch options the New policy screen
-- needs.
--
-- The two reports are SECURITY DEFINER views whose WHERE clause carries the
-- whole guard -- tenant pinned through get_my_tenant_id() and insurance access
-- through can_access_insurance() -- the same rule the ins_unremitted_premium_report
-- RPC enforces. Definer is deliberate: the reports must resolve names from
-- neighbouring modules' tables (bd_clients is a business-development table,
-- organizations a finance/procurement one), whose own RLS an insurance user
-- cannot pass. A security_invoker view would silently render blanks; a definer
-- view with the guard in the WHERE renders the same rows the policy RLS would.
--
--   ins_production_book   one row per written policy with every reporting
--                         dimension (client, insurer, product, branch, agent,
--                         transaction type) and the three money columns.
--   ins_client_statement  per written policy: what was billed on bind (the
--                         gross premium), what the client actually paid
--                         (posted receipt cash; pending/rejected/cancelled
--                         requests are not money), and the balance. Statement
--                         of account for one client, and the aged-balance
--                         buckets across clients, come from this.
--
-- Reversed policies are not production: status in ('active','renewed'), the
-- same rule the commission views use.
--
-- ins_branch_options(p_include_inactive): the New policy screen's Branch
-- select. Insurance-gated (can_access_insurance), returns the caller's
-- tenant's organisations. Edit mode asks for inactive ones too so a draft's
-- saved branch stays selectable.

-- =====================================================================
-- A. ins_production_book
-- =====================================================================
create or replace view public.ins_production_book as
select
  p.tenant_id,
  p.id                as policy_id,
  p.policy_no,
  p.status,
  p.transaction_type,
  p.bound_at::date    as bound_date,
  p.client_id,
  bd.name             as client_name,
  p.insurer_id,
  i.name              as insurer_name,
  p.product_line_id,
  pl.name             as product_line_name,
  p.branch_id,
  o.site_name         as branch_name,
  p.agent_id,
  m.name              as agent_name,
  p.currency,
  p.gross_premium,
  p.commission_amount,
  p.net_premium_to_insurer
from public.ins_policies p
join public.ins_clients c        on c.id  = p.client_id
left join public.bd_clients bd   on bd.id = c.client_id
join public.ins_insurers i       on i.id  = p.insurer_id
join public.ins_product_lines pl on pl.id = p.product_line_id
left join public.organizations o on o.id  = p.branch_id
left join public.ins_intermediaries m on m.id = p.agent_id
where p.status in ('active', 'renewed')
  and p.tenant_id = public.get_my_tenant_id()
  and public.can_access_insurance();

-- =====================================================================
-- B. ins_client_statement
-- =====================================================================
create or replace view public.ins_client_statement as
select
  p.tenant_id,
  p.id              as policy_id,
  p.policy_no,
  p.client_id,
  bd.name           as client_name,
  p.currency,
  p.gross_premium   as billed_amount,
  coalesce(r.received, 0) as received_amount,
  p.gross_premium - coalesce(r.received, 0) as balance_amount,
  p.bound_at::date  as bound_date,
  p.expiry_date,
  p.status
from public.ins_policies p
join public.ins_clients c      on c.id  = p.client_id
left join public.bd_clients bd on bd.id = c.client_id
left join lateral (
  select sum(q.amount) as received
  from public.ins_policy_cash_requests q
  where q.tenant_id = p.tenant_id
    and q.policy_id = p.id
    and q.kind = 'receipt'
    and q.status = 'posted'
) r on true
where p.status in ('active', 'renewed')
  and p.tenant_id = public.get_my_tenant_id()
  and public.can_access_insurance();

-- =====================================================================
-- C. ins_branch_options -- the New policy screen's Branch select
-- =====================================================================
create or replace function public.ins_branch_options(p_include_inactive boolean default false)
returns table (
  id        uuid,
  site_name text,
  is_active boolean
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select o.id, o.site_name, o.is_active
  from public.organizations o
  where o.tenant_id = public.get_my_tenant_id()
    and public.can_access_insurance()
    and (p_include_inactive or o.is_active)
  order by o.site_name;
$$;

-- =====================================================================
-- D. Grants
-- =====================================================================
revoke all on public.ins_production_book from public, anon;
grant select on public.ins_production_book to authenticated;
revoke all on public.ins_client_statement from public, anon;
grant select on public.ins_client_statement to authenticated;
revoke all on function public.ins_branch_options(boolean) from public, anon;
grant execute on function public.ins_branch_options(boolean) to authenticated;
