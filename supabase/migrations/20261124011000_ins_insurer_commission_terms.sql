-- =====================================================================
-- Commission recognition terms, per insurer agreement
-- Accountant pack v2, B3 (decision 2B: fail closed PER INSURER)
-- =====================================================================
-- B3's criterion: "binding refuses unless an explicit recognition mode is approved
-- and in force for that policy's insurer agreement ... the error names the insurer and
-- the missing setting".
--
-- The fail-closed half already ships (20261124010200): bind refuses when the company
-- has never chosen a recognition mode. What it cannot do is express the requirement
-- that makes it an INSURER rule rather than a company rule. One brokerage writes
-- agreements on several bases at once -- placement commission with one insurer,
-- collection commission with another -- and a single company-wide setting cannot say
-- so without forcing someone to pick the wrong one for half the book.
--
-- This adds the per-insurer agreement as the primary source, and keeps the company
-- setting as the fallback so that nothing that binds today stops binding.
--
-- PRECEDENCE, and why it is this order
--
--   1. gross_premium settlement basis  -> at_placement
--      Nothing is left to collect when the premium crosses in full. Unchanged.
--   2. an explicit per-policy override
--      A deliberate decision about this one policy outranks a standing agreement.
--   3. the insurer's approved terms in force on the inception date   <- new
--   4. the company setting
--      The default for insurers with no negotiated term on file.
--   5. nothing -> refuse
--
-- Both 3 and 4 are "explicitly approved and in force"; the difference is specificity.
-- The refusal names the insurer AND both places the mode could have come from,
-- because "the setting is missing" is unhelpful when the answer was supposed to be an
-- agreement with that insurer.
--
-- WHY A SEPARATE TABLE RATHER THAN A COLUMN ON ins_insurers
-- A mode is a term of an agreement, not an attribute of a counterparty. It has an
-- effective period, a document it rests on, and an approver -- and a company that
-- renegotiated its terms needs last year's mode to stay attached to last year's
-- policies. A single column would overwrite the history that the snapshot is meant to
-- protect. ins_intermediary_terms already sets this precedent in the same schema.

-- ---------------------------------------------------------------------
-- 1. The terms
-- ---------------------------------------------------------------------
create table if not exists ins_insurer_commission_terms (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  insurer_id      uuid not null references ins_insurers(id) on delete restrict,
  mode            text not null,
  effective_from  date not null,
  effective_to    date,
  status          text not null default 'draft'
                    check (status in ('draft', 'approved', 'withdrawn')),
  -- The clause or document the mode is taken from. Required: a term with no
  -- provenance is an assertion, and this table exists to stop assertions.
  agreed_ref      text not null check (length(btrim(agreed_ref)) between 3 and 240),
  rationale       text not null check (length(btrim(rationale)) >= 10),
  proposed_by     uuid not null references auth.users(id),
  proposed_at     timestamptz not null default now(),
  approved_by     uuid references auth.users(id),
  approved_at     timestamptz,
  withdrawn_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  -- Maker-checker, as everywhere else that changes accounting behaviour.
  check (approved_by is null or approved_by is distinct from proposed_by),
  check (status <> 'approved' or (approved_by is not null and approved_at is not null))
);

create index if not exists ins_insurer_commission_terms_lookup
  on ins_insurer_commission_terms (tenant_id, insurer_id, effective_from desc)
  where status = 'approved';

comment on table ins_insurer_commission_terms is
  'The commission recognition mode agreed with one insurer, for a period. Approved terms outrank the company-wide ins.commission_recognition setting at bind; the company setting remains the fallback for insurers with no term on file.';

-- One open term per insurer: two approved terms starting the same day cannot both be
-- "the" agreement. Closed, non-overlapping history is fine and expected.
create unique index if not exists ins_insurer_commission_terms_no_duplicate_start
  on ins_insurer_commission_terms (tenant_id, insurer_id, effective_from)
  where status in ('draft', 'approved');

