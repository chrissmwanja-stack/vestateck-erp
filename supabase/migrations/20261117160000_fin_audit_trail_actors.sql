-- =====================================================================
-- Finance B: the financial audit trail
-- =====================================================================
--
-- The question this answers: for any money movement, who set it going, who
-- approved it, who posted it, who reversed it, what did it post, and what
-- paper backs it -- in one place, in order.
--
-- Recon findings that shaped it
-- ---------------------------------------------------------------------
-- 1. `journal_entries.posted_by` already records the poster, and the void
--    columns record who reversed. Those stay the source of truth for those
--    two facts; they are not duplicated here.
-- 2. `approval_actions` already records approval decisions. An earlier note
--    in this project claimed invoice approvals were unrecordable. **That is
--    wrong.** Verified on a live probe: `record_invoice_approval_decision` is
--    SECURITY DEFINER, writes the row, and a different reviewer's approval
--    persists with `effective_user_id` naming them. `approval_actions` also
--    has SELECT-only RLS, so a direct forged INSERT is denied (42501) and a
--    direct UPDATE/DELETE hits 0 rows. No fix needed; nothing to invent.
-- 3. What was genuinely missing:
--      a. No journal entry ever recorded **who initiated** it.
--      b. A reversal's link back to its original existed only in a
--         transaction-local GUC (`fin.reversal_of`) and in a description
--         string. Never persisted, so it could not be reported.
--      c. Nothing joined any of this to the document, the supporting
--         documents, or the period.
--
-- What this migration adds
-- ---------------------------------------------------------------------
-- `fin_transaction_actors` -- one row per (journal entry, role). It is the
-- spine the user asked for, and it is what makes the reversal linkage real.
--
--   role ∈ initiated | approved | posted | reversed
--
-- Actor semantics (decided): every row names the **effective** identity, i.e.
-- `effective_user_id()` = impersonated user when a platform admin is
-- impersonating, else `auth.uid()`. That is the identity whose authority
-- actually counted -- the same one `is_finance_team_member()` and the
-- segregation-of-duties checks use. For approvals, the raw session user and
-- the impersonation session are kept alongside, so an impersonated approval
-- is visible as such rather than hidden.
--
-- Postings are captured at the choke point: `post_journal_entry` is what
-- every module posts through, so instrumenting it covers all of them,
-- including the reversal posts that void paths make. No per-module wiring.
--
-- Backfill
-- ---------------------------------------------------------------------
-- `posted` and `reversed` are backfilled from data that already exists
-- (`posted_by`, `voided_by`), because it would be strange for the trail to
-- claim nobody posted a 2024 entry. `initiated` and `approved` are NOT
-- backfilled: neither fact was ever recorded, and inventing them is exactly
-- the kind of guess this whole exercise exists to remove. `fin_audit_trail`
-- reports which journal entries have no initiator, so the gap is visible.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The spine
-- ---------------------------------------------------------------------
create table if not exists fin_transaction_actors (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants (id) on delete cascade,
  journal_entry_id uuid not null references journal_entries (id) on delete cascade,
  role          text not null,
  actor_id      uuid references app_users (id),
  -- Who the session literally was, and under which impersonation session, when
  -- that differs from actor_id. Null when they are the same.
  acted_by      uuid references app_users (id),
  impersonation_session_id uuid,
  acted_at      timestamptz not null default now(),
  note          text,
  -- The other side of a reversal: on a reversal row, the entry it reverses.
  related_journal_entry_id uuid references journal_entries (id) on delete set null,
  constraint fin_transaction_actors_role_check
    check (role in ('initiated', 'approved', 'posted', 'reversed')),
  -- One holder per role per entry. An entry is posted once, reversed once.
  constraint fin_transaction_actors_once
    unique (journal_entry_id, role)
);

comment on table fin_transaction_actors is
  'Who initiated, approved, posted and reversed each journal entry. One row per role.';
comment on column fin_transaction_actors.actor_id is
  'The effective identity: the impersonated user when a platform admin is impersonating.';
comment on column fin_transaction_actors.related_journal_entry_id is
  'For a reversal row: the journal entry being reversed.';
comment on column fin_transaction_actors.acted_by is
  'The raw session user, set only when it differs from actor_id (impersonation).';

create index if not exists fin_transaction_actors_tenant_idx
  on fin_transaction_actors (tenant_id, acted_at desc);
create index if not exists fin_transaction_actors_actor_idx
  on fin_transaction_actors (tenant_id, actor_id);

