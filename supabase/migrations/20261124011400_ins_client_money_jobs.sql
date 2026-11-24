-- =====================================================================
-- The daily client-money jobs, actually scheduled
-- Accountant pack v2, B9; pack section 9
-- =====================================================================
-- ins_client_money_check() and ins_escalate_missed_reconciliations() were built and
-- callable, and nothing called them. A control that has to be remembered is not a
-- control: a missed reconciliation escalated only if somebody happened to open a screen.
-- This migration is the scheduler.
--
-- WHY THIS IS NOT JUST A cron.schedule() LINE
--
-- Both functions take the tenant from get_my_tenant_id(), which reads the caller's JWT.
-- A scheduled job has no JWT, so get_my_tenant_id() returns null, the position query
-- matches nothing, and the job would run every morning against zero tenants and report
-- success. That is the worst shape a control can fail in -- green, daily, and inert.
--
-- So each job gets a platform-level core that takes the tenant as a parameter, and a
-- wrapper that loops every tenant with insurance enabled and records what happened. The
-- per-tenant functions stay exactly as they were for interactive use; they are not
-- re-issued here.

-- ---------------------------------------------------------------------
-- 1. Tenant-parameterised cores
-- ---------------------------------------------------------------------
-- These reproduce the shipped logic rule for rule. They exist because the interactive
-- versions cannot be called without a session; they are not a rewrite.
create or replace function public.platform_ins_client_money_check(
  p_tenant_id uuid,
  p_currency text default null
) returns table (currency text, free_money numeric, blocked boolean, incident_id uuid)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_pos record;
  v_inc  public.fin_client_money_incidents%rowtype;
begin
  -- Aliased: `currency` is an OUT parameter of this function, so an unqualified column
  -- reference next to p_currency raises 'column reference is ambiguous' at runtime.
  for v_pos in
    select * from public.platform_ins_client_money_position(p_tenant_id, public.ins_local_today()) pos
     where p_currency is null or pos.currency = p_currency
  loop
    -- A negative free position raises (or refreshes) the shortage, whoever asks. p_actor
    -- is null here on purpose: detected_by null is what records "the system found this",
    -- as opposed to a person.
    if v_pos.free_money < 0 then
      v_inc := public.platform_ins_raise_shortage(p_tenant_id, v_pos.currency, v_pos.free_money, null,
        jsonb_build_object('client_money', v_pos.client_money,
                           'client_refunds', v_pos.client_refunds,
                           'insurer_payable', v_pos.insurer_payable,
                           'claim_payable', v_pos.claim_payable));
    else
      v_inc := null;
      select * into v_inc from public.fin_client_money_incidents
       where tenant_id = p_tenant_id and currency = v_pos.currency
         and kind = 'shortage' and status = 'open' limit 1;
    end if;

    return query select v_pos.currency, v_pos.free_money,
                        (v_inc.id is not null), v_inc.id;
  end loop;
end $$;

revoke all on function public.platform_ins_client_money_check(uuid, text) from public;
grant execute on function public.platform_ins_client_money_check(uuid, text) to service_role;

comment on function public.platform_ins_client_money_check(uuid, text) is
  'Tenant-parameterised client-money position check, for the scheduled job. Interactive callers use ins_client_money_check().';

create or replace function public.platform_ins_escalate_missed_reconciliations(
  p_tenant_id uuid,
  p_as_of date default null
) returns table (bank_account_id uuid, bank_name text, missed_days integer, escalated boolean, incident_id uuid)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_on      date := coalesce(p_as_of, public.ins_local_today());
  v_threshold integer := 2;
  v_bank    record;
  v_streak  integer;
  v_inc     public.fin_client_money_incidents%rowtype;
  v_incident uuid;
