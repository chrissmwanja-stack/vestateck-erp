-- =====================================================================
-- Insurance brokerage: re-apply two objects that 20261107090000 was meant
-- to restore, but which are still in their 20261106180000 shape on the
-- live project (xownbroirovedkmqyybc).
--
-- Found by fingerprinting the live catalog against a from-scratch replay of
-- the repo (18 Nov 2026). Everything else matched; these two did not:
--
-- 1. ins_policies_status_check on live allows only
--      (draft, pending_approval, approved, rejected, active, renewed)
--    so 'reversed' and 'cancelled' violate the check. ins_reverse_policy and
--    ins_decide_policy_cancellation fail on the first real policy.
--
-- 2. ins_policy_bind_guard on live raises INS_NOT_APPROVED whenever
--    new.status is 'active' or 'renewed' and old.status is not 'approved',
--    on EVERY update. Editing an already-active policy, or marking a
--    predecessor 'renewed', fails.
--
-- Both statements are the definitions from 20261107090000 (the guard keeps the
-- search_path = public, pg_temp pin that later hardening gave it), restated
-- here so the repository and the live project converge. Idempotent: a database that
-- already has them is unchanged. Live ins_policies had no rows when this was
-- written, so adding the check cannot fail on existing data.
-- =====================================================================

alter table public.ins_policies drop constraint if exists ins_policies_status_check;
alter table public.ins_policies add constraint ins_policies_status_check
  check (status in ('draft', 'pending_approval', 'approved', 'rejected',
                    'active', 'renewed', 'reversed', 'cancelled'));

create or replace function public.ins_policy_bind_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if new.status is distinct from old.status
     and new.status = 'active'
     and old.status <> 'approved' then
    raise exception 'INS_NOT_APPROVED: policy % must be approved before binding (status is %)', old.policy_no, old.status;
  end if;
  return new;
end;
$$;

revoke all on function public.ins_policy_bind_guard() from public, anon, authenticated, service_role;