create or replace function public.ins_insurer_commission_terms_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_mode_ok boolean;
  v_clash   text;
begin
  -- The mode must be one the platform actually implements, taken from the same
  -- registry the company setting reads -- one vocabulary, not two that can drift.
  -- new.mode, not a bare `mode`: the only table in this statement is
  -- accounting_setting_definitions (alias d), which has no mode column, so the unqualified
  -- reference failed with 42703 'column "mode" does not exist' on EVERY insert. No commission
  -- terms could be recorded for any insurer, which in turn made binding a policy impossible
  -- whenever no company-wide recognition mode was approved. It was invisible to a parse check
  -- (the body is a dollar-quoted string) and to the register gates.
  select coalesce(new.mode = any(d.implemented_values), false)
    into v_mode_ok
    from accounting_setting_definitions d
   where d.key = 'ins.commission_recognition';
  if not coalesce(v_mode_ok, false) then
    raise exception 'INS_COMMISSION_TERMS_MODE: % is not an implemented recognition mode (implemented: %)',
      new.mode,
      (select array_to_string(d.implemented_values, ', ')
         from accounting_setting_definitions d
        where d.key = 'ins.commission_recognition');
  end if;

  if new.status = 'approved' then
    select coalesce(t.effective_from::text, '(open)')
      into v_clash
      from ins_insurer_commission_terms t
     where t.tenant_id = new.tenant_id
       and t.insurer_id = new.insurer_id
       and t.status = 'approved'
       and t.id <> coalesce(new.id, gen_random_uuid())
       and t.effective_from <= coalesce(new.effective_to, date 'infinity')
       and coalesce(t.effective_to, date 'infinity') >= new.effective_from
     limit 1;
    if v_clash is not null then
      raise exception 'INS_COMMISSION_TERMS_OVERLAP: these terms run from % and would overlap the approved terms starting %. An insurer agreement has one mode at a time; end the earlier term first.',
        new.effective_from, v_clash;
    end if;
  end if;

  -- A term that is already approved is not edited into something else; it is ended
  -- and replaced, so the history of what was agreed stays readable.
  if tg_op = 'UPDATE' and old.status = 'approved' then
    if new.mode is distinct from old.mode
       or new.effective_from is distinct from old.effective_from
       or new.agreed_ref is distinct from old.agreed_ref then
      raise exception 'INS_COMMISSION_TERMS_IMMUTABLE: approved terms cannot be rewritten. End them with ins_end_insurer_commission_terms() and record the new agreement, so both remain on file.';
    end if;
  end if;
  if current_user = 'authenticated' and not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: commission terms are written only through the commission terms RPCs' using errcode = '42501';
  end if;

  new.updated_at := now();
  return new;
end $$;

revoke all on function public.ins_insurer_commission_terms_guard() from public, anon, authenticated, service_role;

drop trigger if exists ins_insurer_commission_terms_guard on public.ins_insurer_commission_terms;
create trigger ins_insurer_commission_terms_guard
  before insert or update on public.ins_insurer_commission_terms
  for each row execute function public.ins_insurer_commission_terms_guard();

alter table ins_insurer_commission_terms enable row level security;

drop policy if exists ins_insurer_commission_terms_select on ins_insurer_commission_terms;
create policy ins_insurer_commission_terms_select on ins_insurer_commission_terms
  for select to authenticated
  using (tenant_id = get_my_tenant_id());

-- Written only through the RPCs below.
drop policy if exists ins_insurer_commission_terms_insert on ins_insurer_commission_terms;
create policy ins_insurer_commission_terms_insert on ins_insurer_commission_terms
  for insert to authenticated with check (tenant_id = public.get_my_tenant_id() and false);

drop policy if exists ins_insurer_commission_terms_update on ins_insurer_commission_terms;
create policy ins_insurer_commission_terms_update on ins_insurer_commission_terms
  for update to authenticated using (tenant_id = public.get_my_tenant_id() and public.is_tenant_admin()) with check (tenant_id = public.get_my_tenant_id() and public.is_tenant_admin());

