-- Fix a NULL-comparison bypass in prevent_law_contract_direct_approval().
--
-- The guard tested
--     current_setting('app.allow_law_status_change', true) != 'true'
-- current_setting(name, true) returns NULL (not '') when the setting has
-- never been set in the current database session, and NULL != 'true' is NULL,
-- so the IF was skipped and the direct UPDATE went through. Any connection
-- that had not yet run submit_contract_for_approval()/decide_contract() in
-- its lifetime could therefore move a contract draft -> pending_approval or
-- pending_approval -> active with a plain table UPDATE, bypassing
-- decide_contract()'s separation-of-duties check. (Connections that had run
-- an RPC held '' / 'false' and were blocked, which is why this is
-- intermittent in practice and invisible in casual testing.)
--
-- Found by test_reapplied_hardening.sql on a fresh local stack: the direct
-- draft -> pending_approval UPDATE succeeded.
--
-- Fix: treat "unset" as "not allowed" with coalesce. Same shape as the
-- journal-void guard, which compares with = 'true' and so already fails closed.

create or replace function public.prevent_law_contract_direct_approval()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and old.status is distinct from new.status then
    if (old.status = 'draft' and new.status = 'pending_approval')
       or (old.status = 'pending_approval' and new.status in ('active', 'rejected')) then
      if coalesce(current_setting('app.allow_law_status_change', true), '') <> 'true' then
        raise exception 'LAW_STATUS_GUARD: contract status change %->% must go through submit_contract_for_approval() or decide_contract() RPC, not direct table UPDATE', old.status, new.status
          using errcode = 'restrict_violation';
      end if;
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.prevent_law_contract_direct_approval() from public;

comment on function public.prevent_law_contract_direct_approval() is
  'Blocks direct table UPDATE of law_contracts status for approval transitions (draft->pending_approval, pending_approval->active/rejected) -- must go through RPCs. Fails closed when app.allow_law_status_change is unset. Allows lifecycle transitions active->expired/terminated via direct UPDATE.';