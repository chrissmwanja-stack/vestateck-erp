-- Fix prevent_journal_mutation() failing on journal_entry_lines.
-- Fix-forward: do NOT edit 20260929064635.
--
-- The same trigger function is attached to journal_entries and
-- journal_entry_lines, but the void-bypass condition read old.status /
-- new.status unconditionally. journal_entry_lines has no status column, so an
-- UPDATE on a line failed with 'record "old" has no field "status"' instead of
-- raising JOURNAL_IMMUTABLE. Immutability still held (the UPDATE errored), but
-- with the wrong error, and the drift check could not see it.
--
-- Fix: only look at status when the trigger fires for journal_entries. Nested
-- IFs are used because PL/pgSQL does not guarantee AND short-circuiting.
-- Flag comparison is coalesced so it fails closed when the flag is unset.
--
-- The law_contracts guard (NULL-flag bypass) is fixed separately in
-- 20260929140000_fix_law_guard_null_bypass.sql.
--
-- Triggers stay attached; only the function body changes.

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

-- Self-check: abort (and roll back) if the body or either trigger is not as expected.
do $$
begin
  if pg_get_functiondef('public.prevent_journal_mutation()'::regprocedure)
       not like '%tg_table_name = ''journal_entries''%' then
    raise exception 'prevent_journal_mutation() does not contain the table-name branch';
  end if;

  if (select count(*) from pg_trigger
      where tgfoid = 'public.prevent_journal_mutation()'::regprocedure
        and tgenabled = 'O'
        and tgrelid in ('public.journal_entries'::regclass, 'public.journal_entry_lines'::regclass)) <> 2 then
    raise exception 'prevent_journal_mutation trigger missing or disabled on journal_entries / journal_entry_lines';
  end if;
end $$;