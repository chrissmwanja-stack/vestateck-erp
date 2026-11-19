-- =====================================================================
-- The policy screen can see the statutory charge state
-- =====================================================================
-- 20261120005000 made pricing and acknowledgement possible; nothing could display
-- the result, so a manager had no way to know whether a policy was acknowledged, how
-- much it carried, or whether enforcement applied. This returns that from the one
-- call the screen already makes.
--
-- Additive only: `charges` already carries the catalogue columns through to_jsonb,
-- so the new keys are `statutory` (the policy-level acknowledgement and the
-- enforcement mode) and `enforcement`. Nothing existing changes shape.
create or replace function public.ins_policy_financial_details(p_policy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  p public.ins_policies%rowtype;
  v jsonb;
begin
  select * into p from public.ins_policies
   where id = p_policy_id and tenant_id = public.get_my_tenant_id();
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'policy_id', p.id,
    'policy_no', p.policy_no,
    'status', p.status,
    'currency', p.currency,
    'gross_premium', p.gross_premium,
    'shares', coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('insurer_name', i.name) order by s.insurer_id)
                          from public.ins_policy_insurer_shares s
                          join public.ins_insurers i on i.id = s.insurer_id
                         where s.policy_id = p.id), '[]'::jsonb),
    'charges', coalesce((select jsonb_agg(to_jsonb(c) order by c.id)
                           from public.ins_policy_charges c
                          where c.policy_id = p.id), '[]'::jsonb),
    'snapshot', (select to_jsonb(sn) from public.ins_policy_financial_snapshots sn where sn.policy_id = p.id),
    'can_configure', public.can_manage_insurance() and public.effective_user_id() = auth.uid(),
    'client_name', (select b.name from public.ins_clients c
                      join public.bd_clients b on b.id = c.client_id
                     where c.id = p.client_id),

    -- What the screen needs to decide whether to show the pricing/acknowledgement
    -- controls at all, and whether a bind will be refused without them.
    'statutory', jsonb_build_object(
      'ack', p.statutory_charges_ack,
      'acknowledged', p.statutory_charges_ack is not null,
      'acknowledged_total', (p.statutory_charges_ack ->> 'total')::numeric,
      -- Only lines this mechanism wrote count: a manual broker fee is not a
      -- statutory charge and must not make the total look acknowledged.
      'priced_total', coalesce((select sum(c.amount) from public.ins_policy_charges c
                                 where c.policy_id = p.id and c.catalogue_id is not null), 0),
      'priced_count', (select count(*) from public.ins_policy_charges c
                        where c.policy_id = p.id and c.catalogue_id is not null),
      'enforcement', public.ins_statutory_enforcement(p.tenant_id, p.inception_date)),
    -- Top level too: a caller that only wants the mode should not have to dig.
    'enforcement', public.ins_statutory_enforcement(p.tenant_id, p.inception_date)
  ) into v;

  return v;
end $$;

revoke all on function public.ins_policy_financial_details(uuid) from public, anon;
grant execute on function public.ins_policy_financial_details(uuid) to authenticated;

select 'policy financial details carry the statutory state' as status;