drop policy if exists ins_insurer_commission_terms_delete on ins_insurer_commission_terms;
create policy ins_insurer_commission_terms_delete on ins_insurer_commission_terms
  for delete to authenticated using (tenant_id = public.get_my_tenant_id() and false);

-- ---------------------------------------------------------------------
-- 2. Recording and approving a term
-- ---------------------------------------------------------------------
create or replace function public.ins_propose_insurer_commission_terms(
  p_insurer_id uuid,
  p_mode text,
  p_effective_from date,
  p_agreed_ref text,
  p_rationale text,
  p_effective_to date default null
) returns public.ins_insurer_commission_terms
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.ins_insurer_commission_terms%rowtype;
begin
  if not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
    raise exception 'INS_COMMISSION_TERMS_FORBIDDEN: only a company admin or a finance team member can record commission terms' using errcode = '42501';
  end if;
  if p_effective_from is null then
    raise exception 'INS_COMMISSION_TERMS_DATE: an effective date is required';
  end if;
  if not exists (select 1 from public.ins_insurers i where i.id = p_insurer_id and i.tenant_id = v_tenant) then
    raise exception 'INS_NOT_FOUND: insurer';
  end if;
  -- Validated here as well as by the table's CHECK constraints, so the caller gets a
  -- sentence about what is missing rather than a constraint name.
  if length(btrim(coalesce(p_agreed_ref, ''))) < 3 then
    raise exception 'INS_COMMISSION_TERMS_PROVENANCE: name the clause, letter or agreement the mode is taken from. A term with no provenance is an assertion, and this table exists to stop assertions.';
  end if;
  if length(btrim(coalesce(p_rationale, ''))) < 10 then
    raise exception 'INS_COMMISSION_TERMS_RATIONALE: explain the commercial reason in at least ten characters';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  insert into public.ins_insurer_commission_terms
    (tenant_id, insurer_id, mode, effective_from, effective_to, agreed_ref, rationale, proposed_by)
  values
    (v_tenant, p_insurer_id, p_mode, p_effective_from, p_effective_to,
     btrim(p_agreed_ref), btrim(p_rationale), auth.uid())
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.ins_propose_insurer_commission_terms(uuid, text, date, text, text, date) from public, anon;
grant execute on function public.ins_propose_insurer_commission_terms(uuid, text, date, text, text, date) to authenticated;

create or replace function public.ins_approve_insurer_commission_terms(p_id uuid)
returns public.ins_insurer_commission_terms
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row public.ins_insurer_commission_terms%rowtype;
begin
  select * into v_row from public.ins_insurer_commission_terms
   where id = p_id and tenant_id = public.get_my_tenant_id()
   for update;
  if not found then
    raise exception 'INS_NOT_FOUND: commission terms';
  end if;
  if not public.is_tenant_admin() then
    raise exception 'INS_COMMISSION_TERMS_FORBIDDEN: only a company admin can approve commission terms' using errcode = '42501';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'INS_COMMISSION_TERMS_STATE: only draft terms can be approved (these are %)', v_row.status;
  end if;
  if v_row.proposed_by = auth.uid() then
    raise exception 'INS_COMMISSION_TERMS_SELF_APPROVAL: the person who recorded the terms cannot approve them';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update public.ins_insurer_commission_terms
     set status = 'approved', approved_by = auth.uid(), approved_at = now()
   where id = p_id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.ins_approve_insurer_commission_terms(uuid) from public, anon;
grant execute on function public.ins_approve_insurer_commission_terms(uuid) to authenticated;

