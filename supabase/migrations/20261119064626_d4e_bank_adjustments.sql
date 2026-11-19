-- ============================================================================
-- D4e: Bank Reconciliation Adjustments
-- ----------------------------------------------------------------------------
-- Post adjustments for bank statement lines that have no book entry, with
-- independent second-person approval, atomic journal posting + reconciliation,
-- and full audit history.
--
-- Decisions implemented (confirmed with finance / accountant):
--   Q1  Counter-account: finance picks any GL account per adjustment,
--       validated (active, postable, not control, not header, not bank/cash).
--   Q2  Independent approval: a second finance user must approve; enforced in
--       the database transaction (creator <> approver).
--   §7.1 Journal date = bank statement date; closed/locked period blocks
--        approval (no silent date moves).
--   §7.2 Control accounts (AR/AP) are rejected by default.
--   §7.3 Reversal requires the same independent approval flow.
--   Tax codes: deferred entirely; not stored, no tax GL lines (unsafe journal
--              balancing until gross/net treatment is designed).
--   Self-approval: only via the explicitly approved company-level accounting
--              setting 'allow_self_approved_bank_adjustments' (default false);
--              flagged self_approved and surfaced in the exception report.
--   Rejected adjustments: never edited; creator resubmits a new linked row
--              (reworked_from). Original stays in audit history.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- File content matches the migration applied to the live project as version
-- 20261119064626 (d4e_bank_adjustments), with one deliberate difference:
-- the CREATE POLICY statements carry an explicit `to authenticated`
-- (MIGRATION_POLICY.md rule 10). This is a functional no-op (a policy with no
-- TO clause applies to PUBLIC, and `anon` holds no table privileges since
-- 20261112090000). The follow-up 20261119120000_d4e_bank_adjustments_policy_roles.sql
-- rewrites the live policies to match.
-- 0. Header-account flag on gl_accounts so "headers are not postable" is
--    enforceable. Existing rows default to false (postable); finance should
--    mark summary accounts.
-- ----------------------------------------------------------------------------
alter table public.gl_accounts
  add column if not exists is_header boolean not null default false;
comment on column public.gl_accounts.is_header is
  'True for summary/header accounts that group children. Not postable. Bank adjustments reject them.';

-- ----------------------------------------------------------------------------
-- 1. Core table: bank_adjustments
--    Snapshot columns carry the line facts at submission for audit display.
--    The bank statement line remains the source of truth; amount is always
--    the line's amount (abs) and is never accepted from the user.
-- ----------------------------------------------------------------------------
create table if not exists public.bank_adjustments (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenants(id) on delete cascade,
  kind                    text not null default 'adjustment'
                          check (kind in ('adjustment', 'reversal')),
  bank_statement_line_id  uuid not null references public.bank_statement_lines(id),
  bank_account            text not null,
  statement_date          date not null,
  amount                  numeric(20,2) not null check (amount > 0),
  currency                text not null,
  direction               text not null check (direction in ('in','out')),
  counter_account_id      uuid not null references public.gl_accounts(id),
  reason                  text not null check (length(btrim(reason)) >= 5),
  status                  text not null default 'pending'
                          check (status in ('pending','posted','rejected','reversed')),
  journal_entry_id        uuid references public.journal_entries(id),
  reverses_adjustment_id  uuid references public.bank_adjustments(id),
  reworked_from           uuid references public.bank_adjustments(id),
  rejection_reason        text,
  reversal_journal_entry_id uuid references public.journal_entries(id),
  reversal_reason         text,
  reversed_by             uuid,
  reversed_at             timestamptz,
  self_approved           boolean not null default false,
  created_by              uuid not null default public.effective_user_id(),
  created_at              timestamptz not null default now(),
  decided_by              uuid,
  decided_at              timestamptz,
  updated_at              timestamptz not null default now(),
  constraint bank_adjustments_reversal_link_check check (
    (kind = 'adjustment' and reverses_adjustment_id is null)
    or (kind = 'reversal' and reverses_adjustment_id is not null)
  )
);
comment on table public.bank_adjustments is
  'D4e bank-reconciliation adjustment workflow: pending -> posted | rejected; posted -> reversed. Amount derived from the bank statement line, never user-entered.';

