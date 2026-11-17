-- =====================================================================
-- Finance A: period close/reopen controls (maker-checker + audit trail)
-- =====================================================================
--
-- WHAT WAS WRONG
--
-- post_journal_entry() already refuses to post into a closed period, and
-- every posting path in the platform funnels through it (verified: of the
-- 40 functions touching journal_entries, only the gateway inserts
-- directly). So the *posting* half of A was already built.
--
-- The hole was in period administration. accounting_periods had:
--
--   grant: DELETE, INSERT, SELECT, UPDATE to authenticated
--   policy accounting_periods_update: is_finance_team_member('finance')
--                                     and tenant_id = get_my_tenant_id()
--   policy accounting_periods_delete: same
--
-- which means any single Finance-role user could reopen a closed period --
-- or delete the period row outright -- with one PostgREST PATCH/DELETE.
-- No second pair of eyes, no audit event, no reason recorded. The admin
-- screen (AccountingPeriodsAdmin.tsx) did exactly that: it sent an UPDATE
-- straight to the table.
--
-- That undermines everything built on top of period control, including the
-- as-at reporting added in 20261117120000: a report is only reproducible if
-- a closed period actually stays closed.
--
-- WHAT THIS DOES
--
--   1. accounting_period_events -- an append-only log of every close,
--      reopen and delete, with actor, reason and before/after status.
--   2. fin_close_accounting_period(id, note)     -- finance, idempotent,
--      writes an event + a platform audit event.
--   3. fin_reopen_accounting_period(id, reason)  -- reason required (>=10
--      chars) and the caller must be a DIFFERENT finance user from the one
--      who closed it (maker-checker). Writes an event + platform event.
--   4. fin_delete_accounting_period(id, reason)  -- refuses if any journal
--      entry falls inside the period; otherwise finance + reason + event.
--   5. fin_period_events(period_id)              -- read the timeline.
--   6. Grants tightened, so the RPCs are the only way in:
--        accounting_periods : UPDATE, DELETE revoked from authenticated/anon
--        journal_entries    : DELETE revoked from authenticated/anon
--        journal_entry_lines: DELETE revoked from authenticated/anon
--
-- WHY ONLY THOSE VERBS
--
--   - accounting_periods keeps INSERT + SELECT because the existing admin
--     screen (and the SQL tests) create periods client-side; INSERT cannot
--     reopen anything, and overlapping periods are already rejected by
--     check_accounting_period_no_overlap + the tenant range unique index.
--   - journal_entries keeps SELECT + INSERT + UPDATE because several
--     existing tests insert journal rows as `authenticated` to exercise the
--     line guards, and prevent_journal_mutation remains the runtime guard
--     for UPDATE. DELETE is revoked so that immutability no longer rests on
--     one trigger alone -- defence in depth, as with period close.
--
-- DELETE on the journal tables is a privilege removal, not a schema
-- removal, so MIGRATION_POLICY allows it (rule: no DROP TABLE / DROP
-- COLUMN). It is safe to apply because nothing in apps/web deletes journal
-- rows: grep for from('journal_entries') / from('journal_entry_lines') in
-- apps/web/src returns no writes at all.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Append-only period event log
-- ---------------------------------------------------------------------
-- period_id is nullable and ON DELETE SET NULL on purpose: a delete event must
-- SURVIVE the deletion of the period it describes. A cascade here would make
-- the audit log vanish exactly when it matters most (caught by the test: the
-- delete event was being removed along with the period). The period's date
-- range is snapshotted onto the event so a delete is still fully described
-- after the row is gone.
create table if not exists accounting_period_events (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  period_id       uuid references accounting_periods(id) on delete set null,
  action          text not null check (action in ('close', 'reopen', 'delete')),
  actor_id        uuid,
  actor_email     text,
  note            text,
  previous_status text,
  new_status      text,
  period_start    date,
  period_end      date,
  created_at      timestamptz not null default now()
);

comment on table accounting_period_events is
  'Append-only audit log of accounting period close/reopen/delete. Written only '
  'by fin_close_accounting_period / fin_reopen_accounting_period / '
  'fin_delete_accounting_period (SECURITY DEFINER); never by clients, so the '
  'record cannot be edited away by the actor it describes. period_id is '
  'ON DELETE SET NULL so a delete event outlives the period; period_start/'
  'period_end snapshot the range so the event stays meaningful.';

create index if not exists accounting_period_events_period_idx
  on accounting_period_events (period_id, created_at desc);
create index if not exists accounting_period_events_tenant_idx
  on accounting_period_events (tenant_id, created_at desc);

alter table accounting_period_events enable row level security;

-- Readable by the tenant's finance team; writable only through the RPCs
-- below (SECURITY DEFINER bypasses RLS as the owner).
drop policy if exists accounting_period_events_select on accounting_period_events;
create policy accounting_period_events_select on accounting_period_events
  for select
  to authenticated
  using (is_finance_team_member(null) and tenant_id = get_my_tenant_id());

