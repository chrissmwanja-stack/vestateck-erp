-- D4e fix-forward: two events written in the same transaction can come back in
-- the wrong order.
--
-- bank_adjustment_history(uuid) sorts on (created_at, id), and created_at is
-- now(), which is the TRANSACTION timestamp: both rows of a single RPC call get
-- the same value, so the tie is broken by a random uuid. Found by the first real
-- run of test_d4e_bank_adjustments_completion.sql, which expects
-- ['created','approved'] and got ['approved','created'].
--
-- The panel renders the history in the order it is returned, so a reader could
-- be shown "approved" above "created". Order by the sequence-assigned column
-- instead: id is a uuid, not a sequence, so the honest ordering is by
-- created_at and then by the insertion order the heap records -- which for rows
-- with identical timestamps is exactly what ctid gives. That is stable and
-- needs no schema change.
--
-- Fix forward (rule 9): 20261119210000 is not edited. Same signature and grants.

create or replace function public.bank_adjustment_history(p_adjustment_id uuid)
returns table (
  event       text,
  actor_id    uuid,
  actor_name  text,
  note        text,
  created_at  timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null or not public.is_finance_team_member(null) then
    raise exception 'not authorized: reading bank adjustment history requires the finance role' using errcode = '42501';
  end if;
  if not exists (select 1 from public.bank_adjustments a
                  where a.id = p_adjustment_id and a.tenant_id = v_tenant) then
    raise exception 'ADJ_NOT_FOUND: adjustment % not found', p_adjustment_id using errcode = '42501';
  end if;

  return query
    select e.event, e.actor_id,
           coalesce(e.actor_name, u.name, 'Unknown user'),
           e.note, e.created_at
      from public.bank_adjustment_events e
      left join public.app_users u on u.id = e.actor_id
     where e.tenant_id = v_tenant and e.adjustment_id = p_adjustment_id
     -- created_at is the transaction timestamp, so events written by one call
     -- share it; ctid keeps them in the order they were inserted.
     order by e.created_at, e.ctid;
end;
$function$;

revoke all on function public.bank_adjustment_history(uuid) from public, anon;
grant execute on function public.bank_adjustment_history(uuid) to authenticated;
