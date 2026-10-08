-- Phase 1, step 4 (decisions D5 and D7 in PHASE0_COUPLING_AUDIT.md).
--
-- Lets an industry template carry a chart of accounts, GL posting rules and
-- feature-flag defaults, and adds apply_template() to add a template's content
-- to an EXISTING tenant without overwriting anything.
--
--   1. industry_template_items.kind gains: gl_account, posting_rule, feature_flag.
--      Item shapes (name is the natural key, so UNIQUE (template_key, kind, name)
--      holds without a surrogate):
--        gl_account    name = account code
--                      payload {name, account_type, is_control_account?}
--        posting_rule  name = account role (see platform_gl_posting_roles())
--                      payload {account_code}  -- a gl_account item in the SAME template
--        feature_flag  name = platform_feature_flags.key
--                      payload {enabled?}      -- default true
--   2. gl_posting_rules.account_role gains 5 insurance-brokerage roles. Additive:
--      the posting code that USES them is Phase 2 and needs its own change.
--   3. save_industry_template() validates the new kinds, and now also rejects a
--      duplicate (kind, name) with a clear message instead of a unique violation.
--      It also rejects a missing kind (previously a NULL kind slipped past the
--      allow-list because `not NULL` is NULL).
--   4. platform_apply_template_items() (internal) computes / writes the additions.
--   5. apply_template(tenant, template, mode, reason): platform admin only.
--        preview  returns what would be added, writes nothing, needs no reason.
--        fill     inserts only what is missing, never overwrites, needs a reason,
--                 writes an audit event.
--      Anything that already exists but differs (an account with the same code and
--      another type, a posting rule pointing elsewhere, a flag with another value)
--      is reported under "conflicts" and left alone.
--   6. seed_tenant_defaults() additionally applies gl_account / posting_rule /
--      feature_flag items. Those are idempotent, so they run even when the
--      departments/workflow early-return fires (a re-invoked create-tenant heals
--      a tenant that lost its chart).
--
-- The `general` and `construction` templates are NOT touched: they carry no GL
-- items, so new companies on them still start with no chart and the existing
-- "Seed chart" button keeps working.

-- ---------------------------------------------------------------------
-- 1. Item kinds
-- ---------------------------------------------------------------------
alter table public.industry_template_items
  drop constraint if exists industry_template_items_kind_check;
alter table public.industry_template_items
  add constraint industry_template_items_kind_check
  check (kind in ('department', 'module', 'workflow_stage', 'gl_account', 'posting_rule', 'feature_flag'));

-- ---------------------------------------------------------------------
-- 2. Posting roles (13 existing + 5 insurance)
-- ---------------------------------------------------------------------
alter table public.gl_posting_rules
  drop constraint if exists gl_posting_rules_account_role_check;
alter table public.gl_posting_rules
  add constraint gl_posting_rules_account_role_check
  check (account_role in (
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable'
  ));

-- Single list used by save_industry_template(). test_template_kinds_and_apply_template
-- fails if this drifts from the CHECK above.
create or replace function public.platform_gl_posting_roles()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable'
  ]::text[];
$$;

revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