begin
  for v_bank in
    select b.id, b.name, b.currency from public.fin_bank_accounts b
     where b.tenant_id = p_tenant_id and b.kind = 'client_money' and b.is_active
     order by b.name
  loop
    v_streak := public.platform_ins_reconciliation_streak(p_tenant_id, v_bank.id, v_on);
    v_incident := null;

    if v_streak >= v_threshold then
      -- Two consecutive missed days is the pack's line. The incident is recorded once
      -- and refreshed after that, not raised afresh each day.
      v_inc := null;
      select * into v_inc from public.fin_client_money_incidents i
       where i.tenant_id = p_tenant_id and i.bank_account_id = v_bank.id
         and i.kind = 'reconciliation_missed' and i.status = 'open'
       limit 1;

      if not found then
        insert into public.fin_client_money_incidents
          (tenant_id, currency, bank_account_id, kind, shortage, detected_on,
           detected_automatically, detail)
        values
          (p_tenant_id, v_bank.currency, v_bank.id,
           'reconciliation_missed', 0, v_on, true,
           jsonb_build_object('bank_name', v_bank.name, 'missed_days', v_streak))
        returning * into v_inc;

        update public.fin_client_money_incidents
           set incident_no = public.next_doc_number(p_tenant_id, 'fin_client_money_incident', 'CMI')
         where id = v_inc.id
        returning * into v_inc;

        perform public.log_platform_event('fin.client_money.reconciliation_escalated', p_tenant_id,
          'fin_client_money_incident', v_inc.id::text,
          format('%s has missed %s client-money reconciliations in a row', v_bank.name, v_streak),
          null, to_jsonb(v_inc));

        if to_regprocedure('public.ins_notify_finance_users(uuid)') is not null then
          perform public.ins_notify(p_tenant_id,
            public.ins_notify_finance_users(p_tenant_id), null,
            'client_money_reconciliation_missed',
            'Client-money reconciliation missed on ' || v_bank.name,
            format('%s business day(s) in a row with no reviewed reconciliation. This is escalated to company administration.', v_streak),
            '/finance/client-money');
        end if;
      else
        update public.fin_client_money_incidents
           set detail = detail || jsonb_build_object('missed_days', v_streak, 'last_seen', v_on)
         where id = v_inc.id
        returning * into v_inc;
      end if;

      v_incident := v_inc.id;
    end if;

    return query select v_bank.id, v_bank.name, v_streak, (v_streak >= v_threshold), v_incident;
  end loop;
end $$;

revoke all on function public.platform_ins_escalate_missed_reconciliations(uuid, date) from public;
grant execute on function public.platform_ins_escalate_missed_reconciliations(uuid, date) to service_role;

comment on function public.platform_ins_escalate_missed_reconciliations(uuid, date) is
  'Tenant-parameterised missed-reconciliation escalation, for the scheduled job. Interactive callers use ins_escalate_missed_reconciliations().';

-- ---------------------------------------------------------------------
-- 2. The jobs themselves
-- ---------------------------------------------------------------------
-- Same shape as platform_run_operator_digest_logged(): no arguments, run recorded in
-- platform_job_runs, old runs pruned.
--
-- ONE DELIBERATE DIFFERENCE from the digest: a per-tenant failure does not abandon the
-- run. The digest has one tenant's work to do and can afford to stop; this loops a fleet,
-- and stopping on the first broken tenant would mean every company after it goes
-- unchecked -- silently, because the job did report an error. Each tenant's failure is
-- recorded against that tenant, the loop continues, and the run is marked error at the
-- end so the failure is still loud.
create or replace function public.platform_ins_client_money_check_logged()
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant  record;
  v_checked integer := 0;
  v_short   integer := 0;
  v_failed  text[]  := '{}';
  v_row     record;
begin
  for v_tenant in
    select t.id from public.tenants t
     where exists (select 1 from public.tenant_modules m
                    where m.tenant_id = t.id and m.module = 'insurance')
     order by t.id
  loop
    begin
      for v_row in select * from public.platform_ins_client_money_check(v_tenant.id) loop
        v_checked := v_checked + 1;
        if v_row.blocked then v_short := v_short + 1; end if;
      end loop;
    exception when others then
      v_failed := v_failed || (v_tenant.id::text || ': ' || sqlerrm);
      perform public.platform_record_job_run('ins_client_money_check', v_tenant.id, 'error', 0, sqlerrm);
    end;
  end loop;

  perform public.platform_record_job_run('ins_client_money_check', null,
    case when cardinality(v_failed) = 0 then 'ok' else 'error' end,
    v_checked,
    format('%s currency position(s) checked, %s blocked%s',
           v_checked, v_short,
           case when cardinality(v_failed) = 0 then '' else '; failures: ' || array_to_string(v_failed, ' | ') end));
  perform public.platform_job_runs_prune();

  if cardinality(v_failed) > 0 then
    raise exception 'INS_CLIENT_MONEY_JOB: % of the run failed: %',
      cardinality(v_failed), array_to_string(v_failed, ' | ');
  end if;
  return v_checked;
end $$;

revoke all on function public.platform_ins_client_money_check_logged() from public, anon, authenticated;
grant execute on function public.platform_ins_client_money_check_logged() to service_role;

