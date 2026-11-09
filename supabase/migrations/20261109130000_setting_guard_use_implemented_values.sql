-- The phase 1 consolidation (20261108010000) added implemented_values and made
-- allowed_values list planned treatments too, but company_accounting_settings_guard
-- still validated against allowed_values, so a planned value such as
-- over_policy_term could be proposed. Validate against implemented_values
-- (falling back to allowed_values where none are recorded), and expose
-- implemented_values in acct_settings_overview for the settings screen.
-- Both functions copied from 20261107150000, their latest definition.

create or replace function public.company_accounting_settings_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_via        boolean := coalesce(current_setting('acct.via_rpc', true), '') = 'on';
  v_allowed    text[];
  v_prev_from  date;
  v_latest_je  date;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.review_status <> 'unreviewed' then
      raise exception 'ACCT_SETTING_STATUS: a new setting choice starts as an unreviewed draft';
    end if;
    if new.approved_by is not null or new.approved_at is not null or new.withdrawn_reason is not null
       or new.reviewer_name is not null or new.review_reference is not null
       or new.reviewed_by is not null or new.reviewed_at is not null then
      raise exception 'ACCT_SETTING_STATUS: approval, withdrawal and review fields cannot be set on a new draft';
    end if;

    -- a value is selectable only if the code implements it; keys with no
    -- implemented_values recorded treat every allowed value as implemented
    select case when cardinality(implemented_values) = 0 then allowed_values
                else implemented_values end
      into v_allowed
      from accounting_setting_definitions where key = new.setting_key;
    if not found then
      raise exception 'ACCT_SETTING_UNKNOWN: no accounting setting named %', new.setting_key;
    end if;
    if not (new.value = any (v_allowed)) then
      raise exception 'ACCT_SETTING_VALUE_NOT_ALLOWED: % is not an implemented option for % (allowed: %)',
        new.value, new.setting_key, array_to_string(v_allowed, ', ');
    end if;
  else
    if not v_via then
      raise exception 'ACCT_SETTING_VIA_RPC: change a setting through the acct_setting_* functions';
    end if;
    if new.tenant_id is distinct from old.tenant_id
       or new.setting_key is distinct from old.setting_key
       or new.value is distinct from old.value
       or new.effective_from is distinct from old.effective_from
       or new.rationale is distinct from old.rationale
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'ACCT_SETTING_IMMUTABLE: what was chosen, when it takes effect and why cannot change; propose a new choice instead';
    end if;
    if old.status = 'withdrawn' then
      raise exception 'ACCT_SETTING_IMMUTABLE: a withdrawn choice cannot be changed';
    end if;
    if old.status = 'approved' and new.status is distinct from old.status then
      raise exception 'ACCT_SETTING_IMMUTABLE: an approved choice cannot be withdrawn or changed; propose a new choice instead';
    end if;
    if old.review_status = 'reviewed' and (
         new.review_status is distinct from old.review_status
         or new.reviewer_name is distinct from old.reviewer_name
         or new.review_reference is distinct from old.review_reference
         or new.reviewed_by is distinct from old.reviewed_by
         or new.reviewed_at is distinct from old.reviewed_at) then
      raise exception 'ACCT_SETTING_IMMUTABLE: a recorded review cannot be changed';
    end if;

    if new.status = 'approved' and old.status = 'draft' then
      perform pg_advisory_xact_lock(hashtextextended('acct_setting:' || new.tenant_id::text || ':' || new.setting_key, 0));

      select max(effective_from) into v_prev_from
        from company_accounting_settings
       where tenant_id = new.tenant_id and setting_key = new.setting_key
         and status = 'approved' and id <> new.id;
      if v_prev_from is not null and new.effective_from <= v_prev_from then
        raise exception 'ACCT_SETTING_DATE_ORDER: effective date must be later than the previous approved choice''s (%)', v_prev_from;
      end if;

      select max(entry_date) into v_latest_je from journal_entries where tenant_id = new.tenant_id;
      if v_latest_je is not null and new.effective_from <= v_latest_je then
        raise exception 'ACCT_SETTING_BACKDATED: an entry dated % is already posted; choose an effective date after it (a restatement is a separate, accountant-led exercise)', v_latest_je;
      end if;
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.acct_settings_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_out jsonb;
begin
  if get_my_tenant_id() is null then
    raise exception 'ACCT_SETTING_FORBIDDEN: no company in context' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(
           jsonb_build_object('label', d.label, 'description', d.description, 'allowed_values', to_jsonb(d.allowed_values),
                              'implemented_values', to_jsonb(case when cardinality(d.implemented_values) = 0
                                                                  then d.allowed_values else d.implemented_values end))
           || public.acct_get_setting(d.key, current_date)
           order by d.key), '[]'::jsonb)
    into v_out
    from accounting_setting_definitions d;
  return v_out;
end;
$$;

revoke all on function public.company_accounting_settings_guard() from public, anon, authenticated;
revoke all on function public.acct_settings_overview() from public, anon;
grant execute on function public.acct_settings_overview() to authenticated;