-- ---------------------------------------------------------------------
-- 3. save_industry_template(): validate the new kinds
-- ---------------------------------------------------------------------
create or replace function public.save_industry_template(
  p_key text, p_name text, p_description text, p_items jsonb,
  p_is_active boolean default true, p_sort_order integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_before jsonb;
  v_item   jsonb;
  v_kinds  text[] := array['department', 'module', 'workflow_stage', 'gl_account', 'posting_rule', 'feature_flag'];
  v_types  text[] := array['asset', 'liability', 'equity', 'revenue', 'expense'];
  v_orders integer[];
  v_codes  text[];
  v_dup    text;
begin
  perform require_platform_admin('Editing industry templates');

  if p_key !~ '^[a-z][a-z0-9_]{1,39}$' then
    raise exception 'TEMPLATE_KEY_INVALID: key must be 2-40 chars, lowercase letters, digits or underscores, starting with a letter';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'TEMPLATE_NAME_REQUIRED: a template needs a name';
  end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'TEMPLATE_ITEMS_INVALID: items must be an array';
  end if;

  -- Codes of the template's own GL accounts, for posting-rule validation.
  select coalesce(array_agg(btrim(i ->> 'name')), '{}') into v_codes
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
  where i ->> 'kind' = 'gl_account';

  -- Validate items.
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if (v_item ->> 'kind') is null or not ((v_item ->> 'kind') = any (v_kinds)) then
      raise exception 'TEMPLATE_ITEMS_INVALID: unknown kind %', coalesce(v_item ->> 'kind', '(missing)');
    end if;
    if coalesce(btrim(v_item ->> 'name'), '') = '' then
      raise exception 'TEMPLATE_ITEMS_INVALID: every item needs a name';
    end if;
    if (v_item ->> 'kind') = 'module' and not exists (
         select 1 from platform_modules m
         where m.key = (v_item ->> 'name') and m.is_active and m.tenant_entitled
       ) then
      raise exception 'TEMPLATE_ITEMS_INVALID: unknown module %', v_item ->> 'name';
    end if;
    if (v_item ->> 'kind') = 'workflow_stage' and coalesce(btrim(v_item -> 'payload' ->> 'approver_role'), '') = '' then
      raise exception 'TEMPLATE_ITEMS_INVALID: stage "%" needs an approver_role', v_item ->> 'name';
    end if;

    if (v_item ->> 'kind') = 'gl_account' then
      if btrim(v_item ->> 'name') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$' then
        raise exception 'TEMPLATE_ITEMS_INVALID: account code "%" must be 1-20 characters: letters, digits, dot, dash or underscore', v_item ->> 'name';
      end if;
      if coalesce(btrim(v_item -> 'payload' ->> 'name'), '') = '' then
        raise exception 'TEMPLATE_ITEMS_INVALID: account "%" needs a name in its payload', v_item ->> 'name';
      end if;
      if not coalesce((v_item -> 'payload' ->> 'account_type') = any (v_types), false) then
        raise exception 'TEMPLATE_ITEMS_INVALID: account "%" has an invalid account_type (use asset, liability, equity, revenue or expense)', v_item ->> 'name';
      end if;
      if (v_item -> 'payload') ? 'is_control_account'
         and jsonb_typeof(v_item -> 'payload' -> 'is_control_account') <> 'boolean' then
        raise exception 'TEMPLATE_ITEMS_INVALID: account "%" is_control_account must be true or false', v_item ->> 'name';
      end if;
    end if;

    if (v_item ->> 'kind') = 'posting_rule' then
      if not (btrim(v_item ->> 'name') = any (platform_gl_posting_roles())) then
        raise exception 'TEMPLATE_ITEMS_INVALID: unknown posting role "%"', v_item ->> 'name';
      end if;
      if not coalesce(btrim(v_item -> 'payload' ->> 'account_code') = any (v_codes), false) then
        raise exception 'TEMPLATE_ITEMS_INVALID: posting rule "%" points at account "%" which is not a gl_account in this template',
          v_item ->> 'name', coalesce(v_item -> 'payload' ->> 'account_code', '(none)');
      end if;
    end if;

    if (v_item ->> 'kind') = 'feature_flag' then
      if not exists (select 1 from platform_feature_flags f where f.key = btrim(v_item ->> 'name')) then
        raise exception 'TEMPLATE_ITEMS_INVALID: unknown feature flag "%"', v_item ->> 'name';
      end if;
      if (v_item -> 'payload') ? 'enabled' and jsonb_typeof(v_item -> 'payload' -> 'enabled') <> 'boolean' then
        raise exception 'TEMPLATE_ITEMS_INVALID: flag "%" enabled must be true or false', v_item ->> 'name';
      end if;
    end if;
  end loop;

  -- One item per (kind, name): the table is UNIQUE on it, so say so plainly.
  select i ->> 'kind' || ' "' || btrim(i ->> 'name') || '"' into v_dup
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
  group by i ->> 'kind', btrim(i ->> 'name')
  having count(*) > 1
  limit 1;
  if v_dup is not null then
    raise exception 'TEMPLATE_ITEMS_INVALID: duplicate item %', v_dup;
  end if;

  -- Stage routing must point at stages that exist in this template.
  select array_agg((i ->> 'sort_order')::integer) into v_orders
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i where i ->> 'kind' = 'workflow_stage';
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i where i ->> 'kind' = 'workflow_stage' loop
    if (v_item -> 'payload' ->> 'next_low') is not null and not ((v_item -> 'payload' ->> 'next_low')::integer = any (v_orders)) then
      raise exception 'TEMPLATE_ITEMS_INVALID: stage "%" routes (low) to a stage that does not exist', v_item ->> 'name';
    end if;
    if (v_item -> 'payload' ->> 'next_high') is not null and not ((v_item -> 'payload' ->> 'next_high')::integer = any (v_orders)) then
      raise exception 'TEMPLATE_ITEMS_INVALID: stage "%" routes (high) to a stage that does not exist', v_item ->> 'name';
    end if;
  end loop;

  select to_jsonb(t) || jsonb_build_object('items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.kind, i.sort_order), '[]'::jsonb) from industry_template_items i where i.template_key = t.key))
    into v_before from industry_templates t where t.key = p_key;

  insert into industry_templates (key, name, description, is_active, sort_order, updated_by)
  values (p_key, btrim(p_name), nullif(btrim(p_description), ''), coalesce(p_is_active, true), coalesce(p_sort_order, 100), auth.uid())
  on conflict (key) do update
    set name = excluded.name, description = excluded.description, is_active = excluded.is_active,
        sort_order = excluded.sort_order, updated_at = now(), updated_by = auth.uid();

  delete from industry_template_items where template_key = p_key;
  insert into industry_template_items (template_key, kind, sort_order, name, payload)
  select p_key, i ->> 'kind', coalesce((i ->> 'sort_order')::integer, rn::integer), btrim(i ->> 'name'), coalesce(i -> 'payload', '{}'::jsonb)
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality as x(i, rn);

  perform log_platform_event(
    case when v_before is null then 'industry_template.create' else 'industry_template.update' end,
    null, 'industry_template', p_key, null, v_before,
    (select to_jsonb(t) || jsonb_build_object('items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.kind, i.sort_order), '[]'::jsonb) from industry_template_items i where i.template_key = t.key))
       from industry_templates t where t.key = p_key)
  );

  return (select to_jsonb(r) from list_industry_templates(true) r where r.key = p_key);
end;
$function$;

-- ---------------------------------------------------------------------
-- 4. Internal: compute and (optionally) write a template's additions
-- ---------------------------------------------------------------------
create or replace function public.platform_apply_template_items(
  p_tenant_id    uuid,
  p_template_key text,
  p_kinds        text[],
  p_write        boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_item      record;
  v_mods      text[] := '{}';
  v_depts     text[] := '{}';
  v_flags     jsonb  := '[]'::jsonb;
  v_accts     jsonb  := '[]'::jsonb;
  v_rules     jsonb  := '[]'::jsonb;
  v_conf      jsonb  := '[]'::jsonb;
  v_new_codes text[] := '{}';
  v_code      text;
  v_acct_id   uuid;
  v_cur_code  text;
  v_cur_type  text;
  v_cur_on    boolean;
  v_want_on   boolean;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can apply template content';
  end if;

  -- Modules: entitle the ones the tenant lacks. set_tenant_modules() also gives the
  -- tenant's company admins an admin role on each newly entitled module.
  if 'module' = any (p_kinds) then
    for v_item in
      select i.name from industry_template_items i
      where i.template_key = p_template_key and i.kind = 'module' order by i.sort_order
    loop
      if exists (select 1 from tenant_modules where tenant_id = p_tenant_id and module = v_item.name) then
        continue;
      end if;
      if not exists (select 1 from platform_modules m where m.key = v_item.name and m.is_active and m.tenant_entitled) then
        v_conf := v_conf || jsonb_build_object('kind', 'module', 'name', v_item.name,
                    'reason', 'module is no longer active or entitleable in the registry');
        continue;
      end if;
      v_mods := v_mods || v_item.name;
    end loop;
    if p_write and cardinality(v_mods) > 0 then
      perform set_tenant_modules(
        p_tenant_id,
        coalesce((select array_agg(module) from tenant_modules where tenant_id = p_tenant_id), '{}') || v_mods
      );
    end if;
  end if;

  -- Departments: matched by name, case-insensitive; existing ones are left as they are.
  if 'department' = any (p_kinds) then
    for v_item in
      select i.name from industry_template_items i
      where i.template_key = p_template_key and i.kind = 'department' order by i.sort_order
    loop
      if exists (select 1 from departments d
                  where d.tenant_id = p_tenant_id and lower(btrim(d.name)) = lower(btrim(v_item.name))) then
        continue;
      end if;
      v_depts := v_depts || v_item.name;
      if p_write then
        insert into departments (tenant_id, name) values (p_tenant_id, v_item.name);
      end if;
    end loop;
  end if;

  -- Feature flags: insert missing overrides; a differing existing override is a conflict.
  if 'feature_flag' = any (p_kinds) then
    for v_item in
      select i.name, i.payload from industry_template_items i
      where i.template_key = p_template_key and i.kind = 'feature_flag' order by i.sort_order
    loop
      v_want_on := coalesce((v_item.payload ->> 'enabled')::boolean, true);
      if not exists (select 1 from platform_feature_flags f where f.key = v_item.name) then
        v_conf := v_conf || jsonb_build_object('kind', 'feature_flag', 'name', v_item.name,
                    'reason', 'flag no longer exists');
        continue;
      end if;
      select tf.enabled into v_cur_on from tenant_feature_flags tf
       where tf.tenant_id = p_tenant_id and tf.flag_key = v_item.name;
      if found then
        if v_cur_on is distinct from v_want_on then
          v_conf := v_conf || jsonb_build_object('kind', 'feature_flag', 'name', v_item.name,
                      'reason', 'tenant already overrides this flag',
                      'existing', v_cur_on, 'template', v_want_on);
        end if;
        continue;
      end if;
      v_flags := v_flags || jsonb_build_object('flag_key', v_item.name, 'enabled', v_want_on);
      if p_write then
        insert into tenant_feature_flags (tenant_id, flag_key, enabled, note, updated_by)
        values (p_tenant_id, v_item.name, v_want_on, 'Applied from template ' || p_template_key, auth.uid());
      end if;
    end loop;
  end if;

  -- GL accounts: matched by code. Never renamed or retyped.
  if 'gl_account' = any (p_kinds) then
    for v_item in
      select i.name, i.payload from industry_template_items i
      where i.template_key = p_template_key and i.kind = 'gl_account' order by i.sort_order
    loop
      select a.account_type into v_cur_type from gl_accounts a
       where a.tenant_id = p_tenant_id and a.account_code = v_item.name;
      if found then
        if v_cur_type is distinct from (v_item.payload ->> 'account_type') then
          v_conf := v_conf || jsonb_build_object('kind', 'gl_account', 'name', v_item.name,
                      'reason', 'account code exists with a different type',
                      'existing', v_cur_type, 'template', v_item.payload ->> 'account_type');
        end if;
        continue;
      end if;
      v_accts := v_accts || jsonb_build_object('account_code', v_item.name,
                   'name', v_item.payload ->> 'name', 'account_type', v_item.payload ->> 'account_type');
      v_new_codes := v_new_codes || v_item.name;
      if p_write then
        insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
        values (p_tenant_id, v_item.name, v_item.payload ->> 'name', v_item.payload ->> 'account_type',
                coalesce((v_item.payload ->> 'is_control_account')::boolean, false));
      end if;
    end loop;
  end if;

  -- Posting rules: one per role. An existing rule is never repointed.
  if 'posting_rule' = any (p_kinds) then
    for v_item in
      select i.name, i.payload from industry_template_items i
      where i.template_key = p_template_key and i.kind = 'posting_rule' order by i.sort_order
    loop
      v_code := v_item.payload ->> 'account_code';
      select a.account_code into v_cur_code
        from gl_posting_rules r join gl_accounts a on a.id = r.gl_account_id
       where r.tenant_id = p_tenant_id and r.account_role = v_item.name;
      if found then
        if v_cur_code is distinct from v_code then
          v_conf := v_conf || jsonb_build_object('kind', 'posting_rule', 'name', v_item.name,
                      'reason', 'role already points at a different account',
                      'existing', v_cur_code, 'template', v_code);
        end if;
        continue;
      end if;
      select a.id into v_acct_id from gl_accounts a
       where a.tenant_id = p_tenant_id and a.account_code = v_code;
      if v_acct_id is null and not (not p_write and v_code = any (v_new_codes)) then
        v_conf := v_conf || jsonb_build_object('kind', 'posting_rule', 'name', v_item.name,
                    'reason', 'target account ' || coalesce(v_code, '(none)') || ' is not available on this tenant');
        continue;
      end if;
      v_rules := v_rules || jsonb_build_object('account_role', v_item.name, 'account_code', v_code);
      if p_write then
        insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
        values (p_tenant_id, v_item.name, v_acct_id);
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'modules',       to_jsonb(v_mods),
    'departments',   to_jsonb(v_depts),
    'feature_flags', v_flags,
    'gl_accounts',   v_accts,
    'posting_rules', v_rules,
    'conflicts',     v_conf
  );
end;
$function$;

revoke all on function public.platform_apply_template_items(uuid, text, text[], boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. apply_template(): the platform-admin entry point
-- ---------------------------------------------------------------------
create or replace function public.apply_template(
  p_tenant_id    uuid,
  p_template_key text,
  p_mode         text default 'preview',
  p_reason       text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_result jsonb;
  v_write  boolean := (p_mode = 'fill');
begin
  perform require_platform_admin('Applying an industry template');

  if p_mode is null or p_mode not in ('preview', 'fill') then
    raise exception 'TEMPLATE_MODE_INVALID: mode must be preview or fill';
  end if;
  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'TENANT_NOT_FOUND: no such company';
  end if;
  if not exists (select 1 from industry_templates where key = p_template_key and is_active) then
    raise exception 'TEMPLATE_NOT_FOUND: no active template %', p_template_key;
  end if;
  if v_write and coalesce(length(btrim(p_reason)), 0) < 5 then
    raise exception 'REASON_REQUIRED: give a reason (at least 5 characters) - it goes in the audit log';
  end if;

  v_result := platform_apply_template_items(
    p_tenant_id, p_template_key,
    array['module', 'department', 'feature_flag', 'gl_account', 'posting_rule'],
    v_write
  );

  if v_write then
    perform log_platform_event('tenant.template.apply', p_tenant_id, 'tenant', p_tenant_id::text, p_reason,
      null, jsonb_build_object('template', p_template_key, 'added', v_result - 'conflicts',
                               'conflicts', v_result -> 'conflicts'));
  end if;

  return v_result || jsonb_build_object('mode', p_mode, 'template', p_template_key, 'applied', v_write);
end;
$function$;

revoke all on function public.apply_template(uuid, text, text, text) from public, anon;
grant execute on function public.apply_template(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. seed_tenant_defaults(): also apply the new kinds
-- ---------------------------------------------------------------------
create or replace function public.seed_tenant_defaults(p_tenant_id uuid, p_industry_template text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_key text := coalesce(nullif(btrim(p_industry_template), ''), (select key from industry_templates where is_default), 'general');
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can seed tenant defaults';
  end if;

  if not exists (select 1 from industry_templates where key = v_key and is_active) then
    raise exception 'TEMPLATE_NOT_FOUND: no active industry template "%"', v_key;
  end if;

  -- Departments, workflow, modules: first-time seeding only (unchanged behaviour).
  if not (exists (select 1 from departments where tenant_id = p_tenant_id)
          or exists (select 1 from workflow_stages where tenant_id = p_tenant_id)) then
    insert into departments (tenant_id, name)
    select p_tenant_id, i.name
    from industry_template_items i
    where i.template_key = v_key and i.kind = 'department'
    order by i.sort_order;

    perform platform_seed_workflow_from_template(p_tenant_id, v_key, 'requests');

    insert into tenant_modules (tenant_id, module, enabled_by)
    select p_tenant_id, i.name, auth.uid()
    from industry_template_items i
    where i.template_key = v_key and i.kind = 'module'
    order by i.sort_order
    on conflict do nothing;

    update tenants set industry_template = v_key where id = p_tenant_id and industry_template is distinct from v_key;
  end if;

  -- Chart of accounts, posting rules and flag defaults: fill-only, so safe to repeat.
  perform platform_apply_template_items(p_tenant_id, v_key,
    array['feature_flag', 'gl_account', 'posting_rule'], true);
end;
$function$;