-- One live (pending or posted) adjustment per statement line.
-- Reversal rows (kind='reversal') never hold the line reconciled, so they are
-- excluded from the uniqueness rule.
create unique index if not exists bank_adjustments_one_live_per_line
  on public.bank_adjustments (bank_statement_line_id)
  where status in ('pending','posted') and kind = 'adjustment';
create index if not exists bank_adjustments_tenant_status_idx on public.bank_adjustments (tenant_id, status);
create index if not exists bank_adjustments_line_idx        on public.bank_adjustments (bank_statement_line_id);
create index if not exists bank_adjustments_reverses_idx    on public.bank_adjustments (reverses_adjustment_id);
create index if not exists bank_adjustments_journal_idx     on public.bank_adjustments (journal_entry_id);

-- ----------------------------------------------------------------------------
-- 2. Full decision history
-- ----------------------------------------------------------------------------
create table if not exists public.bank_adjustment_events (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  adjustment_id  uuid not null references public.bank_adjustments(id) on delete cascade,
  event          text not null check (event in
                   ('created','reworked','approved','rejected','reversal_requested','reversed')),
  actor_id       uuid not null default public.effective_user_id(),
  note           text,
  created_at     timestamptz not null default now()
);
create index if not exists bank_adjustment_events_adj_idx on public.bank_adjustment_events (adjustment_id, created_at);
create index if not exists bank_adjustment_events_tenant_idx on public.bank_adjustment_events (tenant_id, created_at);

-- ----------------------------------------------------------------------------
-- 3. Configurable "usual suspects" accounts for the Unusual Account Usage report
-- ----------------------------------------------------------------------------
create table if not exists public.bank_adjustment_usual_accounts (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  gl_account_id  uuid not null references public.gl_accounts(id) on delete cascade,
  created_by     uuid not null default public.effective_user_id(),
  created_at     timestamptz not null default now(),
  unique (tenant_id, gl_account_id)
);

-- ----------------------------------------------------------------------------
-- 4. Let bank_reconciliations point at an adjustment (it currently requires
--    exactly one of settlement / cash_bank_transaction / commission_transfer).
-- ----------------------------------------------------------------------------
alter table public.bank_reconciliations
  add column if not exists bank_adjustment_id uuid references public.bank_adjustments(id);

alter table public.bank_reconciliations
  drop constraint if exists bank_reconciliations_one_source_check;
alter table public.bank_reconciliations
  add constraint bank_reconciliations_one_source_check
  check (num_nonnulls(cash_bank_transaction_id, settlement_id,
                      commission_transfer_id, bank_adjustment_id) = 1);

create unique index if not exists bank_reconciliations_adjustment_unique
  on public.bank_reconciliations (bank_adjustment_id);

-- ----------------------------------------------------------------------------
-- 5. Immutability / transition guard for adjustments
-- ----------------------------------------------------------------------------
create or replace function public.bank_adjustments_mutation_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception 'BANK_ADJ_NO_DELETE: bank adjustments are never deleted; reverse a posted adjustment instead';
  end if;

  -- Only the D4e RPCs may change rows.
  if coalesce(current_setting('app.bank_adjustment_rpc', true), '') <> 'on' then
    raise exception 'BANK_ADJ_IMMUTABLE: bank adjustments can only be changed through the adjustment workflow functions';
  end if;

  -- Snapshot columns never change under any circumstances.
  if new.tenant_id is distinct from old.tenant_id
     or new.kind is distinct from old.kind
     or new.bank_statement_line_id is distinct from old.bank_statement_line_id
     or new.bank_account is distinct from old.bank_account
     or new.statement_date is distinct from old.statement_date
     or new.amount is distinct from old.amount
     or new.currency is distinct from old.currency
     or new.direction is distinct from old.direction
     or new.counter_account_id is distinct from old.counter_account_id
     or new.reason is distinct from old.reason
     or new.reverses_adjustment_id is distinct from old.reverses_adjustment_id
     or new.reworked_from is distinct from old.reworked_from
     or new.created_by is distinct from old.created_by then
    raise exception 'BANK_ADJ_SNAPSHOT: the submitted adjustment (line, amount, account, reason) is immutable';
  end if;

  -- Valid status transitions only.
  if (old.status, new.status) not in (('pending','posted'), ('pending','rejected'), ('posted','reversed')) then
    if new.status = old.status then
      return new;  -- e.g. touching updated_at only
    end if;
    raise exception 'BANK_ADJ_TRANSITION: % -> % is not a valid adjustment transition', old.status, new.status;
  end if;

  return new;