-- Deliberately no INSERT/UPDATE/DELETE policies: an event log that its
-- own actors can rewrite is not an audit log.

revoke all on accounting_period_events from anon, authenticated;
grant select on accounting_period_events to authenticated;

-- Every tenant-scoped table in this repo must carry the tenant read-only
-- guard (a suspended / read-only tenant must not be able to write). There is
-- a repo-wide helper for it, and check_live_security_drift.sql fails the
-- build if a new tenant_id table is missing it -- which is how this was
-- caught while writing this migration. Same one-liner the 20261109/20261111
-- migrations used for their new tables.
select public.apply_tenant_read_only_guard();

-- ---------------------------------------------------------------------
-- 2. Close a period
-- ---------------------------------------------------------------------
create or replace function fin_close_accounting_period(
  p_period_id uuid,
  p_note text default null
)
returns accounting_periods
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_p accounting_periods%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to close accounting periods' using errcode = '42501';
  end if;

  select * into v_p from accounting_periods where id = p_period_id for update;
  if not found then
    raise exception 'accounting period not found';
  end if;
  if v_p.tenant_id <> get_my_tenant_id() then
    raise exception 'not authorized for this accounting period' using errcode = '42501';
  end if;

  -- Idempotent: closing an already-closed period is a no-op, not an error.
  if v_p.status = 'closed' then
    return v_p;
  end if;

  update accounting_periods set status = 'closed' where id = p_period_id
  returning * into v_p;

  insert into accounting_period_events
    (tenant_id, period_id, action, actor_id, actor_email, note,
     previous_status, new_status, period_start, period_end)
  values (
    v_p.tenant_id, v_p.id, 'close', auth.uid(),
    (select email from auth.users where id = auth.uid()),
    v_note, 'open', 'closed', v_p.period_start, v_p.period_end
  );

  perform log_platform_event(
    'accounting_period.close', v_p.tenant_id, 'accounting_period', v_p.id::text, v_note,
    jsonb_build_object('status', 'open'),
    jsonb_build_object('status', 'closed', 'period_start', v_p.period_start, 'period_end', v_p.period_end)
  );

  return v_p;
end;
$function$;

comment on function fin_close_accounting_period(uuid, text) is
  'Close an accounting period. Blocks further postings dated inside it. '
  'Idempotent. Finance role required; writes an accounting_period_events row.';

-- ---------------------------------------------------------------------
-- 3. Reopen a period -- maker-checker
-- ---------------------------------------------------------------------
create or replace function fin_reopen_accounting_period(
  p_period_id uuid,
  p_reason text
)
returns accounting_periods
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_p accounting_periods%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_other_reopeners int;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to reopen accounting periods' using errcode = '42501';
  end if;

  select * into v_p from accounting_periods where id = p_period_id for update;
  if not found then
    raise exception 'accounting period not found';
  end if;
  if v_p.tenant_id <> get_my_tenant_id() then
    raise exception 'not authorized for this accounting period' using errcode = '42501';
  end if;

  if v_p.status = 'open' then
    return v_p;
  end if;

  -- A reopen is a control event: it needs a stated reason.
  if v_reason is null or length(v_reason) < 10 then
    raise exception 'a reason (at least 10 characters) is required to reopen a closed accounting period';
  end if;

  -- Maker-checker. closed_by is set by stamp_accounting_period_close() when
  -- the period was closed after that trigger existed. Periods closed before
  -- it (closed_by null) cannot be attributed, so they fall through to the
  -- reason requirement rather than being impossible to reopen.
  if v_p.closed_by is not null and v_p.closed_by = auth.uid() then
    raise exception
      'SEGREGATION_OF_DUTIES: a closed accounting period must be reopened by a different finance user than the one who closed it (closed_by = %). Ask another Finance team member to reopen it.',
      v_p.closed_by
      using errcode = '42501';
  end if;

  -- If the person who closed it has since left the finance team, a reopen
  -- would be impossible under the rule above only when they are the caller;
  -- we do not block it, but we do require that at least one other finance
  -- user exists so the control is meaningful.
  select count(*) into v_other_reopeners
  from finance_team_members
  where tenant_id = v_p.tenant_id
    and role = 'finance'
    and user_id <> coalesce(v_p.closed_by, '00000000-0000-0000-0000-000000000000'::uuid);

  if v_other_reopeners = 0 and v_p.closed_by is not null then
    raise exception
      'SEGREGATION_OF_DUTIES: no other finance user exists in this company to reopen this period. Add a second Finance team member first.';
  end if;

  update accounting_periods set status = 'open' where id = p_period_id
  returning * into v_p;

  insert into accounting_period_events
    (tenant_id, period_id, action, actor_id, actor_email, note,
     previous_status, new_status, period_start, period_end)
  values (
    v_p.tenant_id, v_p.id, 'reopen', auth.uid(),
    (select email from auth.users where id = auth.uid()),
    v_reason, 'closed', 'open', v_p.period_start, v_p.period_end
  );

  perform log_platform_event(
    'accounting_period.reopen', v_p.tenant_id, 'accounting_period', v_p.id::text, v_reason,
    jsonb_build_object('status', 'closed', 'closed_by', v_p.closed_by),
    jsonb_build_object('status', 'open', 'period_start', v_p.period_start, 'period_end', v_p.period_end)
  );

  return v_p;
