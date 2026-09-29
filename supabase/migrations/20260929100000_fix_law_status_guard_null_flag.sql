-- Fix two guard functions reapplied in 20260929064635 that did not behave as
-- intended. Fix-forward: do NOT edit 20260929064635.
--
-- 1) prevent_law_contract_direct_approval()
--    current_setting('app.allow_law_status_change', true) returns NULL when the
--    setting was never defined in the session. `NULL != 'true'` is NULL, and
--    PL/pgSQL treats a NULL condition as false, so the RAISE was skipped and a
--    direct UPDATE (draft -> pending_approval, pending_approval -> active/rejected)
--    succeeded on any connection that had not yet run one of the RPCs.
--    Fix: coalesce the setting to '' before comparing.
--
-- 2) prevent_journal_mutation()
--    The same function is attached to journal_entries and journal_entry_lines,
--    but the void-bypass condition read old.status / new.status unconditionally.
--    journal_entry_lines has no status column, so an UPDATE on a line failed with
--    'record "old" has no field "status"' instead of JOURNAL_IMMUTABLE.
--    Fix: only look at status when the trigger is firing for journal_entries.
--    Nested IFs are used because PL/pgSQL does not guarantee AND short-circuiting.
--
-- Triggers stay attached; only the function bodies change.

create or replace function public.prevent_law_contract_direct_approval()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'UPDATE' and old.status is distinct from new.status then
    -- Block draft -> pending_approval and pending_approval -> active/rejected
    -- via direct UPDATE. These must go through submit_contract_for_approval()
    -- or decide_contract(), which set app.allow_law_status_change = 'true'.
    if (old.status = 'draft' and new.status = 'pending_approval')
       or (old.status = 'pending_approval' and new.status in ('active', 'rejected')) then
      if coalesce(current_setting('app.allow_law_status_change', true), '') <> 'true' then
        raise exception 'LAW_STATUS_GUARD: contract status change %->% must go through submit_contract_for_approval() or decide_contract() RPC, not direct table UPDATE', old.status, new.status
          using errcode = 'restrict_violation';
      end if;
    end if;
    -- Lifecycle transitions (active -> expired/terminated, expired -> terminated, ...)
    -- remain allowed via direct UPDATE.
  end if;
  return new;
end;
$function$;

create or replace function public.prevent_journal_mutation()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  -- INSERT goes through post_journal_entry(); UPDATE/DELETE are blocked for
  -- everyone including the table owner. The only exception is the
  -- posted -> void status change on journal_entries, made by void_journal_entry()
  -- which sets app.allow_journal_void = 'true' for its own transaction.
  if tg_op = 'UPDATE' then
    if tg_table_name = 'journal_entries' then
      if old.status = 'posted' and new.status = 'void' then
        if coalesce(current_setting('app.allow_journal_void', true), '') = 'true' then
          return new;
        end if;
      end if;
    end if;
    raise exception 'JOURNAL_IMMUTABLE: journal entries are immutable, create a reversal entry instead (attempted % on %)', tg_op, old.id
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'JOURNAL_IMMUTABLE: journal entries cannot be deleted (attempted delete on %)', old.id
      using errcode = 'restrict_violation';
  end if;
  return null;
end;
$function$;

-- Self-check: abort (and roll back) if either body or trigger is not as expected.
do $$
begin
  if pg_get_functiondef('public.prevent_law_contract_direct_approval()'::regprocedure)
       not like '%coalesce(current_setting(''app.allow_law_status_change'', true)%' then
    raise exception 'prevent_law_contract_direct_approval() does not contain the NULL-safe flag check';
  end if;

  if pg_get_functiondef('public.prevent_journal_mutation()'::regprocedure)
       not like '%tg_table_name = ''journal_entries''%' then
    raise exception 'prevent_journal_mutation() does not contain the table-name branch';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.law_contracts'::regclass
      and tgname = 'trg_prevent_law_contract_direct_approval'
      and tgenabled = 'O'
  ) then
    raise exception 'trg_prevent_law_contract_direct_approval is missing or disabled on law_contracts';
  end if;
end $$;