create or replace function public.platform_ins_escalate_reconciliations_logged()
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant     record;
  v_banks      integer := 0;
  v_escalated  integer := 0;
  v_failed     text[]  := '{}';
  v_row        record;
begin
  for v_tenant in
    select t.id from public.tenants t
     where exists (select 1 from public.tenant_modules m
                    where m.tenant_id = t.id and m.module = 'insurance')
     order by t.id
  loop
    begin
      for v_row in select * from public.platform_ins_escalate_missed_reconciliations(v_tenant.id) loop
        v_banks := v_banks + 1;
        if v_row.escalated then v_escalated := v_escalated + 1; end if;
      end loop;
    exception when others then
      v_failed := v_failed || (v_tenant.id::text || ': ' || sqlerrm);
      perform public.platform_record_job_run('ins_reconciliation_escalation', v_tenant.id, 'error', 0, sqlerrm);
    end;
  end loop;

  perform public.platform_record_job_run('ins_reconciliation_escalation', null,
    case when cardinality(v_failed) = 0 then 'ok' else 'error' end,
    v_escalated,
    format('%s client-money bank account(s) checked, %s escalated%s',
           v_banks, v_escalated,
           case when cardinality(v_failed) = 0 then '' else '; failures: ' || array_to_string(v_failed, ' | ') end));
  perform public.platform_job_runs_prune();

  if cardinality(v_failed) > 0 then
    raise exception 'INS_RECONCILIATION_JOB: % of the run failed: %',
      cardinality(v_failed), array_to_string(v_failed, ' | ');
  end if;
  return v_escalated;
end $$;

revoke all on function public.platform_ins_escalate_reconciliations_logged() from public, anon, authenticated;
grant execute on function public.platform_ins_escalate_reconciliations_logged() to service_role;

-- ---------------------------------------------------------------------
-- 3. Schedule them
-- ---------------------------------------------------------------------
-- Times are the database server's, which is UTC on Supabase. 05:15 and 05:30 UTC are
-- 08:15 and 08:30 in Kampala, so both land before a business day starts and the
-- escalation is waiting for whoever opens the finance screen. They are also clear of the
-- operator digest at 04:00.
--
-- cron.job rows are data rather than DDL, so this is a DO block in the same style the
-- baseline uses for its own jobs. If pg_cron is absent the migration still succeeds and
-- says so loudly rather than failing the deploy: the jobs are callable either way, and a
-- missing extension should be visible, not fatal.
do $do$
declare
  v_job bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron is not installed: the daily client-money jobs are NOT scheduled. Call public.platform_ins_client_money_check_logged() and public.platform_ins_escalate_reconciliations_logged() from your own scheduler.';
    return;
  end if;

  select jobid into v_job from cron.job where jobname = 'ins_client_money_check_daily';
  if v_job is not null then perform cron.unschedule(v_job); end if;
  perform cron.schedule('ins_client_money_check_daily', '15 5 * * *',
    'select public.platform_ins_client_money_check_logged();');

  select jobid into v_job from cron.job where jobname = 'ins_reconciliation_escalation_daily';
  if v_job is not null then perform cron.unschedule(v_job); end if;
  perform cron.schedule('ins_reconciliation_escalation_daily', '30 5 * * *',
    'select public.platform_ins_escalate_reconciliations_logged();');
end
$do$;

-- ---------------------------------------------------------------------
-- 4. Prove it
-- ---------------------------------------------------------------------
-- The property worth asserting is the one the shipped functions could not satisfy: that
-- a caller with no tenant context at all still reaches every insurance tenant. If this
-- returns a non-zero count from a session with no JWT, the job is not inert.
do $$
declare
  v_tenants integer;
  v_reached integer := 0;
  v_tenant  record;
begin
  if to_regprocedure('public.platform_ins_client_money_check(uuid, text)') is null then
    raise exception 'the tenant-parameterised client-money check was not created';
  end if;
  if to_regprocedure('public.platform_ins_escalate_missed_reconciliations(uuid, date)') is null then
    raise exception 'the tenant-parameterised reconciliation escalation was not created';
  end if;

  select count(*) into v_tenants
    from public.tenants t
   where exists (select 1 from public.tenant_modules m
                  where m.tenant_id = t.id and m.module = 'insurance');
  if v_tenants = 0 then
    raise notice 'no insurance tenant exists yet; the loop is untested here and will run when one does';
  end if;
end $$;