end;
$function$;

drop trigger if exists bank_adjustments_mutation_guard on public.bank_adjustments;
create trigger bank_adjustments_mutation_guard
  before update or delete on public.bank_adjustments
  for each row execute function public.bank_adjustments_mutation_guard();

-- ----------------------------------------------------------------------------
-- 6. Reconciliation guard:
--    - a pending adjustment blocks the line being reconciled by another flow
--    - reconciliation rows owned by a posted adjustment cannot be removed
--      except through the reversal RPC
-- ----------------------------------------------------------------------------
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
                  and a.status = 'pending') then
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

drop trigger if exists bank_reconciliation_adjustment_guard on public.bank_reconciliations;
create trigger bank_reconciliation_adjustment_guard
  before insert or update or delete on public.bank_reconciliations
  for each row execute function public.bank_reconciliation_adjustment_guard();

-- ----------------------------------------------------------------------------
-- 7. Shared validations
-- ----------------------------------------------------------------------------
create or replace function public.bank_adjustment_validate_counter(p_tenant_id uuid, p_counter_account_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_acct public.gl_accounts%rowtype;
begin
  select * into v_acct
    from public.gl_accounts
   where id = p_counter_account_id and tenant_id = p_tenant_id;
  if not found then
    raise exception 'ADJ_COUNTER_NOT_FOUND: that counter-account does not exist in this company' using errcode = '42501';
  end if;
  if not v_acct.is_active then
    raise exception 'ADJ_COUNTER_INACTIVE: % % is inactive', v_acct.account_code, v_acct.name;
  end if;
  if v_acct.is_header then
    raise exception 'ADJ_COUNTER_HEADER: % % is a header account and cannot be posted to', v_acct.account_code, v_acct.name;
  end if;
  if v_acct.is_control_account then
    raise exception 'ADJ_COUNTER_CONTROL: % % is a control account (receivables/payables) and is blocked for bank adjustments', v_acct.account_code, v_acct.name;
  end if;
  if exists (select 1 from public.fin_bank_accounts b
              where b.tenant_id = p_tenant_id and b.gl_account_id = v_acct.id)
     or exists (select 1 from public.gl_posting_rules r
              where r.tenant_id = p_tenant_id and r.gl_account_id = v_acct.id
                and r.account_role in ('bank', 'cash', 'client_money_bank')) then
    raise exception 'ADJ_COUNTER_BANK: % % is a bank/cash/client-money GL account and cannot be the counter-account', v_acct.account_code, v_acct.name;
  end if;
end;
$function$;

create or replace function public.bank_adjustment_check_period(p_tenant_id uuid, p_date date)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if exists (select 1 from public.accounting_periods
              where tenant_id = p_tenant_id
                and status in ('closed', 'locked')
                and p_date between period_start and period_end) then
    raise exception 'ADJ_PERIOD_CLOSED: % falls in a closed or locked accounting period; use the accounting-period process instead of posting an adjustment', p_date;
  end if;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 8. RPCs
-- ----------------------------------------------------------------------------

-- 8.1 Create (or rework a rejected) adjustment. Saves a PENDING row only.
create or replace function public.create_bank_adjustment(
  p_statement_line_id uuid,
  p_counter_account_id uuid,
  p_reason text,
  p_reworked_from uuid default null
)
returns public.bank_adjustments
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_actor  uuid := public.effective_user_id();
  v_line   public.bank_statement_lines%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_adj    public.bank_adjustments%rowtype;
  v_rework public.bank_adjustments%rowtype;
  v_event  text := 'created';
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: creating a bank adjustment requires the finance role' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'ADJ_REASON: a reason of at least 5 characters is required';
  end if;

  select * into v_line
    from public.bank_statement_lines
   where id = p_statement_line_id and tenant_id = v_tenant
   for key share;
  if not found then
    raise exception 'ADJ_LINE_NOT_FOUND: statement line not found in this company' using errcode = '42501';
  end if;

  if exists (select 1 from public.bank_reconciliations r where r.bank_statement_line_id = v_line.id) then
    raise exception 'ADJ_LINE_RECONCILED: this statement line is already reconciled';
  end if;

  if exists (select 1 from public.bank_adjustments a
              where a.bank_statement_line_id = v_line.id
                and a.kind = 'adjustment'
                and a.status in ('pending', 'posted')) then
    raise exception 'ADJ_LIVE_EXISTS: an adjustment for this statement line is already pending or posted';
  end if;

  perform public.bank_adjustment_validate_counter(v_tenant, p_counter_account_id);
  perform public.bank_adjustment_check_period(v_tenant, v_line.statement_date);

  if p_reworked_from is not null then
    select * into v_rework
      from public.bank_adjustments
     where id = p_reworked_from and tenant_id = v_tenant;
    if not found then
      raise exception 'ADJ_REWORK_NOT_FOUND: the adjustment being reworked was not found' using errcode = '42501';
    end if;
    if v_rework.kind <> 'adjustment' or v_rework.status <> 'rejected' then
      raise exception 'ADJ_REWORK_STATE: only a rejected adjustment can be reworked';
    end if;
    if v_rework.bank_statement_line_id <> v_line.id then
      raise exception 'ADJ_REWORK_LINE: a rework must reference the same statement line as the rejected adjustment';
    end if;
    v_event := 'reworked';
  end if;

  perform set_config('app.bank_adjustment_rpc', 'on', true);
  insert into public.bank_adjustments (
    tenant_id, kind, bank_statement_line_id, bank_account, statement_date,
    amount, currency, direction, counter_account_id, reason,
    status, reworked_from, created_by
  ) values (
    v_tenant, 'adjustment', v_line.id, v_line.bank_account, v_line.statement_date,
    abs(v_line.amount), v_line.currency, case when v_line.amount >= 0 then 'in' else 'out' end,
    p_counter_account_id, v_reason,
    'pending', p_reworked_from, v_actor
  ) returning * into v_adj;
  perform set_config('app.bank_adjustment_rpc', 'off', true);

  insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, note)
  values (v_tenant, v_adj.id, v_event, v_actor,
          case when p_reworked_from is not null then 'rework of adjustment ' || p_reworked_from::text end);

  return v_adj;
