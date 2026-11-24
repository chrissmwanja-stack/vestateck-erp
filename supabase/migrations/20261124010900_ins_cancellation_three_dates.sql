-- =====================================================================
-- The three cancellation dates
-- Accountant pack v2, B4; pack section 8
-- =====================================================================
-- The pack requires a cancellation to record three dates, separately:
--
--   request date            when the client (or someone) asked for it
--   effective date          when cover stops -- the COVERAGE date
--   financial settlement date  when the money actually settles -- the POSTING date
--
-- and requires evidence before an effective date can be backdated.
--
-- WHAT THIS UNCOVERS RATHER THAN INVENTS
--
-- Two of the three already exist, under other names:
--
--   proposed_at   the moment the cancellation was first entered. It is the request
--                 date in all but name and is left exactly where it is.
--   posting_date  set by ins_decide_policy_cancellation to ins_local_today() when the
--                 approval posts, and already used as the posting date everywhere.
--
-- The effective date is ins_policy_cancellations.effective_date, and it is the one
-- that carries the risk: today the only check on it is "not in the future". A
-- cancellation backdated six months does not merely mis-state the coverage -- it
-- feeds ins_preview_policy_cancellation, which pro-rates the return premium off that
-- date. A backdated effective date silently changes the amount of money that moves.
-- That is why it needs evidence and why it is checked here.
--
-- So this migration adds ONE column (the settlement date) and the evidence rule. It
-- does not restate the other two dates, because a second source of truth for the same
-- fact is a bug waiting to diverge.
--
-- WHY post_journal_entry IS NOT RECREATED
--
-- The obvious way to make a cancellation post to the settlement period is to pin the
-- accounting date inside post_journal_entry to the cancellation's settlement date.
-- That function is the posting path for every module on the platform; a change there
-- has a blast radius no migration should have. Instead the settlement date is
-- DERIVED from the data that already proves it, and the derived value is checked
-- against the stored one when a cancellation posts. See section 3.

-- ---------------------------------------------------------------------
-- 1. The settlement date, and why it is not just posting_date
-- ---------------------------------------------------------------------
-- posting_date is fixed at the moment of approval. The settlement date is the date
-- the cancellation financially settled, which in a brokerage is normally the same day
-- but need not be: a cancellation approved on the 30th whose refund clears on the
-- 2nd settles in the next period. Keeping its own column means the gap is visible
-- instead of being flattened into the approval date.
alter table ins_policy_cancellations
  add column if not exists settlement_date date;

comment on column ins_policy_cancellations.settlement_date is
  'The date the cancellation financially settled -- the POSTING period. Distinct from effective_date (when cover stops) and from proposed_at (when it was requested). Set at posting; may differ from posting_date when the refunds and recoveries clear in a later period. Written only by ins_settlement_date() / ins_set_cancellation_settlement_date().';

-- ---------------------------------------------------------------------
-- 2. Evidence for a backdated effective date
-- ---------------------------------------------------------------------
create table if not exists ins_cancellation_date_evidence (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
<<<<<<< ours
<<<<<<< ours
  cancellation_id   uuid not null references ins_policy_cancellations(id) on delete cascade,
  -- Which of the three dates this evidence is about. Only the effective date can be
  -- backdated, but recording the subject means the table stays honest if that changes.
  about_date        text not null default 'effective' check (about_date in ('effective', 'settlement')),
  the_date          date not null,
=======
=======
>>>>>>> theirs
  -- nullable on purpose: see the "why the evidence may arrive first" note under the
  -- table. Evidence is an INPUT to a backdated submission, so at the moment it is
  -- recorded the proposal it will support does not exist yet.
  cancellation_id   uuid references ins_policy_cancellations(id) on delete cascade,
  -- Set only while the evidence is unattached: the proposal it was captured for.
  -- Cleared when a submission consumes it. Two submissions can never share a key,
  -- because the key IS the proposal's request key.
  request_key       uuid,
  -- Which of the three dates this evidence is about. Only the effective date can be
  -- backdated, but recording the subject means the table stays honest if that changes.
  about_date        text not null default 'effective' check (about_date in ('effective', 'settlement')),
  -- null only while the evidence is unattached: the effective date it is evidence
  -- about is not fixed until the proposal it supports is submitted. Filled from the
  -- proposal at that moment, so the two can never disagree.
  the_date          date,
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
  -- What the evidence IS, in the words of the person relying on it: a dated client
  -- instruction, an insurer cancellation notice, a registered letter. Free text is
  -- deliberate -- prescribing a vocabulary would invent a filing system the company
  -- may not have.
  evidence_kind     text not null check (length(btrim(evidence_kind)) between 3 and 120),
  evidence_ref      text not null check (length(btrim(evidence_ref)) between 3 and 240),
  evidence_date     date not null,
  recorded_by       uuid not null references auth.users(id),
  recorded_at       timestamptz not null default now(),
  note              text,
  unique (cancellation_id, about_date)
);
<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
-- One unattached evidence row per (tenant, proposal, subject date). Partial rather
-- than a plain unique constraint: attached rows are governed by the constraint above,
-- and their request_key is cleared, which a plain constraint would not police anyway.
create unique index if not exists ins_cancellation_date_evidence_pending_key
  on ins_cancellation_date_evidence (tenant_id, request_key, about_date)
  where cancellation_id is null and request_key is not null;
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs

comment on table ins_cancellation_date_evidence is
  'Evidence supporting a date on a cancellation. Required before an effective date earlier than the request date can be posted. One row per (cancellation, subject date).';

<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
-- Why the evidence may arrive before the proposal it supports
-- ----------------------------------------------------------
-- The obvious design -- submit first, refuse, then record evidence against the
-- cancellation id -- does not work, and it took a live trace to see it. The refusal
-- is raised inside the submission transaction, so the proposal row is rolled back
-- with it. The message told the person to record evidence against a cancellation that
-- no longer exists, and the retry with the same request key hit a fresh insert and was
-- refused again. A backdated cancellation could never be made at all.
--
-- Evidence is therefore an input to the submission. It is captured against the request
-- key the caller is about to submit with; the submission consumes it and attaches it
-- to the row in the same transaction. The refusal still happens at submit time, as the
-- pack requires, but it now names an action that can actually be taken.

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
alter table ins_cancellation_date_evidence enable row level security;

drop policy if exists ins_cancellation_date_evidence_select on ins_cancellation_date_evidence;
create policy ins_cancellation_date_evidence_select on ins_cancellation_date_evidence
  for select to authenticated
  using (tenant_id = get_my_tenant_id());

-- Written only through ins_record_cancellation_date_evidence(). Each verb is denied
-- separately rather than with FOR ALL, per MIGRATION_POLICY.md rule 4.
drop policy if exists ins_cancellation_date_evidence_insert on ins_cancellation_date_evidence;
create policy ins_cancellation_date_evidence_insert on ins_cancellation_date_evidence
  for insert to authenticated with check (false);

drop policy if exists ins_cancellation_date_evidence_update on ins_cancellation_date_evidence;
create policy ins_cancellation_date_evidence_update on ins_cancellation_date_evidence
  for update to authenticated using (false) with check (false);

drop policy if exists ins_cancellation_date_evidence_delete on ins_cancellation_date_evidence;
create policy ins_cancellation_date_evidence_delete on ins_cancellation_date_evidence
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------
-- 3. Which date a cancellation posts to
-- ---------------------------------------------------------------------
-- The settlement date is not recorded by hand at approval; it is DERIVED from what
-- actually happened, and the stored column (when present) is checked against it
-- rather than trusted. That keeps the three gates apart: the money decides the
-- period, and a person cannot move a cancellation between periods by editing a field.
--
--   no settlement yet            the financial part has not happened, so the date the
--                                cancellation posts to is the approval date
--   cash allocated to it         the LATEST settlement date, because the period is
--                                only complete once the last movement has cleared
--   a stored settlement_date     must agree with the derived one, or it is refused
create or replace function public.ins_cancellation_settlement_date(p_cancellation_id uuid)
returns date
language plpgsql
stable
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_cxl    public.ins_policy_cancellations%rowtype;
  v_cash_sum date;
  v_posted   date;
