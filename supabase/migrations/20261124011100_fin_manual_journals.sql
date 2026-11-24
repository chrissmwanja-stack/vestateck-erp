-- =====================================================================
-- Manual journals: a real posting surface with real controls
-- Accountant pack v2, B6; pack section 9
-- =====================================================================
-- The pack requires that a manual journal is:
--
--   * not unbalanced                                    (already enforced)
--   * not self-approved                                 (NOT enforced -- built here)
--   * never posted to a control account without a subledger reference
--                                                       (NOT enforced -- built here)
--   * not editable after posting                        (already enforced)
--
-- A CORRECTION TO THE REGISTER'S CENSUS
--
-- The census said three of the four criteria were "met by absence, not control",
-- because post_journal_entry() is not executable by `authenticated`. Two of them are
-- in fact met by a real control that has nothing to do with that grant:
--
--   balance        check_journal_entry_balanced is a DEFERRED CONSTRAINT TRIGGER on
--                  journal_entry_lines (created in the baseline), so an unbalanced
--                  entry cannot be committed by anyone, including service_role and
--                  the table owner. The per-line inserts inside post_journal_entry
--                  would each fail a naive check; deferral is what makes it work.
--   immutability   prevent_journal_mutation blocks UPDATE and DELETE on both tables
--                  for everyone, with the single documented exception of voiding.
--
-- So the real gap is narrower than the register implied: nobody can enter a manual
-- journal at all, and if they could, nothing would stop one person writing it and
-- approving it, and nothing would stop a manual line landing on AR control without an
-- open item behind it -- which is how a subledger silently stops agreeing with the
-- ledger.
--
-- WHY NOT JUST GRANT EXECUTE ON post_journal_entry
--
-- Because it is a platform primitive with no opinions: it takes whatever lines it is
-- given, for any source type, with no approval and no control-account rule. Handing
-- `authenticated` a grant on it would remove the only thing currently preventing
-- manual journals, and put nothing in its place. What the pack asks for is a governed
-- surface, so the surface is built and the primitive stays exactly as locked as it is.
--
-- WHY MANUAL JOURNALS POST OUTSIDE THE INSURANCE MODULE
--
-- The pack puts manual journals in the same approval-limits section as refunds, but a
-- manual journal is a company-finance instrument, not an insurance one: a company
-- without the insurance module must be able to write one. So the gate here is the
-- finance role and company administration, not can_access_insurance().

-- ---------------------------------------------------------------------
-- 1. The journal
-- ---------------------------------------------------------------------
create table if not exists fin_manual_journals (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  journal_no     text,
  entry_date     date not null,
  -- Why this entry exists, in words a reviewer can act on. The minimum is deliberate:
  -- "adj" is not a reason.
  purpose        text not null check (length(btrim(purpose)) between 10 and 2000),
  -- The document being corrected, supported or accrued. Free text because the range of
  -- things a manual journal rests on is unbounded, but required, because an
  -- unsupported manual journal is the thing this control exists to prevent.
  reference      text not null check (length(btrim(reference)) between 3 and 240),
  status         text not null default 'draft'
                   check (status in ('draft', 'pending_approval', 'approved',
                                     'rejected', 'posted', 'withdrawn')),
  total_debit    numeric not null default 0 check (total_debit >= 0),
  total_credit   numeric not null default 0 check (total_credit >= 0),
  currency       text not null,
  requested_by   uuid not null references auth.users(id),
  requested_at   timestamptz not null default now(),
  submitted_by   uuid references auth.users(id),
  submitted_at   timestamptz,
  decided_by     uuid references auth.users(id),
  decided_at     timestamptz,
  decision_note  text,
  journal_entry_id uuid references journal_entries(id),
  posted_at      timestamptz,
  rejection_reason text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- Maker-checker, enforced in the table as well as in the function.
  check (decided_by is null or decided_by is distinct from requested_by),
  check (status <> 'posted' or (journal_entry_id is not null and posted_at is not null))
);