end;
$function$;

-- 8.2 Request reversal of a posted adjustment. Creates a PENDING reversal row;
--      needs the same independent approval before anything is posted.
create or replace function public.request_bank_adjustment_reversal(
  p_adjustment_id uuid,
  p_reason text
)
returns public.bank_adjustments
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_actor  uuid := public.effective_user_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_orig   public.bank_adjustments%rowtype;
  v_adj    public.bank_adjustments%rowtype;
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: requesting a reversal requires the finance role' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'ADJ_REASON: a reason of at least 5 characters is required for a reversal';
  end if;

  select * into v_orig
    from public.bank_adjustments
   where id = p_adjustment_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'ADJ_NOT_FOUND: adjustment % not found', p_adjustment_id using errcode = '42501';
  end if;
  if v_orig.kind <> 'adjustment' or v_orig.status <> 'posted' then
    raise exception 'ADJ_REVERSAL_STATE: only a posted adjustment can be reversed (status %)', v_orig.status;
  end if;
  if exists (select 1 from public.bank_adjustments a
              where a.reverses_adjustment_id = v_orig.id and a.status = 'pending') then
    raise exception 'ADJ_REVERSAL_PENDING: a reversal of this adjustment is already pending approval';
  end if;

  perform set_config('app.bank_adjustment_rpc', 'on', true);
  insert into public.bank_adjustments (
    tenant_id, kind, bank_statement_line_id, bank_account, statement_date,
    amount, currency, direction, counter_account_id, reason,
    status, reverses_adjustment_id, created_by
  ) values (
    v_tenant, 'reversal', v_orig.bank_statement_line_id, v_orig.bank_account, v_orig.statement_date,
    v_orig.amount, v_orig.currency, case when v_orig.direction = 'out' then 'in' else 'out' end,
    v_orig.counter_account_id, v_reason,
    'pending', v_orig.id, v_actor
  ) returning * into v_adj;
  perform set_config('app.bank_adjustment_rpc', 'off', true);

  insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, note)
  values (v_tenant, v_adj.id, 'reversal_requested', v_actor,
          'reversal of adjustment ' || v_orig.id::text);

  return v_adj;