begin
  select * into v_cxl from public.ins_policy_cancellations
   where id = p_cancellation_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_NOT_FOUND: cancellation';
  end if;

  -- The latest cash movement that actually settled against this cancellation.
  --
  -- A cancellation produces TWO kinds of open item, and they do not share a
  -- source_type or even a source_id:
  --
  --   ins_cancellation_client_refund     source_id = the cancellation id
  --   ins_cancellation_insurer_recovery  source_id = an
  --                                      ins_cancellation_insurer_adjustments row
  --
  -- so matching on source_id alone would silently find only half the money. Both are
  -- matched here.
  --
  -- Each side of a cancellation can settle on its own date: the client refund clears
  -- when the money goes out, the insurer recovery when it comes in. The period is not
  -- complete until the LAST of the two has cleared, so this is a max() across both
  -- sides.
  --
  -- The date used is fin_settlements.settlement_date, which is the date the money
  -- moved. fin_allocations carries no date of its own -- it records which item a
  -- settlement paid, not when -- so there is nothing else to weigh.
  select max(s.settlement_date) into v_cash_sum
    from fin_open_items i
    join fin_allocations a on a.open_item_id = i.id
    join fin_settlements s on s.id = a.settlement_id
   where i.tenant_id = v_tenant
     and s.status <> 'void'
     and (
       (i.source_type = 'ins_cancellation_client_refund'
        and i.source_id = p_cancellation_id)
       or
       (i.source_type = 'ins_cancellation_insurer_recovery'
        and i.source_id in (select adj.id
                              from ins_cancellation_insurer_adjustments adj
                             where adj.cancellation_id = p_cancellation_id
                               and adj.tenant_id = v_tenant))
     );

  if v_cxl.status = 'posted' then
    v_posted := coalesce(v_cash_sum, v_cxl.posting_date);
  else
    -- Not posted yet: the best available statement of when it WILL settle is the
    -- cash that has already moved against it, falling back to today.
    v_posted := coalesce(v_cash_sum, public.ins_local_today());
  end if;

  if v_cxl.settlement_date is not null
     and v_cash_sum is not null
     and v_cxl.settlement_date is distinct from v_cash_sum then
    raise exception 'INS_CANCELLATION_SETTLEMENT_CONFLICT: cancellation % is recorded as settling on % but its cash settled on %. The money decides which period a cancellation falls in; correct the cash or record the reason before proceeding.',
      coalesce(v_cxl.cancellation_no, v_cxl.id::text), v_cxl.settlement_date, v_cash_sum;
  end if;

  return v_posted;
end $$;

revoke all on function public.ins_cancellation_settlement_date(uuid) from public, anon;
grant execute on function public.ins_cancellation_settlement_date(uuid) to authenticated;

