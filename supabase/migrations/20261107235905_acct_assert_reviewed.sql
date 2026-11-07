-- =====================================================================
-- Stage 4: compliance gate on posting paths.
-- acct_assert_reviewed(p_key) raises unless the live approved value for
-- the key exists AND is review_status='reviewed' (or the definition does
-- not require legal review). The bind snapshot trigger calls it, so a
-- legal-applicability treatment that is only configured but not reviewed
-- blocks binding instead of silently applying.
-- =====================================================================

create or replace function public.acct_assert_reviewed(p_key text, p_on date default current_date)
returns text
language plpgsql stable security definer set search_path = 'public'
as $$
declare
  v_legal boolean;
  v_row public.company_accounting_settings;
begin
  select d.requires_legal_review into v_legal
  from public.accounting_setting_definitions d where d.key = p_key;
  if not found then
    raise exception 'ACCT_UNKNOWN_KEY: %', p_key;
  end if;
  if not coalesce(v_legal, false) then
    return public.acct_get_setting(p_key, p_on);  -- not a legal key: no gate
  end if;

  select * into v_row from public.company_accounting_settings s
  where s.tenant_id = public.get_my_tenant_id() and s.setting_key = p_key
    and s.status = 'approved' and s.effective_from <= p_on
  order by s.effective_from desc limit 1;

  if not found then
    raise exception 'ACCT_LEGAL_UNREVIEWED: % has no approved value in force; configure and review it first', p_key;
  end if;
  if v_row.review_status <> 'reviewed' then
    raise exception 'ACCT_LEGAL_UNREVIEWED: % is approved but not compliance-reviewed', p_key;
  end if;
  return v_row.value;
end $$;

revoke all on function public.acct_assert_reviewed(text, date) from public, anon;
grant execute on function public.acct_assert_reviewed(text, date) to authenticated;

-- Bind snapshot now gates legal keys.
create or replace function public.ins_snapshot_bind_config()
returns trigger language plpgsql security definer set search_path = 'public'
as $$
declare
  v_recognition text;
begin
  if new.status = 'active' and old.status is distinct from new.status then
    v_recognition := public.acct_assert_reviewed('ins.commission_recognition', new.inception_date);
    new.accounting_config_snapshot := jsonb_build_object(
      'ins.commission_recognition', v_recognition,
      'resolved_at', now()
    );
  end if;
  return new;
end $$;