end;
$function$;

-- 8.3 Approve (or self-approve under the approved exception). Posts the
--      journal, reconciles the line and marks the adjustment posted — atomically.
--      For a reversal request, posts the offsetting journal, un-reconciles the
--      line and marks the original adjustment reversed — atomically.
create or replace function public.approve_bank_adjustment(p_adjustment_id uuid)
returns public.bank_adjustments
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  v_actor   uuid := public.effective_user_id();
  v_adj     public.bank_adjustments%rowtype;
  v_orig    public.bank_adjustments%rowtype;
  v_line    public.bank_statement_lines%rowtype;
  v_bank    public.fin_bank_accounts%rowtype;
  v_entry   public.journal_entries%rowtype;
  v_lines   jsonb;
  v_desc    text;
  v_self    boolean := false;
  v_setting jsonb;
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: approving a bank adjustment requires the finance role' using errcode = '42501';
  end if;

  select * into v_adj
    from public.bank_adjustments
   where id = p_adjustment_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'ADJ_NOT_FOUND: adjustment % not found', p_adjustment_id using errcode = '42501';
  end if;
  if v_adj.status <> 'pending' then
    raise exception 'ADJ_NOT_PENDING: this adjustment is already %', v_adj.status;
  end if;

  -- Revalidate the line and the counter-account at approval time.
  select * into v_line
    from public.bank_statement_lines
   where id = v_adj.bank_statement_line_id and tenant_id = v_tenant
   for key share;
  if not found then
    raise exception 'ADJ_LINE_STALE: the statement line no longer exists';
  end if;
  perform public.bank_adjustment_validate_counter(v_tenant, v_adj.counter_account_id);

  -- Independent approval: creator cannot approve their own submission unless
  -- the company has an explicitly approved one-person exception.
  if v_actor = v_adj.created_by then
    v_setting := public.acct_get_setting('allow_self_approved_bank_adjustments', current_date);
    if coalesce(v_setting ->> 'value', 'false') <> 'true' then
      raise exception 'ADJ_SELF_APPROVAL_FORBIDDEN: the creator cannot approve their own adjustment; a different Finance user must approve' using errcode = '42501';
    end if;
    v_self := true;
  end if;

  if v_adj.kind = 'adjustment' then
    -- The line must still be unreconciled at approval time.
    if exists (select 1 from public.bank_reconciliations r where r.bank_statement_line_id = v_line.id) then
      raise exception 'ADJ_LINE_RECONCILED: this statement line was reconciled since the adjustment was created';
    end if;
    perform public.bank_adjustment_check_period(v_tenant, v_adj.statement_date);

    select * into v_bank
      from public.fin_bank_accounts
     where tenant_id = v_tenant and name = v_adj.bank_account
     for share;
    if not found then
      raise exception 'ADJ_BANK_MISSING: no bank account named % is configured for this line', v_adj.bank_account;
    end if;
    if v_bank.gl_account_id is null then
      raise exception 'ADJ_BANK_GL_MISSING: bank account % has no GL account mapped', v_bank.name;
    end if;

    v_desc := left('Bank adjustment - ' || coalesce(v_line.reference, v_line.description, 'statement line') || ': ' || v_adj.reason, 240);
    if v_adj.direction = 'out' then
      v_lines := jsonb_build_array(
        jsonb_build_object('gl_account_id', v_adj.counter_account_id, 'debit',  v_adj.amount, 'currency', v_adj.currency, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_bank.gl_account_id,     'credit', v_adj.amount, 'currency', v_adj.currency, 'description', v_desc));
    else
      v_lines := jsonb_build_array(
        jsonb_build_object('gl_account_id', v_bank.gl_account_id,     'debit',  v_adj.amount, 'currency', v_adj.currency, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_adj.counter_account_id, 'credit', v_adj.amount, 'currency', v_adj.currency, 'description', v_desc));
    end if;

    -- One transaction: post journal -> insert reconciliation -> mark posted.
    v_entry := public.post_journal_entry(v_tenant, 'bank_adjustment', v_adj.id,
                                         v_adj.statement_date, v_desc, v_lines);

    perform set_config('app.bank_adjustment_rpc', 'on', true);
    insert into public.bank_reconciliations (tenant_id, bank_statement_line_id, match_type, variance, matched_by, bank_adjustment_id)
    values (v_tenant, v_line.id, 'manual', 0, v_actor, v_adj.id);
    update public.bank_adjustments
       set status = 'posted', journal_entry_id = v_entry.id, decided_by = v_actor,
           decided_at = now(), self_approved = v_self, updated_at = now()
     where id = v_adj.id
    returning * into v_adj;
    perform set_config('app.bank_adjustment_rpc', 'off', true);

    insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, note)
    values (v_tenant, v_adj.id, 'approved', v_actor,
            'posted via journal ' || v_entry.id::text || case when v_self then ' (self-approved under approved one-person exception)' else '' end);

    perform public.fin_audit_record(v_tenant, v_entry.id, 'approved',
      case when v_self then 'self-approved under approved one-person exception' end);
    return v_adj;
  end if;

  -- ---------------- kind = 'reversal' ----------------
  select * into v_orig
    from public.bank_adjustments
   where id = v_adj.reverses_adjustment_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'ADJ_REVERSAL_ORPHAN: the adjustment being reversed no longer exists';
  end if;
  if v_orig.status <> 'posted' then
    raise exception 'ADJ_REVERSAL_STALE: the adjustment being reversed is no longer posted (status %)', v_orig.status;
  end if;
  perform public.bank_adjustment_check_period(v_tenant, current_date);

  v_desc := left('Reversal of bank adjustment ' || v_orig.id::text || ': ' || v_adj.reason, 240);
  select jsonb_agg(jsonb_build_object(
           'gl_account_id', jel.gl_account_id,
           'debit',         jel.credit,
           'credit',        jel.debit,
           'currency',      jel.currency,
           'fx_rate',       jel.fx_rate,
           'is_rounding',   jel.is_rounding,
           'description',   'Reversal of ' || v_orig.journal_entry_id::text || ': ' || coalesce(jel.description, '')))
    into v_lines
    from public.journal_entry_lines jel
   where jel.journal_entry_id = v_orig.journal_entry_id;

  perform set_config('fin.reversal_of', v_orig.journal_entry_id::text, true);
  v_entry := public.post_journal_entry(v_tenant, 'bank_adjustment_reversal', v_adj.id,
                                       current_date, v_desc, v_lines);
  perform set_config('fin.reversal_of', '', true);

  -- One transaction: reversal journal -> un-reconcile the line -> mark both rows.
  perform set_config('app.bank_adjustment_rpc', 'on', true);
  delete from public.bank_reconciliations where bank_adjustment_id = v_orig.id;
  update public.bank_adjustments
     set status = 'reversed', reversed_by = v_actor, reversed_at = now(),
         reversal_reason = v_adj.reason, reversal_journal_entry_id = v_entry.id, updated_at = now()
   where id = v_orig.id;
  update public.bank_adjustments
     set status = 'posted', journal_entry_id = v_entry.id, decided_by = v_actor,
         decided_at = now(), self_approved = v_self, updated_at = now()
   where id = v_adj.id
  returning * into v_adj;
  perform set_config('app.bank_adjustment_rpc', 'off', true);

  insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, note)
  values (v_tenant, v_orig.id, 'reversed', v_actor, 'reversed via ' || v_entry.id::text || ': ' || v_adj.reason),
         (v_tenant, v_adj.id,  'approved', v_actor, 'reversal posted via journal ' || v_entry.id::text);

  perform public.fin_audit_record(v_tenant, v_entry.id, 'approved',
    case when v_self then 'self-approved under approved one-person exception' end);
  perform public.fin_audit_record(v_tenant, v_entry.id, 'reversed',
    'reversal of ' || v_orig.journal_entry_id::text, v_orig.journal_entry_id);

  return v_adj;