create unique index if not exists fin_manual_journals_no_key
  on fin_manual_journals (tenant_id, journal_no)
  where journal_no is not null;

create index if not exists fin_manual_journals_open
  on fin_manual_journals (tenant_id, status)
  where status in ('draft', 'pending_approval', 'approved');

comment on table fin_manual_journals is
  'A manual journal request. Lines live in fin_manual_journal_lines. Nothing reaches the ledger until a second person approves it and it posts through the governed surface; journal_entries remains immutable and post_journal_entry() remains unexecutable by authenticated.';

create table if not exists fin_manual_journal_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  journal_id     uuid not null references fin_manual_journals(id) on delete cascade,
  line_no        integer not null check (line_no > 0),
  gl_account_id  uuid not null references gl_accounts(id) on delete restrict,
  debit          numeric not null default 0 check (debit >= 0),
  credit         numeric not null default 0 check (credit >= 0),
  description    text,
  -- B6's third criterion. A control account can only carry a manual line if the line
  -- names the subledger item it belongs to, and the post checks that item exists, is
  -- in this company, and is on that same control account.
  subledger_source_type text,
  subledger_source_id   uuid,
  created_at     timestamptz not null default now(),
  -- Exactly one side, never both, never neither.
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  unique (journal_id, line_no)
);

comment on column fin_manual_journal_lines.subledger_source_type is
  'Required when gl_account_id is a control account. Must match an open item of that source type and id in this company, whose control role posts to that same account.';

alter table fin_manual_journals enable row level security;
alter table fin_manual_journal_lines enable row level security;

drop policy if exists fin_manual_journals_select on fin_manual_journals;
create policy fin_manual_journals_select on fin_manual_journals
  for select to authenticated
  using (tenant_id = get_my_tenant_id());

drop policy if exists fin_manual_journals_insert on fin_manual_journals;
create policy fin_manual_journals_insert on fin_manual_journals
  for insert to authenticated with check (false);

drop policy if exists fin_manual_journals_update on fin_manual_journals;
create policy fin_manual_journals_update on fin_manual_journals
  for update to authenticated using (false) with check (false);

drop policy if exists fin_manual_journals_delete on fin_manual_journals;
create policy fin_manual_journals_delete on fin_manual_journals
  for delete to authenticated using (false);

drop policy if exists fin_manual_journal_lines_select on fin_manual_journal_lines;
create policy fin_manual_journal_lines_select on fin_manual_journal_lines
  for select to authenticated
  using (tenant_id = get_my_tenant_id());

drop policy if exists fin_manual_journal_lines_insert on fin_manual_journal_lines;
create policy fin_manual_journal_lines_insert on fin_manual_journal_lines
  for insert to authenticated with check (false);

drop policy if exists fin_manual_journal_lines_update on fin_manual_journal_lines;
create policy fin_manual_journal_lines_update on fin_manual_journal_lines
  for update to authenticated using (false) with check (false);

drop policy if exists fin_manual_journal_lines_delete on fin_manual_journal_lines;
create policy fin_manual_journal_lines_delete on fin_manual_journal_lines
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------
-- 2. Guards: draft only, approved only once, posted never
-- ---------------------------------------------------------------------
create or replace function public.fin_manual_journal_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  new.updated_at := now();

  if tg_op = 'UPDATE' then
    if old.status in ('posted', 'withdrawn', 'rejected') then
      raise exception 'FIN_MANUAL_JOURNAL_IMMUTABLE: this manual journal is % and cannot be changed', old.status;
    end if;
    -- The figures are decided at submission and reviewed before approval. A journal
    -- whose lines change after approval is not the journal that was approved.
    if old.status = 'approved'
       and (new.total_debit is distinct from old.total_debit
            or new.total_credit is distinct from old.total_credit
            or new.entry_date is distinct from old.entry_date) then
      raise exception 'FIN_MANUAL_JOURNAL_APPROVED: this journal is approved; its amounts and date cannot change. Withdraw it and raise a new one.';
    end if;
  end if;

  return new;
end $$;

