-- =====================================================================
-- Fix 20261107235905: acct_assert_reviewed returns text, but for a key that
-- does not need legal review it returned acct_get_setting(...), which is a
-- jsonb object ({key, value, source, ...}); plpgsql cast that object to text,
-- so callers (the bind snapshot trigger) received the whole JSON document
-- instead of the setting's value. Return the 'value' field. The legal-key
-- path already returned the bare value. Otherwise identical.
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
    return public.acct_get_setting(p_key, p_on) ->> 'value';  -- not a legal key: no gate
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