end;
$function$;

-- 8.4 Reject. No journal is posted; the reason is recorded.
create or replace function public.reject_bank_adjustment(p_adjustment_id uuid, p_reason text)
returns public.bank_adjustments
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_actor  uuid := public.effective_user_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_adj    public.bank_adjustments%rowtype;
begin
  if v_tenant is null then
    raise exception 'ADJ_NO_TENANT: no company in context' using errcode = '42501';
  end if;
  if not public.is_finance_team_member('finance') then
    raise exception 'not authorized: rejecting a bank adjustment requires the finance role' using errcode = '42501';
  end if;
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'ADJ_REASON: a rejection reason of at least 5 characters is required';
  end if;

  select * into v_adj
    from public.bank_adjustments
   where id = p_adjustment_id and tenant_id = v_tenant
   for update;
  if not found then
    raise exception 'ADJ_NOT_FOUND: adjustment % not found', p_adjustment_id using errcode = '42501';
  end if;
  if v_adj.status <> 'pending' then
    raise exception 'ADJ_NOT_PENDING: this adjustment is already %', v_adj.status;
  end if;

  perform set_config('app.bank_adjustment_rpc', 'on', true);
  update public.bank_adjustments
     set status = 'rejected', rejection_reason = v_reason, decided_by = v_actor,
         decided_at = now(), updated_at = now()
   where id = v_adj.id
  returning * into v_adj;
  perform set_config('app.bank_adjustment_rpc', 'off', true);

  insert into public.bank_adjustment_events (tenant_id, adjustment_id, event, actor_id, note)
  values (v_tenant, v_adj.id, 'rejected', v_actor, v_reason);

  return v_adj;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 9. Accountant reporting views
