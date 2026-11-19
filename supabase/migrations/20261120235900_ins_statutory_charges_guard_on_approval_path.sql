-- =====================================================================
-- The statutory-charge bind guard must fire on the real approval path
-- =====================================================================
-- 20261120005000 wrote the guard as `old.status = 'draft'`. The approval workflow
-- means the real transition is draft -> pending_approval -> approved -> active, so
-- the guard never fired on the path the application actually takes: a policy
-- approved first could reach 'active' with statutory charges priced and never
-- acknowledged, which is the exact hole the mechanism exists to close.
--
-- Found by a probe that bound a policy already sitting at 'approved'. It succeeded.
--
-- Fix forward rather than editing the applied migration (MIGRATION_POLICY rule 9).
-- Only the transition condition changes; the re-pricing comparison is left as it
-- was written.
create or replace function public.ins_statutory_charges_bind_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_ack jsonb;
  v_now jsonb;
  v_now_total numeric := 0;
  v_ack_total numeric;
begin
  -- Any transition INTO active, not just draft -> active.
  if new.status = 'active' and old.status is distinct from 'active' then
    v_ack := new.statutory_charges_ack;

    if v_ack is null then
      -- No acknowledgement at all. Silence is only allowed when the catalogue
      -- genuinely prices nothing for this policy, which is a real case: a company
      -- with no verified statutory charge has nothing to price.
      select coalesce(jsonb_agg(jsonb_build_object(
               'catalogue_id', l.catalogue_id, 'code', l.code, 'amount', l.amount,
               'catalogue_version', l.catalogue_version) order by l.code), '[]'::jsonb),
             coalesce(sum(l.amount), 0)
        into v_now, v_now_total
        from public.ins_price_charges_for(
               new.tenant_id,
               jsonb_strip_nulls(jsonb_build_object(
                 'gross_premium', new.gross_premium,
                 'net_premium', new.gross_premium - coalesce(new.commission_amount, 0),
                 'commission', new.commission_amount,
                 'sum_insured', new.sum_insured,
                 'policy_count', 1)),
               (select code from public.ins_product_lines where id = new.product_line_id),
               new.currency, new.inception_date) l
       where l.amount > 0;

      if v_now_total > 0 then
        raise exception 'INS_CHARGE_NOT_ACKNOWLEDGED: the catalogue prices % for this policy but no statutory charges were acknowledged. Call ins_apply_statutory_charges then ins_acknowledge_statutory_charges before binding.', v_now_total
          using errcode = '23514';
      end if;
      return new;
    end if;

    -- Acknowledged: re-price with the acknowledged inputs and compare. A verified
    -- rate that changed between drafting and binding lands here.
    v_ack_total := coalesce((v_ack ->> 'total')::numeric, 0);
    select coalesce(sum(l.amount), 0)
      into v_now_total
      from public.ins_price_charges_for(
             new.tenant_id, coalesce(v_ack -> 'parameters', '{}'::jsonb),
             (select code from public.ins_product_lines where id = new.product_line_id),
             new.currency, new.inception_date) l
     where l.amount > 0;

    if v_now_total is distinct from v_ack_total then
      raise exception 'INS_CHARGE_ACK_STALE: the acknowledged statutory charges total % but the catalogue now prices %. Re-price and acknowledge again.', v_ack_total, v_now_total
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

revoke all on function public.ins_statutory_charges_bind_guard() from public, anon, authenticated;

-- The bind snapshot has the same flaw: it also keys off draft -> active, so a
-- policy that went through approval would bind without its statutory acknowledgement
-- frozen into the snapshot. Fixed in the wrapper, leaving the commission-only
-- function untouched.
create or replace function public.ins_snapshot_bind_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  new := public.ins_snapshot_bind_config_commission_only();

  -- Any transition into active, for the same reason as the guard above.
  if new.status = 'active' and old.status is distinct from 'active' then
    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object('statutory_charges', to_jsonb(new.statutory_charges_ack));
  end if;
  return new;
end $$;

revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated;

-- Note: ins_snapshot_bind_config_commission_only() itself still keys off
-- draft -> active for the commission keys. That is pre-existing behaviour with its
-- own test section, and changing it here would alter the commission snapshot for
-- approval-path policies -- a separate decision, recorded in ROADMAP.md rather than
-- made silently in a bug fix.
select 'statutory guard fires on the approval path' as status;