-- Ending a term is how a renegotiation is recorded: close the old one the day before
-- the new one starts, rather than editing it.
create or replace function public.ins_end_insurer_commission_terms(p_id uuid, p_ends_on date, p_reason text)
returns public.ins_insurer_commission_terms
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row public.ins_insurer_commission_terms%rowtype;
begin
  select * into v_row from public.ins_insurer_commission_terms
   where id = p_id and tenant_id = public.get_my_tenant_id()
   for update;
  if not found then
    raise exception 'INS_NOT_FOUND: commission terms';
  end if;
  if not public.is_tenant_admin() then
    raise exception 'INS_COMMISSION_TERMS_FORBIDDEN: only a company admin can end commission terms' using errcode = '42501';
  end if;
  if v_row.status <> 'approved' then
    raise exception 'INS_COMMISSION_TERMS_STATE: only approved terms can be ended (these are %)', v_row.status;
  end if;
  if p_ends_on is null or p_ends_on < v_row.effective_from then
    raise exception 'INS_COMMISSION_TERMS_DATE: the end date must be on or after the start date (%)', v_row.effective_from;
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'INS_COMMISSION_TERMS_REASON: say why the term is ending';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update public.ins_insurer_commission_terms
     set effective_to = p_ends_on, withdrawn_reason = btrim(p_reason)
   where id = p_id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.ins_end_insurer_commission_terms(uuid, date, text) from public, anon;