-- ----------------------------------------------------------------------------
create or replace view public.bank_adjustment_register
with (security_invoker = true) as
select
  a.id                  as adjustment_id,
  a.tenant_id,
  a.kind,
  a.status,
  a.bank_account,
  a.statement_date      as transaction_date,
  l.reference           as bank_line_reference,
  ga.account_code       as counter_account_code,
  ga.name               as counter_account_name,
  a.amount,
  a.currency,
  a.direction,
  a.reason              as description_reason,
  a.created_by,
  cu.name               as created_by_name,
  cu.email              as created_by_email,
  a.created_at,
  a.decided_by          as approver_id,
  du.name               as approver_name,
  du.email              as approver_email,
  a.decided_at          as approval_date,
  a.self_approved,
  a.rejection_reason,
  a.journal_entry_id    as posting_journal_reference,
  a.reworked_from,
  a.reverses_adjustment_id,
  a.reversal_journal_entry_id,
  a.reversed_at
from public.bank_adjustments a
join public.bank_statement_lines l on l.id = a.bank_statement_line_id
join public.gl_accounts ga        on ga.id = a.counter_account_id
left join public.app_users cu     on cu.id = a.created_by
left join public.app_users du     on du.id = a.decided_by;

-- Exception report: self-approved adjustments (one-person exception) for
-- accountant sign-off.
create or replace view public.bank_adjustment_exceptions
with (security_invoker = true) as
select * from public.bank_adjustment_register
where self_approved = true and status in ('posted', 'reversed');

-- Unusual Account Usage: posted adjustments whose counter-account is not in the
-- company's configurable usual-accounts list. Flags for review, not verdicts.
create or replace view public.bank_adjustment_unusual_accounts
with (security_invoker = true) as
select
  a.tenant_id,
  a.id                as adjustment_id,
  a.bank_account,
  a.statement_date,
  a.currency,
  a.amount,
  a.direction,
  ga.account_code     as counter_account_code,
  ga.name             as counter_account_name,
  a.reason,
  cu.name             as created_by_name,
  du.name             as approver_name,
  a.decided_at        as approval_date,
  a.journal_entry_id  as posting_journal_reference,
  a.self_approved
