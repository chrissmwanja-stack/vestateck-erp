-- Fix: approve_bank_adjustment could never succeed.
--
-- bank_reconciliation_adjustment_guard() (20261119064626) blocks any INSERT into
-- bank_reconciliations while a pending adjustment exists for the statement
-- line, so another flow cannot reconcile a line that is waiting for approval.
-- But approve_bank_adjustment inserts its own reconciliation row while the
-- adjustment is still 'pending' (it becomes 'posted' in the UPDATE after the
-- insert), so the approval tripped its own guard:
--   RECON_BLOCKED: a bank adjustment is pending for this statement line
-- Found by test_fin_bank_adjustments.sql, the first time it ran in CI.
--
-- The INSERT branch now ignores the one pending adjustment that owns the new
-- row, and only inside the approval RPC: the row must name that adjustment in
-- bank_adjustment_id AND app.bank_adjustment_rpc must be 'on' (set by the RPCs
-- before they write, as for the UPDATE/DELETE branch). A direct insert that
-- merely sets bank_adjustment_id is still blocked. Any other pending
-- adjustment for the line, or any insert without the flag, is blocked as
-- before. The UPDATE/DELETE branch is unchanged.
--
-- Fix forward (rule 9): 20261119064626 is not edited. CREATE OR REPLACE keeps
-- the trigger and the function's existing grants. Idempotent; safe to replay.
create or replace function public.bank_reconciliation_adjustment_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'INSERT' then
    if exists (select 1 from public.bank_adjustments a
                where a.bank_statement_line_id = new.bank_statement_line_id
                  and a.kind = 'adjustment'
                  and a.status = 'pending'
                  and not (new.bank_adjustment_id is not null
                           and a.id = new.bank_adjustment_id
                           and coalesce(current_setting('app.bank_adjustment_rpc', true), '') = 'on')) then
      raise exception 'RECON_BLOCKED: a bank adjustment is pending for this statement line; approve or reject it first';
    end if;
    return new;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    if old.bank_adjustment_id is not null
       and coalesce(current_setting('app.bank_adjustment_rpc', true), '') <> 'on' then
      raise exception 'RECON_LOCKED: this reconciliation belongs to a posted bank adjustment; reverse the adjustment instead';
    end if;
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  return new;
end;
$function$;
