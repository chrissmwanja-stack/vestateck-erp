
-- =====================================================================
-- Insurance: manual agent commission accrual
-- =====================================================================
--
-- What this closes
--
--   ins_agent_commission_accrue() is owner-only. It is called by the
--   recognition trigger and by nothing else, so the only way a share ever
--   reached the books was for the brokerage's commission to be recognised
--   first. That is the right default -- an agent is paid out of money the
--   brokerage has earned -- but it leaves a gap that shows up in three
--   situations:
--
--     * commission recognised BEFORE the subledger existed (the deploy case,
--       handled today by a backfill function with no UI and no client grant)
--     * a share reversed for the wrong reason, now correctable only by a
--       backfill nobody can reach from the product
--     * a book migrated with earned commission already on it
--
--   This migration gives a manager two supported actions:
--
--     Accrue Commission   one policy, chosen by the manager
--     Run Accruals        every eligible policy in a period, one report
--
--   NEITHER OF THEM CALCULATES OR POSTS ANYTHING ITSELF. Both resolve
--   eligibility, then call ins_agent_commission_accrue(), the same function
--   the recognition trigger calls. That is deliberate and it is the whole
--   point of the bit: a manual action must not have a second, subtly
--   different set of accrual rules. If the rules change, they change in one
--   place and both callers move together.
--
-- What is NOT here, and why
--
--   No amount parameter. There is no path by which a caller can name a
--   figure. The share comes from the approved term in force at the policy's
--   inception date, through ins_agent_commission_calculate(). An action that
--   accepted an amount would be a way to post a liability the agreement does
--   not support, and the ledger would have no way to tell the two apart.
--
--   No override of the recognition point. A share is accrued only when the
--   brokerage's own commission has been earned -- the entry's status is
--   'earned' or 'transferred'. A policy that has not reached that point is
--   refused with the reason, named, and the reason says which of the two
--   facts is missing. "Run it anyway" is the one flag this action must never
--   grow.
--
-- ---------------------------------------------------------------------
-- 1. Why a policy cannot be accrued, in words a manager can act on
-- ---------------------------------------------------------------------
-- A single function answers the question, so the button, the bulk run and any
-- future report all say the same thing. It returns a short code plus the
-- sentence, and returns NULL code when the policy COULD be accrued.
--
-- This is a diagnostic, not a guard. The accrue function still re-checks
-- everything: this could be read a second before a concurrent reversal or a
-- term end-date lands, so the check here is for explanation only and the
-- refusal that matters happens inside the accrual.
create or replace function public.ins_agent_commission_blocked_reason(
  p_policy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  p          public.ins_policies;
  a          public.ins_intermediaries;
  v_live     public.ins_agent_commission_accruals;
  v_earned   integer;
  v_calc     jsonb;
begin
  select * into p from public.ins_policies
   where id = p_policy_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_POLICY_NOT_FOUND';
  end if;

  -- Order matters: these are read top to bottom by whoever is fixing the
  -- policy, so the first thing that must change comes first.

  if p.agent_id is null then
    return jsonb_build_object('code', 'INS_AGENT_NO_AGENT',
      'reason', 'the policy names no intermediary, so there is nobody to accrue a share for');
  end if;

  select * into a from public.ins_intermediaries
   where id = p.agent_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_INTERMEDIARY_NOT_FOUND';
  end if;

  if a.category = 'insurer_appointed_agent' then
    return jsonb_build_object('code', 'INS_AGENT_INSURER_PAID',
      'reason', format('%s is an insurer-appointed agent, so the insurer remunerates them; the brokerage pays nothing and accrues nothing', a.name));
  end if;

  if not public.ins_intermediary_is_broker_paid(p.agent_id) then
    return jsonb_build_object('code', 'INS_AGENT_UNKNOWN_CATEGORY',
      'reason', format('%s has category %s, which has no commission treatment; only sub_agent and referral_partner are paid by the brokerage', a.name, a.category));
  end if;

  -- An active share is already on the books. That is not a failure to explain,
  -- it is the answer: accruing again would be a second liability for one
  -- obligation.
  select * into v_live from public.ins_agent_commission_accruals
   where tenant_id = v_tenant and policy_id = p_policy_id
     and intermediary_id = p.agent_id
     and status <> 'reversed';
  if found then
    return jsonb_build_object('code', 'INS_AGENT_ALREADY_ACCRUED',
      'reason', format('a share for %s is already on the books (%s, %s)', a.name, v_live.status, v_live.gross_amount),
      'accrual_id', v_live.id, 'status', v_live.status);
  end if;

  -- Has the brokerage earned its commission? This is the recognition point the
  -- manual action is not allowed to jump. `deferred` means the insurer has not
  -- paid us yet under on_insurer_settlement; no entry at all means the policy
  -- has not been bound, or carries no commission.
  select count(*) into v_earned
    from public.ins_commission_entries e
   where e.policy_id = p_policy_id
     and e.status in ('earned', 'transferred');
  if v_earned = 0 then
    return jsonb_build_object('code', 'INS_AGENT_NOT_RECOGNISED',
      'reason', format('the brokerage''s own commission on %s has not been recognised yet, so there is no earned commission for the agent''s share to come out of; accrual follows recognition (mode %s)', p.policy_no, public.ins_commission_recognition_mode(p_policy_id)));
  end if;

  -- Ask the calculator, which is the authority on the term and the share. It
  -- raises for a missing term and returns payable_by_brokerage=false for a
  -- basis of none; both are answers, and neither is a crash.
  begin
    v_calc := public.ins_agent_commission_calculate(p_policy_id, p.agent_id);
  exception when others then
    return jsonb_build_object('code', 'INS_AGENT_NOT_ACCRUABLE', 'reason', sqlerrm);
  end;

  if not coalesce((v_calc ->> 'payable_by_brokerage')::boolean, false) then
    return jsonb_build_object('code', 'INS_AGENT_NOT_PAYABLE',
      'reason', coalesce(v_calc ->> 'reason', 'the approved term records that the brokerage does not pay this intermediary'));
  end if;

  -- Reaching here means every condition holds. The amount is returned so the
  -- UI can show what WOULD be accrued before anybody commits to it, but the
  -- figure comes from the same calculation the accrual will run, never from
  -- the caller.
  return jsonb_build_object(
    'code', null,
    'reason', null,
    'intermediary_id', a.id,
    'name', a.name,
    'basis', v_calc ->> 'basis',
    'gross_amount', (v_calc ->> 'gross_amount')::numeric,
    'currency', p.currency,
    'recognition_mode', public.ins_commission_recognition_mode(p_policy_id));
end
$function$;

revoke all on function public.ins_agent_commission_blocked_reason(uuid) from public, anon;
grant execute on function public.ins_agent_commission_blocked_reason(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. What is eligible, for the bulk run
-- ---------------------------------------------------------------------
-- Scoped by the policy's inception date, presented per currency because the
-- totals are never added across currencies. `eligible` is what a Run Accruals
-- would post; `blocked` is everything else in the period, WITH its reason, so
-- the manager is never asked to run something blind and never has to wonder
-- why the count in the dialog does not match the count on the register.
create or replace function public.ins_agent_commission_accrual_preview(
  p_from date,
  p_to   date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  r        record;
  v_block  jsonb;
  v_elig   jsonb := '[]'::jsonb;
  v_blocked jsonb := '[]'::jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INS_AGENT_BAD_PERIOD: from % and to % do not describe a period', p_from, p_to;
  end if;

  for r in
    select p.id, p.policy_no, p.inception_date, p.currency, p.agent_id
      from public.ins_policies p
     where p.tenant_id = v_tenant
       and p.inception_date between p_from and p_to
       and p.agent_id is not null
       and p.status not in ('draft', 'cancelled')
     order by p.inception_date, p.policy_no
  loop
    v_block := public.ins_agent_commission_blocked_reason(r.id);

    if v_block ->> 'code' is null then
      v_elig := v_elig || jsonb_build_array(jsonb_build_object(
        'policy_id', r.id, 'policy_no', r.policy_no,
        'inception_date', r.inception_date, 'currency', r.currency,
        'intermediary_id', v_block ->> 'intermediary_id',
        'name', v_block ->> 'name', 'basis', v_block ->> 'basis',
        'gross_amount', (v_block ->> 'gross_amount')::numeric));
    else
      v_blocked := v_blocked || jsonb_build_array(jsonb_build_object(
        'policy_id', r.id, 'policy_no', r.policy_no,
        'inception_date', r.inception_date, 'currency', r.currency,
        'code', v_block ->> 'code', 'reason', v_block ->> 'reason'));
    end if;
  end loop;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'eligible', v_elig,
    'eligible_count', jsonb_array_length(v_elig),
    'blocked', v_blocked,
    'blocked_count', jsonb_array_length(v_blocked),
    'by_currency',
      coalesce((select jsonb_agg(x order by x ->> 'currency')
                  from (select jsonb_build_object(
                                 'currency', (e ->> 'currency'),
                                 'count', count(*),
                                 'gross_amount', sum((e ->> 'gross_amount')::numeric)) as x
                          from jsonb_array_elements(v_elig) as e
                         group by (e ->> 'currency')) s), '[]'::jsonb));
end
$function$;

revoke all on function public.ins_agent_commission_accrual_preview(date, date) from public, anon;
grant execute on function public.ins_agent_commission_accrual_preview(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Accrue one policy, on a manager's say-so
-- ---------------------------------------------------------------------
-- A thin wrapper, and it must stay thin. It checks the caller is a manager,
-- then delegates to ins_agent_commission_accrue(). It does not compute the
-- share, decide the term, or touch the ledger.
--
-- p_reason is stored on the event rather than on the accrual: the accrual row
-- records what the agreement produced, the event records that a person asked
-- for it and why. Both are needed to answer "why is this share here?".
create or replace function public.ins_agent_commission_accrue_manual(
  p_policy_id uuid,
  p_reason    text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_block  jsonb;
  v_out    jsonb;
  v_acc    public.ins_agent_commission_accruals;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  -- Explain before attempting, so an ordinary "not yet" arrives as a sentence
  -- with a code rather than an exception with a stack position. The accrual
  -- below refuses the same cases again on its own terms.
  v_block := public.ins_agent_commission_blocked_reason(p_policy_id);
  if v_block ->> 'code' is not null then
    return jsonb_build_object('accrued', false,
                              'code', v_block ->> 'code',
                              'reason', v_block ->> 'reason');
  end if;

  v_out := public.ins_agent_commission_accrue(p_policy_id);

  -- The event the trigger would have written says "share of the brokerage's
  -- commission". When a person asked for it, the note has to say so -- an
  -- accrual that appeared because somebody pressed a button is a different
  -- fact from one that appeared because a settlement posted, and an auditor
  -- will ask which.
  if coalesce((v_out ->> 'accrued')::boolean, false) then
    select * into v_acc from public.ins_agent_commission_accruals
     where id = (v_out ->> 'accrual_id')::uuid;

    update public.ins_agent_commission_events
       set note = 'accrued manually by a manager'
                  || coalesce(': ' || nullif(btrim(p_reason), ''), '')
                  || ' (basis ' || v_acc.basis || ')'
     where accrual_id = v_acc.id
       and event = 'accrued';
  end if;

  return v_out;
end
$function$;

revoke all on function public.ins_agent_commission_accrue_manual(uuid, text) from public, anon;
grant execute on function public.ins_agent_commission_accrue_manual(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Run the period
-- ---------------------------------------------------------------------
-- One policy's obstacle must not stop the run: a missing term on the first
-- policy alphabetically would otherwise make the whole book look broken. Every
-- failure is collected and returned, and the run is safe to repeat because the
-- accrual underneath is idempotent -- a second run accrues nothing that the
-- first one did.
create or replace function public.ins_run_agent_commission_accruals(
  p_from   date,
  p_to     date,
  p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  v_preview jsonb;
  r         record;
  v_out     jsonb;
  v_ok      integer := 0;
  v_skip    integer := 0;
  v_fail    integer := 0;
  v_failed  jsonb := '[]'::jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  v_preview := public.ins_agent_commission_accrual_preview(p_from, p_to);

  for r in
    select (e ->> 'policy_id')::uuid as policy_id, e ->> 'policy_no' as policy_no
      from jsonb_array_elements(v_preview -> 'eligible') as e
     order by (e ->> 'inception_date'), (e ->> 'policy_no')
  loop
    begin
      v_out := public.ins_agent_commission_accrue_manual(r.policy_id, p_reason);

      if coalesce((v_out ->> 'accrued')::boolean, false) then
        v_ok := v_ok + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'policy_no', r.policy_no, 'accrued', true,
          'accrual_id', v_out ->> 'accrual_id',
          'gross_amount', (v_out ->> 'gross_amount')::numeric));
      else
        v_skip := v_skip + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'policy_no', r.policy_no, 'accrued', false,
          'reason', v_out ->> 'reason'));
      end if;

    exception when others then
      -- Counted AND listed. A run that reported "3 failed" and showed two
      -- messages would leave the manager hunting for the third, and the
      -- arithmetic on the summary is something they will check.
      v_fail := v_fail + 1;
      v_failed := v_failed || jsonb_build_array(jsonb_build_object(
        'policy_no', r.policy_no, 'error', sqlerrm));
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'policy_no', r.policy_no, 'accrued', false, 'error', sqlerrm));
    end;
  end loop;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'accrued', v_ok, 'skipped', v_skip, 'failed', v_fail,
    'failures', v_failed,
    'results', v_results,
    'blocked_before_run', v_preview -> 'blocked_count',
    'by_currency', v_preview -> 'by_currency');
end
$function$;

revoke all on function public.ins_run_agent_commission_accruals(date, date, text) from public, anon;
grant execute on function public.ins_run_agent_commission_accruals(date, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. The old backfill is now the same thing, reachable
-- ---------------------------------------------------------------------
-- ins_agent_commission_backfill() covered "the whole book, no date range" and
-- was owner-only, which meant the deploy case it was written for could not be
-- run from the product. It is left in place rather than dropped -- it is called
-- by nothing and dropping it would be a change with no upside -- but its work
-- is now available as a period run. Granting it to clients would be granting a
-- mass posting under a different name, so it stays owner-only deliberately.
comment on function public.ins_agent_commission_backfill() is
  'Owner-only whole-book backfill, superseded for client use by ins_run_agent_commission_accruals(from, to). Kept because it is referenced in the deploy notes; not granted to authenticated on purpose.';
