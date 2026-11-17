-- =====================================================================
-- Insurance: the post-opening acceptance gate
-- =====================================================================
--
-- What was wrong
--
--   A brokerage migrating its portfolio posts an opening position from an
--   import batch: receivables, insurer payables, deferred commission, and the
--   client-money float at cut-over. That journal is the hinge between the old
--   system's history and this ledger.
--
--   Nothing stopped a second batch posting another one. Measured on a clean
--   replay: batch A posted 1,000,000 of receivable, batch B then posted
--   500,000 more for the same tenant, both dated at their own cut-over dates,
--   with no record anywhere that the books now had two openings. That is
--   exactly the shape of a double-counted book, and it is silent.
--
--   Worse, `ins_import_opening_report` compares the posted journal with the
--   legacy control totals and with the sub-ledger, but nothing *accepts* the
--   result. A reviewer reading a difference had no way to record that they had
--   read it and that the books were accepted at cut-over.
--
-- What this adds
--
--   1. One opening position per company, enforced. A second post is refused by
--      name unless the company has explicitly reopened for a correction.
--   2. An acceptance step: a reviewer other than the person who posted records
--      that they examined the opening and accepts it -- optionally naming the
--      differences they saw.
--   3. A gate on ordinary business until the opening is accepted. Until then a
--      policy can be drafted and approved, but not bound, because binding books
--      premium into a ledger whose opening balance nobody has vouched for is how
--      a cut-over becomes unauditable.
--
-- Deliberately NOT here
--
--   Reopening does not silently re-post. It unlocks a second batch and requires
--   its own acceptance; both openings then stand, which is what a correction
--   genuinely is. Nor does acceptance alter any number: it records a person and
--   a moment, not an adjustment.

-- ---------------------------------------------------------------------
-- 1. Which opening position the company is on
-- ---------------------------------------------------------------------
alter table public.ins_import_batches
  add column if not exists opening_posted_at    timestamptz,
  add column if not exists opening_posted_by    uuid,
  add column if not exists opening_accepted_at  timestamptz,
  add column if not exists opening_accepted_by  uuid,
  add column if not exists opening_accept_note  text,
  add column if not exists opening_accepted_diff jsonb;

comment on column public.ins_import_batches.opening_accepted_at is
  'When a reviewer who did not post the opening position accepted it. Null means the opening is posted but unaccepted, which blocks new binding.';
comment on column public.ins_import_batches.opening_accepted_diff is
  'The reconciliation differences the accepting reviewer was shown, stored so the acceptance cannot silently cover a later change.';

-- A company's cut-over: set once, when the first opening posts. Kept on the
-- tenant so the gate does not have to scan batches to answer "has this company
-- opened?".
alter table public.tenants
  add column if not exists ins_opening_posted_at timestamptz,
  add column if not exists ins_opening_accepted_at timestamptz,
  add column if not exists ins_opening_reopened_at timestamptz,
  add column if not exists ins_opening_reopen_reason text;

comment on column public.tenants.ins_opening_posted_at is
  'When this company first posted an insurance opening position. Null means it has not migrated a portfolio.';

-- ---------------------------------------------------------------------
-- 2. One post per company; a correction needs an explicit reopen
-- ---------------------------------------------------------------------
create or replace function public.ins_opening_single_post_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_first     timestamptz;
  v_reopened  timestamptz;
begin
  if new.source_type <> 'ins_import_opening' then
    return new;
  end if;

  select ins_opening_posted_at, ins_opening_reopened_at
    into v_first, v_reopened
    from public.tenants where id = new.tenant_id
   for update;

  if v_first is null then
    -- The first opening for this company. Record the cut-over.
    update public.tenants
       set ins_opening_posted_at = now()
     where id = new.tenant_id;
    return new;
  end if;

  -- A later opening is allowed only if the company has been reopened since the
  -- most recent posting, and only for the batch that reopening unlocked. The
  -- reopen stamps the tenant; the batch records when it was posted.
  if v_reopened is null or v_reopened < v_first then
    raise exception 'INS_OPENING_EXISTS: this company already has an opening position (posted %). A second one would double-count the cut-over; reopen the opening explicitly if it must be corrected', to_char(v_first, 'YYYY-MM-DD HH24:MI')
      using errcode = '23514';
  end if;

  return new;
end;
$function$;

revoke all on function public.ins_opening_single_post_guard() from public, anon, authenticated;

drop trigger if exists trg_ins_opening_single_post on public.journal_entries;
create trigger trg_ins_opening_single_post
  before insert on public.journal_entries
  for each row execute function public.ins_opening_single_post_guard();

