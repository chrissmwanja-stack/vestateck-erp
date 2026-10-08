-- Phase 1, step 1 (continued): template module validation reads the registry.
--
-- save_industry_template() validated 'module' items against a hard-coded array
-- of 8 keys, so a template could never reference a module added later. It now
-- accepts any active, tenant-entitled key in platform_modules. Everything else
-- in the function is unchanged (same signature, errors, audit event).

-- A2. Save (create or replace) a template with its items in one call.
--     p_items: [{kind, sort_order, name, payload}] -- replaces all items.
create or replace function public.save_industry_template(
  p_key         text,
  p_name        text,
  p_description text,
  p_items       jsonb,
  p_is_active   boolean default true,
  p_sort_order  integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before jsonb;
  v_item   jsonb;
  v_kinds  text[] := array['department', 'module', 'workflow_stage'];
  v_orders integer[];
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

  -- Validate items.
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if not (v_item ->> 'kind') = any (v_kinds) then
      raise exception 'TEMPLATE_ITEMS_INVALID: unknown kind %', v_item ->> 'kind';
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
  end loop;

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
$$;

revoke all on function public.save_industry_template(text, text, text, jsonb, boolean, integer) from public;
grant execute on function public.save_industry_template(text, text, text, jsonb, boolean, integer) to authenticated;