revoke all on function public.fin_manual_journal_guard() from public, anon, authenticated;

drop trigger if exists fin_manual_journal_guard on public.fin_manual_journals;
create trigger fin_manual_journal_guard
  before insert or update on public.fin_manual_journals
  for each row execute function public.fin_manual_journal_guard();

-- Lines may only be added or changed while the journal is a draft.
create or replace function public.fin_manual_journal_line_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_status text;
  v_journal uuid := coalesce(new.journal_id, old.journal_id);
begin
  select j.status into v_status from public.fin_manual_journals j where j.id = v_journal;
  if v_status is null then
    raise exception 'FIN_MANUAL_JOURNAL_LINE: journal not found';
  end if;
  if v_status <> 'draft' then
    -- Lines travel with the journal as the thing that was approved, so they are frozen
    -- the moment it leaves draft -- not only once it posts.
    raise exception 'FIN_MANUAL_JOURNAL_LINE: lines can only be changed while the journal is a draft (this one is %)', v_status;
  end if;
  return coalesce(new, old);
end $$;

revoke all on function public.fin_manual_journal_line_guard() from public, anon, authenticated;

drop trigger if exists fin_manual_journal_line_guard on public.fin_manual_journal_lines;
create trigger fin_manual_journal_line_guard
  before insert or update or delete on public.fin_manual_journal_lines
  for each row execute function public.fin_manual_journal_line_guard();

-- ---------------------------------------------------------------------
-- 3. The control-account rule
-- ---------------------------------------------------------------------
-- This is the criterion that keeps the subledger honest. It is a function as well as a
-- trigger so the submission path can call it and refuse early, with a message about
-- which line is wrong rather than about a constraint.
create or replace function public.fin_manual_journal_check_control_lines(p_journal_id uuid)
returns void
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid;
  v_bad    record;
begin
  select tenant_id into v_tenant from public.fin_manual_journals where id = p_journal_id;
  if v_tenant is null then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;

  for v_bad in
    select l.line_no, ga.account_code, ga.name,
           l.subledger_source_type, l.subledger_source_id, l.gl_account_id
      from public.fin_manual_journal_lines l
      join public.gl_accounts ga on ga.id = l.gl_account_id and ga.tenant_id = l.tenant_id
     where l.journal_id = p_journal_id
       and ga.is_control_account
     order by l.line_no
  loop
    if v_bad.subledger_source_type is null or v_bad.subledger_source_id is null then
      raise exception 'FIN_MANUAL_JOURNAL_CONTROL: line % posts to control account % (%) with no subledger reference. A control account is the total of its subledger, so a manual line on it makes the ledger disagree with the subledger with nothing to reconcile against. Name the open item this line belongs to.',
        v_bad.line_no, v_bad.account_code, v_bad.name;
    end if;

    -- The reference must resolve to a real open item, in this company, on a control
    -- role that actually posts to this account. Naming an item that is not there is
    -- worse than naming none, because it looks reconciled.
    if not exists (
      select 1
        from public.fin_open_items i
        join public.gl_posting_rules r
          on r.tenant_id = i.tenant_id
         and r.account_role = i.control_role
       where i.tenant_id = v_tenant
         and i.source_type = v_bad.subledger_source_type
         and i.source_id = v_bad.subledger_source_id
         and r.gl_account_id = v_bad.gl_account_id
    ) then
      raise exception 'FIN_MANUAL_JOURNAL_CONTROL: line % names subledger item %s:%s on control account % (%), but no open item of that type and id exists on that account in this company. A reference that does not resolve is worse than none: it looks reconciled.',
        v_bad.line_no, v_bad.subledger_source_type, v_bad.subledger_source_id,
        v_bad.account_code, v_bad.name;
    end if;
  end loop;
end $$;