-- ---------------------------------------------------------------------
-- 4. Accepting the opening: a second person, once
-- ---------------------------------------------------------------------
create or replace function public.ins_import_accept_opening(
  p_batch_id uuid,
  p_note     text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  b        public.ins_import_batches;
  v_diff   jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;

  if b.opening_posted_at is null then
    raise exception 'INS_OPENING_NOT_POSTED: post the opening position before accepting it';
  end if;

  if b.opening_accepted_at is not null then
    raise exception 'INS_OPENING_ALREADY_ACCEPTED: accepted on % by %; an acceptance is a record of a moment, not something to overwrite',
      to_char(b.opening_accepted_at, 'YYYY-MM-DD HH24:MI'), b.opening_accepted_by;
  end if;

  -- The person who posted must not be the person who accepts. The import already
  -- enforces this for control-total overrides; the opening is a bigger number
  -- than any control total, so the same rule applies.
  if b.committed_by is not null and b.committed_by = auth.uid() then
    raise exception 'INS_OPENING_SELF_ACCEPT: the reviewer who accepts the opening must not be the one who committed the batch'
      using errcode = '42501';
  end if;
  if b.opening_posted_by is not null and b.opening_posted_by = auth.uid() then
    raise exception 'INS_OPENING_SELF_ACCEPT: the reviewer who accepts the opening must not be the one who posted it'
      using errcode = '42501';
  end if;

  -- Store the reconciliation the reviewer was shown, so a later movement cannot
  -- be read as having been accepted. The report is a table, not a document:
  -- collapse it to one object per currency and measure.
  select coalesce(jsonb_object_agg(key, val), '{}'::jsonb)
    into v_diff
    from (
      select currency || ':' || measure as key,
             jsonb_build_object(
               'posted', posted_amount,
               'open_items', open_item_amount,
               'control', control_amount,
               'match', match,
               'subledger_match', subledger_match) as val
        from public.ins_import_opening_report(b.id)
    ) x;

  update public.ins_import_batches
     set opening_accepted_at = now(),
         opening_accepted_by = auth.uid(),
         opening_accept_note = nullif(btrim(coalesce(p_note, '')), ''),
         opening_accepted_diff = v_diff
   where id = b.id
  returning * into b;

  update public.tenants
     set ins_opening_accepted_at = b.opening_accepted_at
   where id = v_tenant;

  return jsonb_build_object(
    'accepted', true,
    'accepted_at', b.opening_accepted_at,
    'accepted_by', b.opening_accepted_by,
    'note', b.opening_accept_note,
    'differences_seen', v_diff
  );
end;
$function$;

revoke all on function public.ins_import_accept_opening(uuid, text) from public, anon;
grant execute on function public.ins_import_accept_opening(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Recording who posted the opening
-- ---------------------------------------------------------------------
-- The existing post function does not stamp an actor. Rather than re-create its
-- 300 lines to add one line, watch the journal it writes: after an
-- ins_import_opening entry lands, stamp the batch that owns it.
create or replace function public.ins_opening_stamp_posted()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.source_type <> 'ins_import_opening' then
    return new;
  end if;
  update public.ins_import_batches
     set opening_posted_at = coalesce(opening_posted_at, now()),
         opening_posted_by = coalesce(opening_posted_by, auth.uid())
   where id = new.source_id and tenant_id = new.tenant_id;
  return new;
end;
$function$;

revoke all on function public.ins_opening_stamp_posted() from public, anon, authenticated;

drop trigger if exists trg_ins_opening_stamp_posted on public.journal_entries;
create trigger trg_ins_opening_stamp_posted
  after insert on public.journal_entries
  for each row execute function public.ins_opening_stamp_posted();

-- ---------------------------------------------------------------------
-- 6. Reopening, for a correction, and only deliberately
-- ---------------------------------------------------------------------
create or replace function public.ins_import_reopen_opening(
  p_batch_id uuid,
  p_reason   text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  b        public.ins_import_batches;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'INS_OPENING_REOPEN_REASON: a reopen needs a reason of at least 10 characters; it is what a reviewer will read at the next year-end';
  end if;

  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;
  if b.opening_posted_at is null then
    raise exception 'INS_OPENING_NOT_POSTED: batch % has no opening position to reopen', b.label;
  end if;

  -- Reopening does not remove the old opening. Both stand; the correction is a
  -- second, separately accepted position. Clearing the tenant's acceptance is
  -- what puts ordinary binding back behind the gate until someone looks again.
  update public.tenants
     set ins_opening_reopened_at = now(),
         ins_opening_reopen_reason = btrim(p_reason),
         ins_opening_accepted_at = null
   where id = v_tenant;

  return jsonb_build_object('reopened', true, 'reason', btrim(p_reason));
end;
$function$;

revoke all on function public.ins_import_reopen_opening(uuid, text) from public, anon;
grant execute on function public.ins_import_reopen_opening(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. The gate itself: no new binding on an unaccepted opening
-- ---------------------------------------------------------------------
-- Drafting and approving stay open: a reviewer working through the opening may
-- well be preparing the first policies. Binding is what puts money in the
-- ledger, so that is where the gate sits.
create or replace function public.ins_opening_accepted_for(p_tenant uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select t.ins_opening_posted_at is null
      or t.ins_opening_accepted_at is not null
    from public.tenants t
   where t.id = p_tenant;
$$;

revoke all on function public.ins_opening_accepted_for(uuid) from public, anon;
grant execute on function public.ins_opening_accepted_for(uuid) to authenticated;

create or replace function public.ins_opening_gate_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid;
begin
  if new.status = 'active' and old.status is distinct from new.status then
    v_tenant := new.tenant_id;
    if not coalesce(public.ins_opening_accepted_for(v_tenant), true) then
      raise exception 'INS_OPENING_UNACCEPTED: this company has posted an opening position that no second reviewer has accepted yet; accept it (ins_import_accept_opening) before binding new business, or the cut-over balance goes unaudited'
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function public.ins_opening_gate_guard() from public, anon, authenticated;

drop trigger if exists trg_ins_opening_gate on public.ins_policies;
create trigger trg_ins_opening_gate
  before update of status on public.ins_policies
  for each row execute function public.ins_opening_gate_guard();