grant execute on function public.ins_end_insurer_commission_terms(uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Which mode applies to an insurer on a date
-- ---------------------------------------------------------------------
create or replace function public.platform_ins_commission_mode(
  p_tenant_id uuid,
  p_insurer_id uuid,
  p_on date
) returns table (mode text, source text, terms_id uuid, agreed_ref text)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row public.ins_insurer_commission_terms%rowtype;
begin
  -- The insurer's own approved agreement, if one covers this date.
  select * into v_row
    from public.ins_insurer_commission_terms t
   where t.tenant_id = p_tenant_id
     and t.insurer_id = p_insurer_id
     and t.status = 'approved'
     and t.effective_from <= coalesce(p_on, public.ins_local_today())
     and (t.effective_to is null or t.effective_to >= coalesce(p_on, public.ins_local_today()))
   order by t.effective_from desc
   limit 1;

  if found then
    return query select v_row.mode, 'insurer_agreement'::text, v_row.id, v_row.agreed_ref;
    return;
  end if;

  -- No agreement on file: say nothing. The caller decides whether the company
  -- setting can stand in, because that is a policy decision and not this function's.
  return query select null::text, 'none'::text, null::uuid, null::text;
end $$;

revoke all on function public.platform_ins_commission_mode(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.platform_ins_commission_mode(uuid, uuid, date) to service_role;

create or replace function public.ins_commission_recognition_mode(p_policy_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_pol     ins_policies%rowtype;
  v_terms   record;
  v_setting text;
begin
  select * into v_pol from public.ins_policies where id = p_policy_id;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform public.assert_tenant_access(v_pol.tenant_id);

  if public.get_my_tenant_id() is distinct from v_pol.tenant_id then
    raise exception 'INS_TENANT_MISMATCH: policy belongs to another company' using errcode = '42501';
  end if;

  if v_pol.commission_recognition_override is not null then
    return v_pol.commission_recognition_override;
  end if;

  select * into v_terms
    from public.platform_ins_commission_mode(v_pol.tenant_id, v_pol.insurer_id, v_pol.inception_date);
  if v_terms.mode is not null then
    return v_terms.mode;
  end if;

  v_setting := public.acct_assert_reviewed('ins.commission_recognition', v_pol.inception_date);
  if v_setting not in ('on_insurer_settlement', 'at_placement', 'on_premium_collection', 'pro_rata_on_collection') then
    raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % is set for this company, but only on_insurer_settlement, at_placement, on_premium_collection and pro_rata_on_collection are implemented; configure one of those', v_setting;
  end if;
  return v_setting;
end;
$function$;

revoke all on function public.ins_commission_recognition_mode(uuid) from public, anon;
grant execute on function public.ins_commission_recognition_mode(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Bind: the insurer agreement becomes the primary source
-- ---------------------------------------------------------------------
-- This re-issues ins_snapshot_bind_config() from 20261124010200. Every rule in it is
-- preserved: the gross-basis override, the per-policy override, the unimplemented-mode
-- refusal, the collection-mode-under-gross-basis refusal, and the statutory snapshot.
-- The single behavioural change is where v_recognition comes from, and the refusal
-- message now names the insurer as well as the setting.
create or replace function public.ins_snapshot_bind_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_recognition text;
  v_effective   text;
  v_source      text;
  v_basis       text;
  v_terms       record;
  v_insurer     record;
  v_setting     jsonb;
begin
  if new.status = 'active' and old.status is distinct from new.status then
    if not public.ins_via_rpc()
       or old.status <> 'approved'
       or not coalesce(public.ins_opening_accepted_for(new.tenant_id), true) then
      return new;
    end if;

    select i.name, i.code into v_insurer
      from public.ins_insurers i
     where i.id = new.insurer_id and i.tenant_id = new.tenant_id;

    -- (3) the insurer's agreement takes precedence over (4) the company setting.
    select * into v_terms
      from public.platform_ins_commission_mode(new.tenant_id, new.insurer_id, new.inception_date);

    v_setting := public.acct_get_setting('ins.commission_recognition', new.inception_date);

    if v_terms.mode is not null then
      v_recognition := v_terms.mode;
    elsif (v_setting ->> 'source') = 'configured' then
      -- The review gate applies to the company setting, which is the path that can
      -- be changed without anyone looking at a contract. An insurer agreement is
      -- already double-approved by its own maker-checker, so it does not need a
      -- second gate that would then overwrite the agreement with the company value.
      v_recognition := public.acct_assert_reviewed('ins.commission_recognition', new.inception_date);
    else
      -- FAIL CLOSED (decision 2B). Neither an insurer agreement nor an approved
      -- company setting is in force, so this policy has no recognised mode and
      -- cannot bind. The message names both places it could have come from,
      -- because telling someone only about the company setting sends them to the
      -- wrong screen when the answer was supposed to be an agreement.
      raise exception 'INS_COMMISSION_RECOGNITION_UNSET: % cannot bind. Insurer % (%) has no approved commission terms in force on %, and this company has no approved ins.commission_recognition on that date. Record the mode agreed with this insurer in its commission terms (at_placement, on_premium_collection, pro_rata_on_collection or on_insurer_settlement), or set the company default in accounting settings and have it reviewed.',
        new.policy_no,
        coalesce(v_insurer.name, new.insurer_id::text),
        coalesce(v_insurer.code, '?'),
        new.inception_date;
    end if;

    v_basis := public.ins_share_basis(new.id);

    if new.commission_recognition_override is not null then
      v_source := 'policy_override';
    elsif v_terms.mode is not null then
      v_source := 'insurer_agreement';
    else
      v_source := 'tenant_setting';
    end if;

    -- Gross settlement means the premium crosses in full and the commission is
    -- a receivable from the insurer: there is nothing left to defer, so it is
    -- earned at placement whatever the setting says. Unchanged.
    if v_basis = 'gross_premium'
       and coalesce(new.commission_amount, 0) > 0 then
      v_effective := 'at_placement';
      v_source    := 'remittance_basis_gross';
    elsif new.commission_recognition_override is not null then
      v_effective := new.commission_recognition_override;
      v_source    := 'policy_override';
    else
      v_effective := v_recognition;
    end if;

    if v_effective not in ('on_insurer_settlement', 'at_placement',
                           'on_premium_collection', 'pro_rata_on_collection') then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % has no reader in this release (implemented: on_insurer_settlement, at_placement, on_premium_collection, pro_rata_on_collection). Configure one of those before binding %', v_effective, new.policy_no;
    end if;

    if v_effective = 'at_placement' and coalesce(new.commission_amount, 0) <= 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_MODE: % is set to recognise commission at placement but has no commission; correct the rate or choose a collection or settlement mode', new.policy_no;
    end if;

    -- Both collection modes need something left to collect, so both are
    -- refused under a gross basis.
    if v_effective in ('on_premium_collection', 'pro_rata_on_collection')
       and v_basis = 'gross_premium'
       and coalesce(new.commission_amount, 0) > 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_BASIS: % is set to recognise commission when the premium is collected (%), but its settlement basis is gross_premium, where the premium crosses in full at bind and there is nothing left to collect. Choose at_placement for a gross basis, or move this insurer to a net basis', new.policy_no, v_effective;
    end if;

    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object(
           'ins.commission_recognition', v_recognition,
           'commission_recognition_effective', v_effective,
           'commission_recognition_source', v_source,
           -- The agreement the mode came from, so the snapshot can be defended
           -- later without re-deriving which terms were in force.
           'commission_terms_id', v_terms.terms_id,
           'commission_terms_ref', v_terms.agreed_ref,
           'insurer_code', v_insurer.code,
           'resolved_at', now()
         );
  end if;

  if new.status = 'active' and old.status is distinct from 'active' then
    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object(
           'statutory_charges', to_jsonb(new.statutory_charges_ack),
           'statutory_charge_enforcement',
             public.ins_statutory_enforcement(new.tenant_id, new.inception_date));
  end if;

  return new;
end $$;

revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated;

-- The trigger already exists from 20261124010200; re-created here so this migration
-- is self-contained if that one is ever squashed away.
drop trigger if exists ins_bind_config_snapshot on public.ins_policies;
create trigger ins_bind_config_snapshot
  before update on public.ins_policies
  for each row execute function public.ins_snapshot_bind_config();

-- ---------------------------------------------------------------------
-- 5. What the accountant needs to see before binding
-- ---------------------------------------------------------------------
-- The refusal is only useful if someone can tell, BEFORE a client is waiting at the
-- counter, which insurers are configured and which are not.
create or replace function public.ins_commission_mode_readiness()
returns table (
  insurer_id uuid, insurer_code text, insurer_name text,
  mode text, source text, effective_from date, agreed_ref text,
  will_bind boolean, says text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  v_setting jsonb;
  v_today   date := public.ins_local_today();
begin
  v_setting := public.acct_get_setting('ins.commission_recognition', v_today);

  return query
  select i.id, i.code, i.name,
         coalesce(m.mode,
                  case when (v_setting ->> 'source') = 'configured'
                       then v_setting ->> 'value' end),
         case when m.mode is not null then 'insurer_agreement'
              when (v_setting ->> 'source') = 'configured' then 'tenant_setting'
              else 'none' end,
         (select t.effective_from from public.ins_insurer_commission_terms t
           where t.id = m.terms_id),
         m.agreed_ref,
         coalesce(m.mode, case when (v_setting ->> 'source') = 'configured'
                               then v_setting ->> 'value' end) is not null,
         case
           when m.mode is not null then
             'covered by the insurer agreement' || coalesce(' (' || m.agreed_ref || ')', '')
           when (v_setting ->> 'source') = 'configured' then
             'no agreement on file; the company default applies'
           else
             'NOT COVERED: policies with this insurer cannot bind until terms or a company default exist'
         end
    from public.ins_insurers i
    left join lateral public.platform_ins_commission_mode(v_tenant, i.id, v_today) m on true
   where i.tenant_id = v_tenant
   order by i.code;
end $$;

revoke all on function public.ins_commission_mode_readiness() from public, anon;
grant execute on function public.ins_commission_mode_readiness() to authenticated;

select public.apply_tenant_read_only_guard();

-- ---------------------------------------------------------------------
-- 6. Prove the table and the resolver are in place
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public'
                    and table_name = 'ins_insurer_commission_terms') then
    raise exception 'B3: ins_insurer_commission_terms was not created';
  end if;
  if not exists (select 1 from pg_proc where proname = 'platform_ins_commission_mode') then
    raise exception 'B3: the mode resolver is missing';
  end if;
  raise notice 'PASS: B3 per-insurer commission terms are installable';
end $$;