-- Append-only, like the rest of the financial record. Enforced by trigger
-- rather than by policy alone, because a policy gap is silent.
create or replace function fin_transaction_actors_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  raise exception 'AUDIT_IMMUTABLE: the financial audit trail cannot be edited or deleted';
end;
$function$;

drop trigger if exists trg_fin_transaction_actors_immutable on fin_transaction_actors;
create trigger trg_fin_transaction_actors_immutable
  before update or delete on fin_transaction_actors
  for each row execute function fin_transaction_actors_guard();

-- Every tenant-scoped table needs the read-only guard (see
-- check_live_security_drift.sql).
drop trigger if exists tenant_read_only_guard on fin_transaction_actors;
create trigger tenant_read_only_guard
  before insert or update or delete on fin_transaction_actors
  for each row execute function tenant_read_only_guard();

alter table fin_transaction_actors enable row level security;

drop policy if exists fin_transaction_actors_select on fin_transaction_actors;
create policy fin_transaction_actors_select on fin_transaction_actors
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null));

-- No INSERT/UPDATE/DELETE policy on purpose: only SECURITY DEFINER functions
-- below write here. Tighten the grants to match.
revoke insert, update, delete, truncate on fin_transaction_actors from authenticated, anon;
grant select on fin_transaction_actors to authenticated;
grant all on fin_transaction_actors to service_role;