end;
$function$;

comment on function fin_reopen_accounting_period(uuid, text) is
  'Reopen a closed accounting period. Requires a reason and a finance user '
  'different from the one who closed it (maker-checker). Writes an '
  'accounting_period_events row and a platform audit event.';

-- ---------------------------------------------------------------------
-- 4. Delete a period -- only while it is empty
-- ---------------------------------------------------------------------
create or replace function fin_delete_accounting_period(
  p_period_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_p accounting_periods%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_entries int;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to delete accounting periods' using errcode = '42501';
  end if;

  select * into v_p from accounting_periods where id = p_period_id for update;
  if not found then
    raise exception 'accounting period not found';
  end if;
  if v_p.tenant_id <> get_my_tenant_id() then
    raise exception 'not authorized for this accounting period' using errcode = '42501';
  end if;

  if v_reason is null or length(v_reason) < 10 then
    raise exception 'a reason (at least 10 characters) is required to delete an accounting period';
  end if;

  -- Removing a period whose range holds journals would silently make those
  -- entries un-audited by period control. Refuse; the period is real history.
  select count(*) into v_entries
  from journal_entries
  where tenant_id = v_p.tenant_id
    and entry_date between v_p.period_start and v_p.period_end;

  if v_entries > 0 then
    raise exception
      'cannot delete this accounting period: % journal entr%s dated inside it. Leave the period in place -- it is part of the audit trail.',
      v_entries, case when v_entries = 1 then 'y is' else 'ies are' end;
  end if;

  insert into accounting_period_events
    (tenant_id, period_id, action, actor_id, actor_email, note,
     previous_status, new_status, period_start, period_end)
  values (
    v_p.tenant_id, v_p.id, 'delete', auth.uid(),
    (select email from auth.users where id = auth.uid()),
    v_reason, v_p.status, null, v_p.period_start, v_p.period_end
  );

  perform log_platform_event(
    'accounting_period.delete', v_p.tenant_id, 'accounting_period', v_p.id::text, v_reason,
    jsonb_build_object('status', v_p.status, 'period_start', v_p.period_start, 'period_end', v_p.period_end),
    null
  );

  delete from accounting_periods where id = p_period_id;
end;
$function$;

comment on function fin_delete_accounting_period(uuid, text) is
  'Delete an accounting period that has no journal entries dated inside it. '
  'Refuses otherwise. Finance role and a reason required; writes an event.';

-- ---------------------------------------------------------------------
-- 5. Read the timeline
-- ---------------------------------------------------------------------
create or replace function fin_period_events(p_period_id uuid)
returns setof accounting_period_events
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid;
begin
  if not is_finance_team_member(null) then
    raise exception 'not authorized to read accounting period history' using errcode = '42501';
  end if;

  select tenant_id into v_tenant from accounting_periods where id = p_period_id;
  if v_tenant is null then
    return;
  end if;
  if v_tenant <> get_my_tenant_id() then
    raise exception 'not authorized for this accounting period' using errcode = '42501';
  end if;

  return query
    select * from accounting_period_events
    where period_id = p_period_id
    order by created_at desc;
end;
$function$;

revoke all on function fin_close_accounting_period(uuid, text) from public;
revoke all on function fin_reopen_accounting_period(uuid, text) from public;
revoke all on function fin_delete_accounting_period(uuid, text) from public;
revoke all on function fin_period_events(uuid) from public;
grant execute on function fin_close_accounting_period(uuid, text) to authenticated, service_role;
grant execute on function fin_reopen_accounting_period(uuid, text) to authenticated, service_role;
grant execute on function fin_delete_accounting_period(uuid, text) to authenticated, service_role;
grant execute on function fin_period_events(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. Tighten grants: the RPCs become the only way to change a period
-- ---------------------------------------------------------------------
-- Reopening a closed period is now a maker-checked, logged act rather than
-- a PATCH. INSERT stays so the admin screen can still create periods.
revoke update, delete on accounting_periods from anon, authenticated;

-- Defence in depth for the journal: immutability no longer rests on
-- prevent_journal_mutation alone. Nothing in apps/web writes or deletes
-- journal rows directly; the gateway is SECURITY DEFINER and owner-run.
revoke delete on journal_entries from anon, authenticated;
revoke delete on journal_entry_lines from anon, authenticated;

commit;