-- The three dates, side by side, for a screen or a report. One call, so nobody has to
-- remember which column is which -- which is the whole point of B4.
create or replace function public.ins_cancellation_dates(p_cancellation_id uuid)
returns table (
  request_date    date,
  effective_date  date,
  settlement_date date,
  effective_is_backdated boolean,
  evidence_held   boolean
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_cxl public.ins_policy_cancellations%rowtype;
begin
  select * into v_cxl from public.ins_policy_cancellations
   where id = p_cancellation_id and tenant_id = public.get_my_tenant_id();
  if not found then
    raise exception 'INS_NOT_FOUND: cancellation';
  end if;

  return query
  select (v_cxl.proposed_at at time zone 'Africa/Kampala')::date,
         v_cxl.effective_date,
         public.ins_cancellation_settlement_date(v_cxl.id),
         v_cxl.effective_date < (v_cxl.proposed_at at time zone 'Africa/Kampala')::date,
         exists (select 1 from public.ins_cancellation_date_evidence e
                  where e.cancellation_id = v_cxl.id and e.about_date = 'effective');
end $$;

revoke all on function public.ins_cancellation_dates(uuid) from public, anon;
grant execute on function public.ins_cancellation_dates(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Recording evidence
-- ---------------------------------------------------------------------
create or replace function public.ins_record_cancellation_date_evidence(
  p_cancellation_id uuid,
  p_evidence_kind text,
  p_evidence_ref text,
  p_evidence_date date,
<<<<<<< ours
<<<<<<< ours
  p_note text default null
=======
=======
>>>>>>> theirs
  p_note text default null,
  -- Give this INSTEAD of p_cancellation_id when the evidence is being captured
  -- before a backdated proposal exists -- which is the normal case, because a
  -- backdated submission is refused without it. Pass the same request key you are
  -- about to submit with; the submission consumes the evidence.
  p_request_key uuid default null
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
) returns public.ins_cancellation_date_evidence
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_cxl    public.ins_policy_cancellations%rowtype;
  v_row    public.ins_cancellation_date_evidence%rowtype;
<<<<<<< ours
<<<<<<< ours
=======
  v_the_date date;
>>>>>>> theirs
=======
  v_the_date date;
>>>>>>> theirs
begin
  if not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;

<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
  if p_evidence_date is null or p_evidence_date > public.ins_local_today() then
    raise exception 'INS_CANCELLATION_EVIDENCE_INPUT: the evidence date must be today or earlier';
  end if;

  -- Two shapes, deliberately mutually exclusive: one attaches evidence to a
  -- cancellation that already exists (a non-backdated proposal being corrected, or a
  -- backdated one whose submission carried its evidence), the other captures it for a
  -- proposal that has not been made yet.
  if p_cancellation_id is not null and p_request_key is not null then
    raise exception 'INS_CANCELLATION_EVIDENCE_INPUT: give the cancellation or the pending request key, not both -- evidence recorded against a request key is attached when that proposal is submitted';
  end if;
  if p_cancellation_id is null and p_request_key is null then
    raise exception 'INS_CANCELLATION_EVIDENCE_INPUT: give the cancellation to attach this to, or the request key of the proposal it is for';
  end if;

  if p_request_key is not null then
    -- Captured ahead of the submission. The effective date is not known yet (the
    -- caller has not chosen it or has not committed to it), so it is left null and
    -- filled from the proposal when consumed -- a date recorded here could silently
    -- disagree with the one actually submitted.
    insert into public.ins_cancellation_date_evidence
      (tenant_id, cancellation_id, request_key, about_date, the_date, evidence_kind,
       evidence_ref, evidence_date, recorded_by, note)
    values
      (v_tenant, null, p_request_key, 'effective', null, btrim(p_evidence_kind),
       btrim(p_evidence_ref), p_evidence_date, auth.uid(),
       nullif(btrim(coalesce(p_note, '')), ''))
    on conflict (tenant_id, request_key, about_date) where cancellation_id is null and request_key is not null
      do update
        set evidence_kind = excluded.evidence_kind,
            evidence_ref  = excluded.evidence_ref,
            evidence_date = excluded.evidence_date,
            note          = excluded.note,
            recorded_by   = excluded.recorded_by,
            recorded_at   = now()
      returning * into v_row;
    return v_row;
  end if;

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
  select * into v_cxl from public.ins_policy_cancellations
   where id = p_cancellation_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_NOT_FOUND: cancellation';
  end if;
<<<<<<< ours
<<<<<<< ours

=======
>>>>>>> theirs
=======
>>>>>>> theirs
  if v_cxl.status = 'posted' then
    raise exception 'INS_CANCELLATION_EVIDENCE_STATE: cancellation % has already posted; evidence must be recorded before it posts, otherwise it is a justification added after the fact',
      coalesce(v_cxl.cancellation_no, v_cxl.id::text);
  end if;
<<<<<<< ours
<<<<<<< ours
  if p_evidence_date is null or p_evidence_date > public.ins_local_today() then
    raise exception 'INS_CANCELLATION_EVIDENCE_INPUT: the evidence date must be today or earlier';
  end if;

  insert into public.ins_cancellation_date_evidence
    (tenant_id, cancellation_id, about_date, the_date, evidence_kind, evidence_ref,
     evidence_date, recorded_by, note)
  values
    (v_tenant, p_cancellation_id, 'effective', v_cxl.effective_date,
     btrim(p_evidence_kind), btrim(p_evidence_ref), p_evidence_date,
     auth.uid(), nullif(btrim(coalesce(p_note, '')), ''))
=======
=======
>>>>>>> theirs

  v_the_date := v_cxl.effective_date;
  insert into public.ins_cancellation_date_evidence
    (tenant_id, cancellation_id, request_key, about_date, the_date, evidence_kind,
     evidence_ref, evidence_date, recorded_by, note)
  values
    (v_tenant, p_cancellation_id, null, 'effective', v_the_date, btrim(p_evidence_kind),
     btrim(p_evidence_ref), p_evidence_date, auth.uid(),
     nullif(btrim(coalesce(p_note, '')), ''))
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
  on conflict (cancellation_id, about_date) do update
    set evidence_kind = excluded.evidence_kind,
        evidence_ref  = excluded.evidence_ref,
        evidence_date = excluded.evidence_date,
<<<<<<< ours
<<<<<<< ours
=======
        the_date      = excluded.the_date,
>>>>>>> theirs
=======
        the_date      = excluded.the_date,
>>>>>>> theirs
        note          = excluded.note,
        recorded_by   = excluded.recorded_by,
        recorded_at   = now()
  returning * into v_row;

  return v_row;
end $$;
<<<<<<< ours
<<<<<<< ours

revoke all on function public.ins_record_cancellation_date_evidence(uuid, text, text, date, text) from public, anon;
grant execute on function public.ins_record_cancellation_date_evidence(uuid, text, text, date, text) to authenticated;
=======
revoke all on function public.ins_record_cancellation_date_evidence(uuid, text, text, date, text, uuid) from public, anon;
grant execute on function public.ins_record_cancellation_date_evidence(uuid, text, text, date, text, uuid) to authenticated;
>>>>>>> theirs
=======
revoke all on function public.ins_record_cancellation_date_evidence(uuid, text, text, date, text, uuid) from public, anon;
grant execute on function public.ins_record_cancellation_date_evidence(uuid, text, text, date, text, uuid) to authenticated;
>>>>>>> theirs

-- ---------------------------------------------------------------------
-- 4b. Let the new column through the immutability guard
-- ---------------------------------------------------------------------
-- ins_cancellation_evidence_guard() (baseline) decides which columns of a
-- cancellation may change at all, by diffing the whole row with a short list
-- subtracted. settlement_date is not on that list, so without this the guard would
-- refuse the very update that stamps it -- the trigger in section 6 would fire, set
-- the value, and the row would be rejected as "proposal inputs cannot be rewritten".
--
-- This is a surgical re-issue of that function: the ONLY change is that
-- 'settlement_date' is added to the subtracted list, so it becomes an allowed field
-- exactly like posting_date beside it. Every other rule is reproduced unchanged,
-- including the ones covering the three append-only tables that share this function.
create or replace function public.ins_cancellation_evidence_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare cid uuid; c ins_policy_cancellations%rowtype;
begin
 if tg_table_name='ins_policy_cancellations' then
  if tg_op='DELETE' then raise exception 'INS_CANCELLATION_IMMUTABLE: retain cancellation audit'; end if;
  if tg_op='INSERT' then return new; end if;
  if old.status in('posted','rejected','withdrawn') then raise exception 'INS_CANCELLATION_IMMUTABLE: terminal cases cannot change'; end if;
  -- settlement_date is new in B4 and belongs in this list for the same reason
  -- posting_date is: it is set by the posting step, not typed in at proposal time.
  if (to_jsonb(new)-array['status','prepared_by','prepared_at','clearing_gl_account_id','calculation','checked_by','checked_at','review_note','manual_exception_accepted','cancellation_no','posting_date','settlement_date','journal_entry_id','refund_item_id','cash_at_posting','accounting_mappings','operation_txid'])
    is distinct from (to_jsonb(old)-array['status','prepared_by','prepared_at','clearing_gl_account_id','calculation','checked_by','checked_at','review_note','manual_exception_accepted','cancellation_no','posting_date','settlement_date','journal_entry_id','refund_item_id','cash_at_posting','accounting_mappings','operation_txid']) then
   raise exception 'INS_CANCELLATION_IMMUTABLE: proposal inputs cannot be rewritten; withdraw and resubmit'; end if;
  return new;
 end if;
 if tg_table_name='ins_cancellation_events' then
  if tg_op<>'INSERT' then raise exception 'INS_CANCELLATION_IMMUTABLE: append-only audit'; end if;
  return new;
 end if;
 cid:=case when tg_op='DELETE' then old.cancellation_id else new.cancellation_id end;
 select * into c from ins_policy_cancellations where id=cid;
 if tg_op='DELETE' or c.status<>'posting' or c.operation_txid<>txid_current() then raise exception 'INS_CANCELLATION_IMMUTABLE: financial evidence is transaction-bound and immutable'; end if;
 if tg_op='UPDATE' and (tg_table_name<>'ins_cancellation_insurer_adjustments' or (to_jsonb(new)-'recovery_item_id') is distinct from (to_jsonb(old)-'recovery_item_id')) then
  raise exception 'INS_CANCELLATION_IMMUTABLE: adjustment history cannot change'; end if;
 return new;
end $$;

-- ---------------------------------------------------------------------
-- 5. The backdating rule
-- ---------------------------------------------------------------------
-- An effective date earlier than the request date means cover stopped before anyone
-- asked for it to stop. That is legitimate -- clients backdate instructions constantly
-- -- but it changes the premium, so it needs something to point at.
--
-- This is a function rather than a trigger so it can be called from the two places
-- that matter (submit time, so the person hears about it immediately) and re-checked
-- at posting time (so removing the evidence afterwards does not help).
create or replace function public.ins_cancellation_effective_evidence_check(p_cancellation_id uuid)
returns void
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_cxl         public.ins_policy_cancellations%rowtype;
  v_request     date;
begin
  select * into v_cxl from public.ins_policy_cancellations
   where id = p_cancellation_id and tenant_id = public.get_my_tenant_id();
  if not found then
    raise exception 'INS_NOT_FOUND: cancellation';
  end if;

  v_request := (v_cxl.proposed_at at time zone 'Africa/Kampala')::date;

  if v_cxl.effective_date < v_request
     and not exists (select 1 from public.ins_cancellation_date_evidence e
                      where e.cancellation_id = v_cxl.id
                        and e.about_date = 'effective'
                        -- The evidence must itself pre-date the posting: notice the
                        -- company did not have is not notice.
                        and e.evidence_date <= public.ins_local_today()) then
    raise exception 'INS_CANCELLATION_BACKDATED_NO_EVIDENCE: cancellation % has an effective date of % but was requested on %. A backdated effective date needs the dated instruction or notice it rests on: record it with ins_record_cancellation_date_evidence() before submitting.',
      coalesce(v_cxl.cancellation_no, v_cxl.id::text), v_cxl.effective_date, v_request;
  end if;
end $$;

revoke all on function public.ins_cancellation_effective_evidence_check(uuid) from public, anon;
grant execute on function public.ins_cancellation_effective_evidence_check(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Enforce at posting time
-- ---------------------------------------------------------------------
-- The submit-time check is the courtesy; this is the control. It runs before the
-- cancellation is allowed to post, so a cancellation cannot reach the ledger with a
-- backdated effective date and no evidence, whatever route it took to get there.
create or replace function public.ins_cancellation_dates_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_request date;
begin
  if new.status not in ('posting', 'posted') then
    return new;
  end if;
  -- OLD is unassigned on INSERT, so it may only be read when the row already existed.
  if tg_op = 'UPDATE' and old.status in ('posting', 'posted') then
    return new;
  end if;

  v_request := (new.proposed_at at time zone 'Africa/Kampala')::date;

  -- Backdated effective date with nothing behind it.
  if new.effective_date < v_request
     and not exists (select 1 from public.ins_cancellation_date_evidence e
                      where e.cancellation_id = new.id and e.about_date = 'effective') then
    raise exception 'INS_CANCELLATION_BACKDATED_NO_EVIDENCE: cancellation % has an effective date of % but was requested on %, and no evidence is recorded. Record the dated instruction or notice with ins_record_cancellation_date_evidence() before posting.',
      coalesce(new.cancellation_no, new.id::text), new.effective_date, v_request;
  end if;

  -- The settlement date is stamped once, at posting, from what the cash shows.
  if new.settlement_date is null then
    new.settlement_date := coalesce(
      (select max(s.settlement_date)
         from fin_open_items i
         join fin_allocations a on a.open_item_id = i.id
         join fin_settlements s on s.id = a.settlement_id
        where i.tenant_id = new.tenant_id
          and s.status <> 'void'
          and (
            (i.source_type = 'ins_cancellation_client_refund'
             and i.source_id = new.id)
            or
            (i.source_type = 'ins_cancellation_insurer_recovery'
             and i.source_id in (select adj.id
                                   from ins_cancellation_insurer_adjustments adj
                                  where adj.cancellation_id = new.id
                                    and adj.tenant_id = new.tenant_id))
          )),
      new.posting_date,
      public.ins_local_today());
  end if;

  return new;
end $$;

revoke all on function public.ins_cancellation_dates_guard() from public, anon, authenticated;

drop trigger if exists ins_cancellation_dates_guard on public.ins_policy_cancellations;
create trigger ins_cancellation_dates_guard
  before insert or update on public.ins_policy_cancellations
  for each row execute function public.ins_cancellation_dates_guard();

-- A cancellation cannot be relocated once it has posted: the period it fell in is a
-- closed question by then.
create or replace function public.ins_cancellation_dates_immutable()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if old.status = 'posted' then
    if new.effective_date is distinct from old.effective_date
       or new.settlement_date is distinct from old.settlement_date
       or new.posting_date is distinct from old.posting_date then
      raise exception 'INS_CANCELLATION_DATES_IMMUTABLE: cancellation % has posted; its effective, settlement and posting dates cannot be changed',
        coalesce(old.cancellation_no, old.id::text);
    end if;
  end if;
  return new;
end $$;

revoke all on function public.ins_cancellation_dates_immutable() from public, anon, authenticated;

drop trigger if exists ins_cancellation_dates_immutable on public.ins_policy_cancellations;
create trigger ins_cancellation_dates_immutable
  before update on public.ins_policy_cancellations
  for each row execute function public.ins_cancellation_dates_immutable();

-- Evidence is not editable or removable once the cancellation has posted, for the
-- same reason: otherwise the justification can be rewritten after the decision.
-- NOTE ON THE NAME: ins_cancellation_evidence_guard() already exists in the baseline
-- as the immutability guard shared by ins_cancellation_events,
-- ins_cancellation_credit_links and ins_cancellation_insurer_adjustments -- three
-- append-only tables. Reusing that name would have replaced a guard that works on
-- three tables with one written for a fourth, and the collision is silent because
-- `create or replace` would have succeeded. Hence ins_cancellation_date_evidence_guard.
create or replace function public.ins_cancellation_date_evidence_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
<<<<<<< ours
<<<<<<< ours
  v_status text;
begin
  select c.status into v_status from public.ins_policy_cancellations c
   where c.id = coalesce(old.cancellation_id, new.cancellation_id);
=======
=======
>>>>>>> theirs
  v_id     uuid := coalesce(new.cancellation_id, old.cancellation_id);
  v_status text;
begin
  -- Unattached evidence (captured for a proposal that has not been submitted yet) is
  -- not evidence for anything on the record: it may be corrected or discarded freely,
  -- and the submission that consumes it does both in one step.
  if v_id is null then
    return coalesce(new, old);
  end if;
  select c.status into v_status from public.ins_policy_cancellations c where c.id = v_id;
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
  if v_status = 'posted' then
    raise exception 'INS_CANCELLATION_EVIDENCE_STATE: evidence for a posted cancellation cannot be changed or removed';
  end if;
  return coalesce(new, old);
end $$;

revoke all on function public.ins_cancellation_date_evidence_guard() from public, anon, authenticated;

drop trigger if exists ins_cancellation_date_evidence_guard on public.ins_cancellation_date_evidence;
create trigger ins_cancellation_date_evidence_guard
  before update or delete on public.ins_cancellation_date_evidence
  for each row execute function public.ins_cancellation_date_evidence_guard();

-- ---------------------------------------------------------------------
-- 7. Say it at submit time, too
-- ---------------------------------------------------------------------
<<<<<<< ours
<<<<<<< ours
-- Same function, called from the submission path, so the person entering a backdated
-- cancellation is told before Finance ever sees it. The body is identical to the
-- version in 20261108000100 apart from writing the cancellation number, calling the
-- check, and making the request date explicit.
=======
=======
>>>>>>> theirs
-- Re-issued from 20261108000200. It is a re-issue rather than an edit because the
-- submission path has to consume the evidence, and the check cannot simply be bolted
-- on the end: see the "why the evidence may arrive first" note under section 2.
--
-- Every rule the live function enforces is reproduced here. The first cut of this
-- migration dropped four of them -- the role check, the request/reason validation, the
-- policy row lock and the duplicate-live-proposal guard -- and the cancellation
-- event row with them. That would have let a backdated cancellation be raised over the
-- top of a live one and left the audit trail without its 'proposed' event, so the body
-- below is the live body with the evidence handling added, not a rewrite from scratch.
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
create or replace function public.ins_submit_policy_cancellation(
  p_policy_id uuid,
  p_effective_date date,
  p_insurer_terms jsonb,
  p_charge_refunds jsonb,
  p_reason text,
  p_request_key uuid
) returns public.ins_policy_cancellations
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c public.ins_policy_cancellations%rowtype;
  quote jsonb;
  v_method text;
begin
<<<<<<< ours
<<<<<<< ours
  perform public.ins_policy_cash_require_finance();

  -- The treatment in force on the EFFECTIVE date, which is the date the money is
  -- calculated from -- a backdated cancellation must use the treatment that applied
  -- then, not the one configured since.
  v_method := case (public.acct_get_setting('ins.cancellation_treatment', p_effective_date) ->> 'value')
                when 'short_period' then 'short_period' else 'pro_rata' end;

  if p_request_key is not null then
    select * into c from public.ins_policy_cancellations
     where tenant_id = public.get_my_tenant_id() and request_key = p_request_key;
    if found then
      if c.policy_id is distinct from p_policy_id
         or c.effective_date is distinct from p_effective_date
         or c.reason is distinct from btrim(p_reason) then
        raise exception 'INS_CANCELLATION_RETRY_CONFLICT: different request payload';
      end if;
      return c;
    end if;
=======
=======
>>>>>>> theirs
  -- Finance, acting as themselves. Unchanged from the live definition. B4 used to
  -- require only that SOME can_manage_insurance() user was present, which let anyone
  -- who can edit a policy raise a cash-affecting cancellation.
  if auth.uid() is null
     or effective_user_id() is distinct from auth.uid()
     or not (can_manage_insurance() or is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN: Insurance manager or Finance acting as themselves required' using errcode = '42501';
  end if;

  -- Company-configured default cancellation treatment. p_insurer_terms is an array of
  -- {insurer_id, terms:{method,...}}; an explicit terms.method (a per-agreement
  -- override) always wins, otherwise the approved ins.cancellation_treatment setting
  -- supplies it, read as at the EFFECTIVE date -- a backdated cancellation must use the
  -- treatment that applied then, not the one configured since.
  if jsonb_typeof(p_insurer_terms) = 'array' and exists (
    select 1 from jsonb_array_elements(p_insurer_terms) e
     where jsonb_typeof(e) = 'object' and jsonb_typeof(e -> 'terms') = 'object'
       and nullif(btrim(coalesce(e -> 'terms' ->> 'method', '')), '') is null) then
    v_method := case (public.acct_get_setting('ins.cancellation_treatment', p_effective_date) ->> 'value')
                  when 'pro_rata_refund'   then 'pro_rata'
                  when 'short_rate_refund' then 'short_period'
                  when 'no_refund'         then 'non_refundable'
                  else 'manual_review' end;
    select coalesce(jsonb_agg(
             case when jsonb_typeof(e) = 'object' and jsonb_typeof(e -> 'terms') = 'object'
                   and nullif(btrim(coalesce(e -> 'terms' ->> 'method', '')), '') is null
                  then jsonb_set(e, '{terms}', (e -> 'terms') || jsonb_build_object('method', v_method))
                  else e end
             order by ord), '[]'::jsonb)
      into p_insurer_terms
      from jsonb_array_elements(p_insurer_terms) with ordinality t(e, ord);
  end if;

  if p_request_key is null or p_reason is null
     or length(btrim(p_reason)) not between 5 and 2000 then
    raise exception 'INS_CANCELLATION_INPUT: request key and reason required';
  end if;

  perform id from public.ins_policies
   where id = p_policy_id and tenant_id = public.get_my_tenant_id() for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;

  -- Retry safety. The identity of a retry is the request key plus everything the
  -- caller sent, so a key reused with a different payload is a conflict rather than a
  -- silent second proposal.
  select * into c from public.ins_policy_cancellations
   where tenant_id = public.get_my_tenant_id() and request_key = p_request_key;
  if found then
    if c.proposed_by <> auth.uid()
       or c.policy_id is distinct from p_policy_id
       or c.effective_date is distinct from p_effective_date
       or c.insurer_terms is distinct from p_insurer_terms
       or c.charge_refunds is distinct from p_charge_refunds
       or c.reason is distinct from btrim(p_reason) then
      raise exception 'INS_CANCELLATION_RETRY_CONFLICT: different payload';
    end if;
    return c;
  end if;

  -- Refused BEFORE the insert, which is the whole point of taking the evidence up
  -- front. Raising after the insert would roll the proposal back along with the
  -- refusal, and the evidence would have nothing to attach to.
  if p_effective_date < public.ins_local_today()
     and not exists (select 1 from public.ins_cancellation_date_evidence e
                      where e.tenant_id = public.get_my_tenant_id()
                        and e.request_key = p_request_key
                        and e.cancellation_id is null
                        and e.about_date = 'effective'
                        and e.evidence_date <= public.ins_local_today()) then
    raise exception 'INS_CANCELLATION_BACKDATED_NO_EVIDENCE: the effective date % is earlier than today, so this is a backdated cancellation and needs the dated instruction or notice it rests on. Record it first with ins_record_cancellation_date_evidence(p_cancellation_id => null, p_request_key => %, ...) using the same request key, then submit again.',
      p_effective_date, p_request_key;
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
  end if;

  quote := public.ins_preview_policy_cancellation(p_policy_id, p_effective_date, p_insurer_terms, p_charge_refunds);

<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
  if exists (select 1 from public.ins_policy_cancellations
              where policy_id = p_policy_id
                and status in ('proposed', 'prepared', 'posting', 'posted')) then
    raise exception 'INS_CANCELLATION_EXISTS: a live proposal or posted cancellation already exists';
  end if;

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
  insert into public.ins_policy_cancellations
    (tenant_id, policy_id, request_key, reason, effective_date, insurer_terms,
     charge_refunds, proposed_by, calculation)
  values
    (public.get_my_tenant_id(), p_policy_id, p_request_key, btrim(p_reason),
     p_effective_date, p_insurer_terms, p_charge_refunds, auth.uid(), quote)
  returning * into c;

<<<<<<< ours
<<<<<<< ours
  -- A backdated effective date is refused here, with the instruction that fixes it,
  -- rather than surfacing later at posting. The proposal row is left in place so the
  -- person can record the evidence and retry with the same request key.
  perform public.ins_cancellation_effective_evidence_check(c.id);
=======
=======
>>>>>>> theirs
  -- Attach any evidence captured for this request key, and record the date it is
  -- evidence about now that the proposal has fixed it.
  update public.ins_cancellation_date_evidence
     set cancellation_id = c.id,
         request_key     = null,
         the_date        = c.effective_date
   where tenant_id = public.get_my_tenant_id()
     and request_key = p_request_key
     and cancellation_id is null;

  insert into public.ins_cancellation_events (tenant_id, cancellation_id, event, actor_id)
  values (c.tenant_id, c.id, 'proposed', auth.uid());
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs

  return c;
end $$;

revoke all on function public.ins_submit_policy_cancellation(uuid, date, jsonb, jsonb, text, uuid) from public, anon;
grant execute on function public.ins_submit_policy_cancellation(uuid, date, jsonb, jsonb, text, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 8. Prove it
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public'
                    and table_name = 'ins_policy_cancellations'
                    and column_name = 'settlement_date') then
    raise exception 'B4: settlement_date was not added';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'ins_cancellation_dates_guard'
                    and not tgisinternal) then
    raise exception 'B4: the posting-time date guard is not installed';
  end if;
  raise notice 'PASS: B4 carries a settlement date, evidence table and posting-time guard';
end $$;