from public.bank_adjustments a
join public.gl_accounts ga    on ga.id = a.counter_account_id
left join public.app_users cu on cu.id = a.created_by
left join public.app_users du on du.id = a.decided_by
where a.status in ('posted', 'reversed')
  and a.kind = 'adjustment'
  and not exists (
    select 1 from public.bank_adjustment_usual_accounts u
     where u.tenant_id = a.tenant_id and u.gl_account_id = a.counter_account_id);

-- ----------------------------------------------------------------------------
-- 10. Row level security: RPC-only writes; finance-only reads
-- ----------------------------------------------------------------------------
alter table public.bank_adjustments enable row level security;
alter table public.bank_adjustment_events enable row level security;
alter table public.bank_adjustment_usual_accounts enable row level security;

drop policy if exists bank_adjustments_select on public.bank_adjustments;
create policy bank_adjustments_select on public.bank_adjustments
  for select to authenticated using (public.is_finance_team_member(null) and tenant_id = public.get_my_tenant_id());

drop policy if exists bank_adjustment_events_select on public.bank_adjustment_events;
create policy bank_adjustment_events_select on public.bank_adjustment_events
  for select to authenticated using (public.is_finance_team_member(null) and tenant_id = public.get_my_tenant_id());

drop policy if exists bank_adjustment_usual_accounts_select on public.bank_adjustment_usual_accounts;
create policy bank_adjustment_usual_accounts_select on public.bank_adjustment_usual_accounts
  for select to authenticated using (public.is_finance_team_member(null) and tenant_id = public.get_my_tenant_id());
drop policy if exists bank_adjustment_usual_accounts_insert on public.bank_adjustment_usual_accounts;
create policy bank_adjustment_usual_accounts_insert on public.bank_adjustment_usual_accounts
  for insert to authenticated with check (public.is_finance_team_member('finance') and tenant_id = public.get_my_tenant_id());
drop policy if exists bank_adjustment_usual_accounts_delete on public.bank_adjustment_usual_accounts;
create policy bank_adjustment_usual_accounts_delete on public.bank_adjustment_usual_accounts
  for delete to authenticated using (public.is_finance_team_member('finance') and tenant_id = public.get_my_tenant_id());

-- ----------------------------------------------------------------------------
-- 11. Grants: reads to authenticated; writes only through the RPCs
-- ----------------------------------------------------------------------------
grant select on public.bank_adjustments, public.bank_adjustment_events,
                public.bank_adjustment_usual_accounts
  to authenticated;
grant select on public.bank_adjustment_register, public.bank_adjustment_exceptions,
                public.bank_adjustment_unusual_accounts
  to authenticated;
grant insert, delete on public.bank_adjustment_usual_accounts -- config list only
  to authenticated;

revoke all on function public.bank_adjustment_validate_counter(uuid, uuid) from public, authenticated;
revoke all on function public.bank_adjustment_check_period(uuid, date) from public, authenticated;
grant execute on function public.create_bank_adjustment(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.request_bank_adjustment_reversal(uuid, text) to authenticated;
grant execute on function public.approve_bank_adjustment(uuid) to authenticated;
grant execute on function public.reject_bank_adjustment(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 12. Company-level one-person exception setting (off by default; requires
--     the accounting-settings approval workflow to switch on)
-- ----------------------------------------------------------------------------
insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, default_value, implemented_values, requires_legal_review)
select 'allow_self_approved_bank_adjustments',
       'Allow self-approved bank adjustments',
       'Permit a single authorised finance user (a genuinely one-person finance team) to approve their own bank adjustment. Off by default. When an approved setting enables it, such journals are flagged self_approved and listed in the accountant exception report.',
       array['true','false'], 'false', array['true','false'], true
where not exists (select 1 from public.accounting_setting_definitions
                   where key = 'allow_self_approved_bank_adjustments');