revoke all on function public.fin_manual_journal_check_control_lines(uuid) from public, anon;
grant execute on function public.fin_manual_journal_check_control_lines(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Raising a manual journal
-- ---------------------------------------------------------------------
create or replace function public.fin_create_manual_journal(
  p_entry_date date,
  p_purpose text,
  p_reference text,
  p_lines jsonb
) returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.fin_manual_journals%rowtype;
  v_line   jsonb;
  v_no     integer := 0;
  v_dr     numeric := 0;
  v_cr     numeric := 0;
  v_acct   public.gl_accounts%rowtype;
  v_ccy    text;
begin
  if v_tenant is null then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: no company in context' using errcode = '42501';
  end if;
  if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: writing a manual journal needs the finance role or company administration' using errcode = '42501';
  end if;
  if p_entry_date is null then
    raise exception 'FIN_MANUAL_JOURNAL_INPUT: an entry date is required';
  end if;
  if p_entry_date > public.ins_local_today() then
    raise exception 'FIN_MANUAL_JOURNAL_INPUT: a manual journal cannot be dated in the future (%). Post it on the day.', p_entry_date;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'FIN_MANUAL_JOURNAL_INPUT: a journal needs at least two lines';
  end if;
  if exists (select 1 from public.accounting_periods
              where tenant_id = v_tenant and status = 'closed'
                and p_entry_date between period_start and period_end) then
    raise exception 'FIN_MANUAL_JOURNAL_PERIOD: % falls in a closed accounting period', p_entry_date;
  end if;

  v_ccy := public.fin_ledger_currency(v_tenant);

  insert into public.fin_manual_journals
    (tenant_id, entry_date, purpose, reference, currency, requested_by)
  values (v_tenant, p_entry_date, btrim(p_purpose), btrim(p_reference), v_ccy, auth.uid())
  returning * into v_row;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;

    select * into v_acct from public.gl_accounts
     where id = (v_line ->> 'gl_account_id')::uuid and tenant_id = v_tenant;
    if not found then
      raise exception 'FIN_MANUAL_JOURNAL_ACCOUNT: line % names an account that is not in this company''s chart', v_no using errcode = '42501';
    end if;
    -- Refuse the obvious structural mistakes with a sentence rather than letting a
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
    -- posting fail later on a control total.
    if v_acct.is_header then
      raise exception 'FIN_MANUAL_JOURNAL_ACCOUNT: line % posts to % (%), which is a header account. Post to the account below it.', v_no, v_acct.account_code, v_acct.name;
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
    -- posting fail later on a control total. gl_accounts has no header concept -- its
    -- columns are code, name, type, is_control_account and is_active -- so the check is
    -- the one the chart can actually support.
    if v_acct.is_control_account then
      raise exception 'FIN_MANUAL_JOURNAL_ACCOUNT: line % posts to % (%), which is a control account. A manual journal may not post to a control account; post to the subledger instead.', v_no, v_acct.account_code, v_acct.name;
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
    -- posting fail later on a control total.
    if v_acct.is_header then
      raise exception 'FIN_MANUAL_JOURNAL_ACCOUNT: line % posts to % (%), which is a header account. Post to the account below it.', v_no, v_acct.account_code, v_acct.name;
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
    -- posting fail later on a control total. gl_accounts has no header concept -- its
    -- columns are code, name, type, is_control_account and is_active -- so the check is
    -- the one the chart can actually support.
    -- A control account line is allowed only with a subledger reference; the reference is
    -- then checked for realness by fin_manual_journal_check_control_lines() once the lines
    -- are written. A blanket ban here contradicted that function and this pack's own §4,
    -- which says a named open item behind the line is exactly the evidence required --
    -- without a reference the line is refused below, before the totals are compared, so the
    -- 'name the item' case is still reported as FIN_MANUAL_JOURNAL_CONTROL and not as an
    -- unknown account.
    if v_acct.is_control_account
       and (nullif(btrim(coalesce(v_line ->> 'subledger_source_type', '')), '') is null
            or nullif(v_line ->> 'subledger_source_id', '') is null) then
      raise exception 'FIN_MANUAL_JOURNAL_CONTROL: line % posts to control account % (%) with no subledger reference. A control account is the total of its subledger, so a manual line on it makes the ledger disagree with the subledger with nothing to reconcile against. Name the open item this line belongs to.', v_no, v_acct.account_code, v_acct.name;
>>>>>>> theirs
    end if;
    if not v_acct.is_active then
      raise exception 'FIN_MANUAL_JOURNAL_ACCOUNT: line % posts to % (%), which is inactive.', v_no, v_acct.account_code, v_acct.name;
    end if;

    v_dr := v_dr + coalesce((v_line ->> 'debit')::numeric, 0);
    v_cr := v_cr + coalesce((v_line ->> 'credit')::numeric, 0);

    insert into public.fin_manual_journal_lines
      (tenant_id, journal_id, line_no, gl_account_id, debit, credit, description,
       subledger_source_type, subledger_source_id)
    values
      (v_tenant, v_row.id, v_no, v_acct.id,
       coalesce((v_line ->> 'debit')::numeric, 0),
       coalesce((v_line ->> 'credit')::numeric, 0),
       nullif(btrim(coalesce(v_line ->> 'description', '')), ''),
       nullif(btrim(coalesce(v_line ->> 'subledger_source_type', '')), ''),
       nullif(v_line ->> 'subledger_source_id', '')::uuid);
  end loop;

  -- Unbalanced is refused here, at the point the person can fix it, rather than at the
  -- ledger's deferred trigger with a message about an entry id they have never seen.
  if v_dr <> v_cr then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %. Correct the lines (debit-credit = %).', v_dr, v_cr, v_dr - v_cr;
  end if;

  perform public.fin_manual_journal_check_control_lines(v_row.id);

  update public.fin_manual_journals
     set total_debit = v_dr, total_credit = v_cr
   where id = v_row.id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.fin_create_manual_journal(date, text, text, jsonb) from public, anon;
grant execute on function public.fin_create_manual_journal(date, text, text, jsonb) to authenticated;

-- Re-checking the control rule when a draft is submitted, in case a line was added by
-- another route between creation and submission.
create or replace function public.fin_submit_manual_journal(p_journal_id uuid)
returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row public.fin_manual_journals%rowtype;
begin
  select * into v_row from public.fin_manual_journals
   where id = p_journal_id and tenant_id = public.get_my_tenant_id() for update;
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: only a draft can be submitted (this one is %)', v_row.status;
  end if;
  if v_row.requested_by <> auth.uid() and not public.is_tenant_admin() then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: only the person who raised it can submit it' using errcode = '42501';
  end if;

  perform public.fin_manual_journal_check_control_lines(v_row.id);

  if v_row.total_debit <> v_row.total_credit or v_row.total_debit = 0 then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %', v_row.total_debit, v_row.total_credit;
  end if;

  update public.fin_manual_journals
     set status = 'pending_approval', submitted_by = auth.uid(), submitted_at = now()
   where id = v_row.id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.fin_submit_manual_journal(uuid) from public, anon;
grant execute on function public.fin_submit_manual_journal(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Approving: nothing posts until a second person signs
-- ---------------------------------------------------------------------
-- Approval is what creates the ledger entry, in one transaction: there is no window in
-- which a journal is approved but unposted, or posted but unapproved.
create or replace function public.fin_decide_manual_journal(
  p_journal_id uuid,
  p_decision text,
  p_note text
) returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.fin_manual_journals%rowtype;
  v_lines  jsonb := '[]'::jsonb;
  v_je     public.journal_entries%rowtype;
  v_line   record;
begin
  if p_decision not in ('approve', 'reject') then
    raise exception 'FIN_MANUAL_JOURNAL_INPUT: decision must be approve or reject';
  end if;
  if p_decision = 'reject' and length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'FIN_MANUAL_JOURNAL_REASON: say why it is being rejected';
  end if;

  select * into v_row from public.fin_manual_journals
   where id = p_journal_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;
  if v_row.status <> 'pending_approval' then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: only a submitted journal can be decided (this one is %)', v_row.status;
  end if;

  -- The pack's second criterion, and the reason this surface exists at all.
  if v_row.requested_by = auth.uid() then
    raise exception 'FIN_MANUAL_JOURNAL_SELF_APPROVAL: a manual journal must be approved by someone other than the person who wrote it';
  end if;
  if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: approving a manual journal needs the finance role or company administration' using errcode = '42501';
  end if;

  if p_decision = 'reject' then
    update public.fin_manual_journals
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(),
           decision_note = btrim(p_note)
     where id = v_row.id
    returning * into v_row;
    return v_row;
  end if;

  -- Belt and braces: the rule was checked at submission, but the check is cheap and
  -- the failure it prevents is expensive.
  perform public.fin_manual_journal_check_control_lines(v_row.id);
  if v_row.total_debit <> v_row.total_credit or v_row.total_debit = 0 then
    raise exception 'FIN_MANUAL_JOURNAL_UNBALANCED: debits total % and credits total %', v_row.total_debit, v_row.total_credit;
  end if;

  for v_line in
    select l.gl_account_id, l.debit, l.credit, l.description
      from public.fin_manual_journal_lines l
     where l.journal_id = v_row.id
     order by l.line_no
  loop
    v_lines := v_lines || jsonb_build_object(
      'gl_account_id', v_line.gl_account_id,
      'debit', v_line.debit,
      'credit', v_line.credit,
      'description', v_line.description);
  end loop;

  -- The ledger primitive stays unexecutable by `authenticated`; this function is the
  -- only caller, and only after the checks above. Marked 'manual' so the existing
  -- reports that already look for source_type = 'manual' keep working.
  v_je := public.post_journal_entry(
            v_tenant, 'manual', v_row.id, v_row.entry_date,
            v_row.purpose || ' [' || v_row.reference || ']', v_lines);

  update public.fin_manual_journals
     set status = 'posted', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         journal_entry_id = v_je.id, posted_at = now(),
         journal_no = public.next_doc_number(v_tenant, 'fin_manual_journal', 'MJ')
   where id = v_row.id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.fin_decide_manual_journal(uuid, text, text) from public, anon;
grant execute on function public.fin_decide_manual_journal(uuid, text, text) to authenticated;

-- Anything still open can be withdrawn by the person who raised it (or an admin), so a
-- mistake does not sit in the approval queue forever.
create or replace function public.fin_withdraw_manual_journal(p_journal_id uuid, p_reason text)
returns public.fin_manual_journals
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row public.fin_manual_journals%rowtype;
begin
  select * into v_row from public.fin_manual_journals
   where id = p_journal_id and tenant_id = public.get_my_tenant_id() for update;
  if not found then
    raise exception 'FIN_MANUAL_JOURNAL_NOT_FOUND: manual journal';
  end if;
  if v_row.status in ('posted', 'withdrawn', 'rejected') then
    raise exception 'FIN_MANUAL_JOURNAL_STATE: this journal is already %', v_row.status;
  end if;
  if v_row.requested_by <> auth.uid() and not public.is_tenant_admin() then
    raise exception 'FIN_MANUAL_JOURNAL_FORBIDDEN: only the person who raised it can withdraw it' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'FIN_MANUAL_JOURNAL_REASON: say why it is being withdrawn';
  end if;

  update public.fin_manual_journals
     set status = 'withdrawn', rejection_reason = btrim(p_reason),
         decided_by = coalesce(decided_by, auth.uid()), decided_at = coalesce(decided_at, now())
   where id = v_row.id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.fin_withdraw_manual_journal(uuid, text) from public, anon;
grant execute on function public.fin_withdraw_manual_journal(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Prove it is installable
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'fin_manual_journals') then
    raise exception 'B6: fin_manual_journals was not created';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'trg_check_journal_entry_balanced'
                    and tgdeferrable and tginitdeferred) then
    raise exception 'B6: the deferred balance trigger this builds on is missing';
  end if;
  raise notice 'PASS: B6 manual journals are installable, and the balance control it relies on is still in place';
end $$;