-- ---------------------------------------------------------------------
-- 2. Where the reversal link comes from
-- ---------------------------------------------------------------------
-- A reversal is recognisable two ways, and both are used because the void
-- paths differ:
--   * post_journal_entry posts the reversal while `fin.reversal_of` still
--     names the original (void_journal_entry, the FX revaluation void, the
--     credit-note void, the insurance voids).
--   * the settlement void clears that GUC and then posts with
--     source_type = 'fin_settlement_void', so the original is the settlement's
--     own journal (settlements are immutable, so there is exactly one).
create or replace function fin_audit_reversal_of(
  p_tenant_id uuid,
  p_source_type text,
  p_source_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_orig uuid := nullif(current_setting('fin.reversal_of', true), '')::uuid;
begin
  if v_orig is not null then
    return v_orig;
  end if;
  if p_source_type = 'fin_settlement_void' and p_source_id is not null then
    select s.journal_entry_id into v_orig
      from fin_settlements s
     where s.id = p_source_id and s.tenant_id = p_tenant_id;
    return v_orig;
  end if;
  return null;
end;
$function$;

revoke all on function fin_audit_reversal_of(uuid, text, uuid) from public;
grant execute on function fin_audit_reversal_of(uuid, text, uuid) to service_role;

-- ---------------------------------------------------------------------
-- 3. The recorder
-- ---------------------------------------------------------------------
-- SECURITY DEFINER and not granted to `authenticated`: called only from
-- post_journal_entry and fin_audit_link_document.
create or replace function fin_audit_record(
  p_tenant_id uuid,
  p_journal_entry_id uuid,
  p_role text,
  p_note text default null,
  p_related_journal_entry_id uuid default null
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_effective uuid := effective_user_id();
  v_raw       uuid := auth.uid();
  v_session   uuid;
begin
  if p_role not in ('initiated', 'approved', 'posted', 'reversed') then
    raise exception 'AUDIT_ROLE: unknown role %', p_role;
  end if;

  if v_raw is not null and v_effective is distinct from v_raw then
    select s.id into v_session
      from impersonation_sessions s
     where s.platform_admin_id = v_raw
       and s.ended_at is null
       and s.expires_at > now()
     order by s.started_at desc
     limit 1;
  end if;

  insert into fin_transaction_actors
    (tenant_id, journal_entry_id, role, actor_id, acted_by, impersonation_session_id, note,
     related_journal_entry_id)
  values
    (p_tenant_id, p_journal_entry_id, p_role, v_effective,
     case when v_effective is distinct from v_raw then v_raw end,
     v_session, p_note, p_related_journal_entry_id)
  on conflict (journal_entry_id, role) do nothing;
end;
$function$;

revoke all on function fin_audit_record(uuid, uuid, text, text, uuid) from public;
grant execute on function fin_audit_record(uuid, uuid, text, text, uuid) to service_role;

-- ---------------------------------------------------------------------
-- 4. The hook: every posting records its poster, and reversals their link
-- ---------------------------------------------------------------------
-- An AFTER INSERT trigger rather than an edit to post_journal_entry: the
-- function is SECURITY DEFINER with a long body, and I do not want to
-- re-type it here and risk drifting from the original. The trigger runs for
-- every row that reaches journal_entries, whoever inserted it, which is
-- strictly better coverage than a hook on one code path.
--
-- `prevent_journal_mutation` keeps journal_entries rows immutable, so an
-- INSERT is the only way a journal entry comes into existence.
create or replace function trg_fin_audit_journal_actor()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_orig uuid;
begin
  -- The poster. posted_by is the recorded fact; fall back to the effective
  -- identity only if a caller inserted a row without it.
  perform fin_audit_record(
    new.tenant_id, new.id, 'posted',
    case when new.posted_by is null then 'posted without posted_by; actor from session' end
  );

  -- A reversal: link it to what it reverses.
  -- The 'reversed' row lives on the REVERSAL entry and names the entry it
  -- reverses. (The original is marked void separately; its own operator was
  -- recorded on that entry's 'posted' row and in journal_entries.voided_by.)
  v_orig := fin_audit_reversal_of(new.tenant_id, new.source_type, new.source_id);
  if v_orig is not null and v_orig <> new.id then
    perform fin_audit_record(new.tenant_id, new.id, 'reversed',
      'reversal of ' || v_orig::text, v_orig);
  end if;

  return null;
end;
$function$;

drop trigger if exists trg_fin_audit_journal_actor on journal_entries;
create trigger trg_fin_audit_journal_actor
  after insert on journal_entries
  for each row execute function trg_fin_audit_journal_actor();

-- ---------------------------------------------------------------------
-- 5. The linkage: document <-> journal <-> approval <-> paper
-- ---------------------------------------------------------------------
-- The document a journal entry belongs to is already source_type/source_id.
-- What was missing is the approval that authorised it. Two modules have
-- approval trails; both are joined here.
--
-- This is a function rather than triggers on approval_actions because an
-- approval is recorded *before* the document it approves is posted, so at
-- approval time there is usually no journal entry to attach to yet. Resolving
-- it at read time is both simpler and always current.
create or replace function fin_audit_approvals(p_journal_entry_id uuid)
returns table (
  approver_id   uuid,
  approver_name text,
  decision      text,
  comment       text,
  acted_at      timestamptz,
  acted_by      uuid,
  on_behalf_of  uuid,
  module        text
)
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
  with je as (
    select j.tenant_id, j.source_type, j.source_id
      from journal_entries j
     where j.id = p_journal_entry_id
       and j.tenant_id = get_my_tenant_id()
  )
  -- Invoice workflow approvals.
  select aa.effective_user_id, u.name, aa.decision, aa.comment, aa.acted_at,
         aa.actor_id, aa.acted_on_behalf_of, 'invoice_approval'::text
    from je
    join approval_actions aa on aa.invoice_request_id = je.source_id
    left join app_users u on u.id = aa.effective_user_id
   where je.source_type = 'supplier_invoice'

  union all
  -- Material request workflow approvals. The journal's source is the request.
  select aa.effective_user_id, u.name, aa.decision, aa.comment, aa.acted_at,
         aa.actor_id, aa.acted_on_behalf_of, 'request_approval'::text
    from je
    join approval_actions aa on aa.request_id = je.source_id
    left join app_users u on u.id = aa.effective_user_id
   where je.source_type not in ('supplier_invoice')
$function$;

revoke all on function fin_audit_approvals(uuid) from public;
grant execute on function fin_audit_approvals(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. The screen's data source
-- ---------------------------------------------------------------------
-- One row per hop, in order, for one document. Deliberately composes the
-- pieces already built rather than duplicating them:
--   * the document spine and the money legs come from fin_trace (item E),
--   * the actors come from fin_transaction_actors,
--   * the approvals from fin_audit_approvals,
--   * the paper from `documents`,
--   * the period state from accounting_periods.
create or replace function fin_audit_trail(p_entity_type text, p_entity_id uuid)
returns table (
  hop          integer,
  stage        text,
  happened_at  timestamptz,
  actor_id     uuid,
  actor_name   text,
  summary      text,
  detail       text,
  journal_id   uuid,
  document_id  uuid,
  document_name text,
  amount       numeric,
  currency     text,
  status       text
)
language plpgsql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_hop      integer := 0;
  v_eff      uuid := effective_user_id();
  r          record;
  r2         record;
  r3         record;
  r4         record;
  v_src      text;
  v_src_id   uuid;
begin
  if p_entity_id is null then
    raise exception 'fin_audit_trail: an entity id is required';
  end if;

  ------------------------------------------------------------------
  -- The spine: document -> PO -> journals -> money -> open items -> ...
  ------------------------------------------------------------------
  for r in
    select t.hop, t.hop_kind, t.reference, t.status, t.amount, t.currency,
           t.journal_id, t.journal_date, t.journal_status, t.actor, t.happened_at, t.detail
      from fin_trace(p_entity_type, p_entity_id) t
     order by t.hop
  loop
    v_hop := v_hop + 1;
    hop := v_hop;
    stage := case r.hop_kind
               when 'document' then 'document'
               when 'purchase_order' then 'purchase order'
               when 'journal' then 'journal'
               when 'cash_bank' then 'payment'
               when 'open_item' then 'open item'
               when 'settlement' then 'settlement'
               when 'bank_match' then 'bank match'
               when 'accounting_period' then 'period'
               else r.hop_kind end;
    happened_at := r.happened_at;
    actor_id := r.actor;
    actor_name := (select u.name from app_users u where u.id = r.actor);
    summary := coalesce(r.reference, r.hop_kind);
    detail := r.detail;
    journal_id := r.journal_id;
    document_id := null;
    document_name := null;
    amount := r.amount;
    currency := r.currency;
    status := coalesce(r.journal_status, r.status);
    return next;

    ------------------------------------------------------------------
    -- Who initiated / approved / posted / reversed this journal entry.
    -- Emitted right after its journal hop, so the trail reads in order.
    ------------------------------------------------------------------
    if r.hop_kind = 'journal' and r.journal_id is not null then
      for r2 in
        select fa.role, fa.actor_id, u.name, fa.acted_at, fa.note, fa.acted_by
          from fin_transaction_actors fa
          left join app_users u on u.id = fa.actor_id
         where fa.journal_entry_id = r.journal_id
         order by case fa.role when 'initiated' then 1 when 'approved' then 2
                               when 'posted' then 3 else 4 end
      loop
        v_hop := v_hop + 1;
        hop := v_hop;
        stage := r2.role;
        happened_at := r2.acted_at;
        actor_id := r2.actor_id;
        actor_name := r2.name;
        summary := initcap(r2.role) || ' by ' || coalesce(r2.name, 'an unidentified user');
        detail := case when r2.acted_by is not null and r2.acted_by <> r2.actor_id
                       then 'session user ' || r2.acted_by::text || ' acting as the named user'
                       else r2.note end;
        journal_id := r.journal_id;
        document_id := null; document_name := null;
        amount := null; currency := null;
        status := r2.role;
        return next;
      end loop;

      ------------------------------------------------------------------
      -- The approvals that authorised the underlying document.
      ------------------------------------------------------------------
      for r3 in select * from fin_audit_approvals(r.journal_id) loop
        v_hop := v_hop + 1;
        hop := v_hop;
        stage := 'approval';
        happened_at := r3.acted_at;
        actor_id := r3.approver_id;
        actor_name := r3.approver_name;
        summary := initcap(r3.decision) || ' by ' || coalesce(r3.approver_name, 'an approver');
        detail := concat_ws(' · ', r3.module, r3.comment,
                            case when r3.acted_by is not null and r3.acted_by <> r3.approver_id
                                 then 'acted by ' || r3.acted_by::text end,
                            case when r3.on_behalf_of is not null
                                 then 'on behalf of ' || r3.on_behalf_of::text end);
        journal_id := r.journal_id;
        document_id := null; document_name := null;
        amount := null; currency := null;
        status := r3.decision;
        return next;
      end loop;

      ------------------------------------------------------------------
      -- The paper behind it.
      ------------------------------------------------------------------
      select je.source_type, je.source_id into v_src, v_src_id
        from journal_entries je where je.id = r.journal_id;

      for r4 in
        select d.id, coalesce(d.file_name, d.doc_kind) as name, d.doc_kind, d.created_at
          from documents d
         where d.tenant_id = get_my_tenant_id()
           and ((d.entity_type = p_entity_type and d.entity_id = p_entity_id)
                or (d.entity_type = v_src and d.entity_id = v_src_id))
         order by d.created_at
      loop
        v_hop := v_hop + 1;
        hop := v_hop;
        stage := 'supporting document';
        happened_at := r4.created_at;
        actor_id := v_eff;
        actor_name := null;
        summary := r4.name;
        detail := r4.doc_kind;
        journal_id := r.journal_id;
        document_id := r4.id;
        document_name := r4.name;
        amount := null; currency := null;
        status := 'attached';
        return next;
      end loop;
    end if;
  end loop;

  if v_hop = 0 then
    raise exception 'fin_audit_trail: nothing to report for % %', p_entity_type, p_entity_id;
  end if;
end;
$function$;

revoke all on function fin_audit_trail(text, uuid) from public;
grant execute on function fin_audit_trail(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 7. Linking an initiator
-- ---------------------------------------------------------------------
-- Initiation is not journal-derived: the person who raised the invoice or
-- the request is not necessarily who posted it. The creating tables hold the
-- fact (`invoice_requests.requester_id`, `requests.requester_id`). This
-- function records it once the journal exists, and is idempotent so it can be
-- called from any path that knows both.
create or replace function fin_audit_link_initiator(
  p_journal_entry_id uuid,
  p_initiator_id uuid,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid;
begin
  select tenant_id into v_tenant from journal_entries where id = p_journal_entry_id;
  if v_tenant is null then
    raise exception 'fin_audit_link_initiator: journal entry % not found', p_journal_entry_id;
  end if;
  if auth.uid() is not null and v_tenant is distinct from get_my_tenant_id() then
    raise exception 'not authorized for this journal entry' using errcode = '42501';
  end if;
  if p_initiator_id is not null
     and not exists (select 1 from app_users u where u.id = p_initiator_id and u.tenant_id = v_tenant) then
    raise exception 'fin_audit_link_initiator: % is not a member of this company', p_initiator_id;
  end if;

  insert into fin_transaction_actors (tenant_id, journal_entry_id, role, actor_id, note)
  values (v_tenant, p_journal_entry_id, 'initiated', p_initiator_id, p_note)
  on conflict (journal_entry_id, role) do nothing;
end;
$function$;

revoke all on function fin_audit_link_initiator(uuid, uuid, text) from public;
grant execute on function fin_audit_link_initiator(uuid, uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 8. Completeness: which postings have no initiator on record
-- ---------------------------------------------------------------------
create or replace function fin_audit_gaps(p_tenant_id uuid default null)
returns table (
  journal_entry_id uuid,
  source_type      text,
  entry_date       date,
  description      text,
  gap              text
)
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
  with t as (select coalesce(p_tenant_id, get_my_tenant_id()) as tenant_id)
  select je.id, je.source_type, je.entry_date, je.description,
         'no initiator recorded for this posting'::text
    from journal_entries je, t
   where je.tenant_id = t.tenant_id
     and not exists (
       select 1 from fin_transaction_actors fa
        where fa.journal_entry_id = je.id and fa.role = 'initiated'
     )
  union all
  select je.id, je.source_type, je.entry_date, je.description,
         'reversal is not linked back to the entry it reverses'::text
    from journal_entries je
    join t on je.tenant_id = t.tenant_id
    join fin_transaction_actors fa
      on fa.journal_entry_id = je.id and fa.role = 'reversed'
   where fa.related_journal_entry_id is null
$function$;

revoke all on function fin_audit_gaps(uuid) from public;
grant execute on function fin_audit_gaps(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 9. Backfill the two roles that really were recorded
-- ---------------------------------------------------------------------
insert into fin_transaction_actors (tenant_id, journal_entry_id, role, actor_id, acted_at, note)
select je.tenant_id, je.id, 'posted', je.posted_by, je.created_at,
       'backfilled from journal_entries.posted_by'
  from journal_entries je
 where je.posted_by is not null
on conflict (journal_entry_id, role) do nothing;

-- Reversal rows: the historical link exists only in the description that
-- void_journal_entry wrote ('Reversal of <uuid> — <reason>'), which is the
-- very weakness this table removes. Parse it once so old entries get a real
-- link; from now on the trigger records it directly.
insert into fin_transaction_actors
  (tenant_id, journal_entry_id, role, actor_id, acted_at, note, related_journal_entry_id)
select rev.tenant_id, rev.id, 'reversed', rev.posted_by, rev.created_at,
       'backfilled by parsing the reversal description',
       orig.id
  from journal_entries rev
  join journal_entries orig
    on orig.tenant_id = rev.tenant_id
   and rev.description like 'Reversal of ' || orig.id::text || '%'
on conflict (journal_entry_id, role) do nothing;
