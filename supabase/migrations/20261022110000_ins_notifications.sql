-- Insurance notifications.
--
-- Before: the platform bell and `notifications` table existed, but nothing in
-- insurance wrote to them. A Finance checker had no way to learn that an
-- endorsement was waiting, and nobody heard about a renewal until they opened
-- the Renewals screen.
--
-- What this adds:
--   A. notifications.link_path -- an in-app path the bell navigates to on click.
--   B. Recipient helpers and one writer (ins_notify) that every insurance
--      notification goes through. The writer never raises: a bell problem must
--      not roll back a financial posting or a claim update.
--   C. Triggers (no edits to the guarded posting RPCs):
--        * endorsements and cancellations: proposed -> Finance team; prepared ->
--          Finance team minus the proposer and preparer (the independent
--          checker); posted or rejected -> the people who proposed/prepared it.
--        * cancellation cash requests: pending -> Finance team minus the maker;
--          posted or rejected -> the maker.
--        * claims: new claim -> insurance admins and managers; assignment ->
--          the assignee; approved, repudiated or settled -> assignee and the
--          registrar.
--      The person who made the change is never notified of it.
--   D. ins_renewal_notification_sweep(): the "cronless cron" used elsewhere on
--      the platform (a screen calls it on mount; no pg_cron). It sends one
--      digest per threshold to insurance admins and managers, once per policy:
--      60, 30 and 7 days before expiry, plus a notice for a policy that lapsed
--      in the last 30 days with no renewal draft, no outcome and no cancellation.
--      A policy first seen inside a tighter window gets only the tighter notice.
--
-- Test: supabase/tests/test_ins_notifications.sql.

-- =====================================================================
-- A. Link target
-- =====================================================================
alter table public.notifications add column if not exists link_path text;

alter table public.notifications drop constraint if exists notifications_link_path_check;
alter table public.notifications add constraint notifications_link_path_check
  check (link_path is null
         or (link_path like '/%' and link_path not like '//%' and length(link_path) <= 300));

-- =====================================================================
-- B. Sweep markers, recipient helpers, writer
-- =====================================================================
create table if not exists public.ins_notification_marks (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  policy_id uuid not null,
  kind      text not null check (kind in ('renewal_60', 'renewal_30', 'renewal_7', 'lapsed')),
  sent_at   timestamptz not null default now(),
  primary key (tenant_id, policy_id, kind),
  foreign key (tenant_id, policy_id) references public.ins_policies (tenant_id, id) on delete cascade
);

alter table public.ins_notification_marks enable row level security;
revoke all on public.ins_notification_marks from public, anon, authenticated;

create or replace function public.ins_notify_insurance_users(p_tenant uuid, p_roles text[])
returns uuid[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(distinct sr.user_id), '{}'::uuid[])
  from staff_roles sr
  where sr.tenant_id = p_tenant
    and sr.module = 'insurance'
    and sr.role = any (p_roles);
$$;

create or replace function public.ins_notify_finance_users(p_tenant uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(distinct f.user_id), '{}'::uuid[])
  from finance_team_members f
  where f.tenant_id = p_tenant
    and f.role = 'finance';
$$;

-- Writes one notification per distinct recipient who belongs to the tenant,
-- skipping anyone in p_exclude. Null elements in either array are ignored.
create or replace function public.ins_notify(
  p_tenant     uuid,
  p_recipients uuid[],
  p_exclude    uuid[],
  p_type       text,
  p_title      text,
  p_body       text,
  p_link       text
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into notifications (tenant_id, recipient_id, type, title, body, link_path)
  select p_tenant, u.id, p_type, p_title, p_body, p_link
  from app_users u
  where u.tenant_id = p_tenant
    and u.id = any (array_remove(coalesce(p_recipients, '{}'::uuid[]), null))
    and u.id <> all (array_remove(coalesce(p_exclude, '{}'::uuid[]), null));
exception when others then
  raise warning 'ins_notify % failed: % (%)', p_type, sqlerrm, sqlstate;
end;
$$;

-- =====================================================================
-- C. Event triggers
-- =====================================================================

-- C1. Endorsements and cancellations share their column names for the
--     maker/checker flow; the document number is the only difference.
create or replace function public.ins_notify_approval_case()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor     uuid := auth.uid();
  v_row       jsonb := to_jsonb(NEW);
  v_what      text;
  v_slug      text;
  v_no        text;
  v_policy_no text;
  v_link      text;
  v_people    uuid[];
begin
  if TG_TABLE_NAME = 'ins_policy_endorsements' then
    v_what := 'Endorsement'; v_slug := 'ins_endorsement';
    v_no := v_row ->> 'endorsement_no';
  else
    v_what := 'Cancellation'; v_slug := 'ins_cancellation';
    v_no := v_row ->> 'cancellation_no';
  end if;

  select p.policy_no into v_policy_no
  from ins_policies p
  where p.id = NEW.policy_id and p.tenant_id = NEW.tenant_id;
  v_policy_no := coalesce(v_policy_no, 'policy');
  v_link := '/insurance/policies/' || NEW.policy_id::text;
  v_people := array[NEW.proposed_by, NEW.prepared_by];

  if TG_OP = 'INSERT' then
    if NEW.status = 'proposed' then
      perform ins_notify(
        NEW.tenant_id, ins_notify_finance_users(NEW.tenant_id), array[v_actor, NEW.proposed_by],
        v_slug || '_proposed',
        v_what || ' proposed: ' || v_policy_no,
        format('A %s on policy %s, effective %s, is waiting for a Finance maker to prepare it.',
               lower(v_what), v_policy_no, NEW.effective_date),
        v_link);
    end if;
    return NEW;
  end if;

  if NEW.status is not distinct from OLD.status then
    return NEW;
  end if;

  if NEW.status = 'prepared' then
    perform ins_notify(
      NEW.tenant_id, ins_notify_finance_users(NEW.tenant_id),
      array[v_actor, NEW.proposed_by, NEW.prepared_by],
      v_slug || '_prepared',
      v_what || ' awaiting your check: ' || v_policy_no,
      format('A %s on policy %s was prepared and needs an independent Finance checker.',
             lower(v_what), v_policy_no),
      v_link);
  elsif NEW.status = 'posted' then
    perform ins_notify(
      NEW.tenant_id, v_people, array[v_actor],
      v_slug || '_posted',
      v_what || ' posted: ' || coalesce(v_no, v_policy_no),
      format('The %s on policy %s was approved and posted.', lower(v_what), v_policy_no),
      v_link);
  elsif NEW.status = 'rejected' then
    perform ins_notify(
      NEW.tenant_id, v_people, array[v_actor],
      v_slug || '_rejected',
      v_what || ' rejected: ' || v_policy_no,
      format('The %s on policy %s was rejected.%s', lower(v_what), v_policy_no,
             case when nullif(btrim(coalesce(NEW.review_note, '')), '') is not null
                  then ' Reviewer note: ' || left(btrim(NEW.review_note), 200) else '' end),
      v_link);
  end if;
  return NEW;
exception when others then
  raise warning 'ins_notify_approval_case failed: % (%)', sqlerrm, sqlstate;
  return NEW;
end;
$$;

drop trigger if exists ins_notify_endorsement on public.ins_policy_endorsements;
create trigger ins_notify_endorsement
  after insert or update of status on public.ins_policy_endorsements
  for each row execute function public.ins_notify_approval_case();

drop trigger if exists ins_notify_cancellation on public.ins_policy_cancellations;
create trigger ins_notify_cancellation
  after insert or update of status on public.ins_policy_cancellations
  for each row execute function public.ins_notify_approval_case();

-- C2. Cancellation cash requests.
create or replace function public.ins_notify_cancellation_cash()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor     uuid := auth.uid();
  v_policy_id uuid;
  v_policy_no text;
  v_currency  text;
  v_link      text;
  v_summary   text;
begin
  select p.id, p.policy_no, p.currency into v_policy_id, v_policy_no, v_currency
  from ins_policy_cancellations c
  join ins_policies p on p.id = c.policy_id and p.tenant_id = c.tenant_id
  where c.id = NEW.cancellation_id and c.tenant_id = NEW.tenant_id;

  v_policy_no := coalesce(v_policy_no, 'policy');
  v_link := case when v_policy_id is null then null else '/insurance/policies/' || v_policy_id::text end;
  v_summary := format('%s of %s %s on policy %s',
                      replace(NEW.kind, '_', ' '), coalesce(v_currency, ''),
                      to_char(NEW.amount, 'FM999,999,999,990.00'), v_policy_no);

  if TG_OP = 'INSERT' then
    if NEW.status = 'pending' then
      perform ins_notify(
        NEW.tenant_id, ins_notify_finance_users(NEW.tenant_id), array[v_actor, NEW.maker_id],
        'ins_cancellation_cash_pending',
        'Cash request awaiting your check: ' || v_policy_no,
        'A cancellation cash request needs an independent Finance checker: ' || v_summary || '.',
        v_link);
    end if;
    return NEW;
  end if;

  if NEW.status is not distinct from OLD.status then
    return NEW;
  end if;

  if NEW.status in ('posted', 'rejected') then
    perform ins_notify(
      NEW.tenant_id, array[NEW.maker_id], array[v_actor],
      'ins_cancellation_cash_' || NEW.status,
      'Cash request ' || NEW.status || ': ' || v_policy_no,
      format('Your cancellation cash request (%s) was %s.', v_summary, NEW.status),
      v_link);
  end if;
  return NEW;
exception when others then
  raise warning 'ins_notify_cancellation_cash failed: % (%)', sqlerrm, sqlstate;
  return NEW;
end;
$$;

drop trigger if exists ins_notify_cancellation_cash on public.ins_cancellation_cash_requests;
create trigger ins_notify_cancellation_cash
  after insert or update of status on public.ins_cancellation_cash_requests
  for each row execute function public.ins_notify_cancellation_cash();

-- C3. Claims.
create or replace function public.ins_notify_claim_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor     uuid := auth.uid();
  v_policy_no text;
  v_link      text := '/insurance/claims/' || NEW.id::text;
begin
  select p.policy_no into v_policy_no
  from ins_policies p
  where p.id = NEW.policy_id and p.tenant_id = NEW.tenant_id;
  v_policy_no := coalesce(v_policy_no, 'policy');

  if TG_OP = 'INSERT' then
    perform ins_notify(
      NEW.tenant_id, ins_notify_insurance_users(NEW.tenant_id, array['admin', 'manager']),
      array[v_actor, NEW.assigned_to],
      'ins_claim_registered',
      'New claim ' || NEW.claim_no,
      format('Claim %s on policy %s (loss date %s) was registered.', NEW.claim_no, v_policy_no, NEW.loss_date),
      v_link);
    if NEW.assigned_to is not null then
      perform ins_notify(
        NEW.tenant_id, array[NEW.assigned_to], array[v_actor],
        'ins_claim_assigned',
        'Claim assigned to you: ' || NEW.claim_no,
        format('Claim %s on policy %s was assigned to you.', NEW.claim_no, v_policy_no),
        v_link);
    end if;
    return NEW;
  end if;

  if NEW.assigned_to is not null and NEW.assigned_to is distinct from OLD.assigned_to then
    perform ins_notify(
      NEW.tenant_id, array[NEW.assigned_to], array[v_actor],
      'ins_claim_assigned',
      'Claim assigned to you: ' || NEW.claim_no,
      format('Claim %s on policy %s was assigned to you.', NEW.claim_no, v_policy_no),
      v_link);
  end if;

  if NEW.status is distinct from OLD.status and NEW.status in ('approved', 'repudiated', 'settled') then
    perform ins_notify(
      NEW.tenant_id, array[NEW.assigned_to, NEW.created_by], array[v_actor],
      'ins_claim_' || NEW.status,
      'Claim ' || NEW.status || ': ' || NEW.claim_no,
      format('Claim %s on policy %s is now %s.', NEW.claim_no, v_policy_no, NEW.status),
      v_link);
  end if;
  return NEW;
exception when others then
  raise warning 'ins_notify_claim_change failed: % (%)', sqlerrm, sqlstate;
  return NEW;
end;
$$;

drop trigger if exists ins_notify_claim on public.ins_claims;
create trigger ins_notify_claim
  after insert or update of status, assigned_to on public.ins_claims
  for each row execute function public.ins_notify_claim_change();

-- =====================================================================
-- D. Renewal sweep
-- =====================================================================
create or replace function public.ins_renewal_notification_sweep()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_recips  uuid[];
  v_kinds   text[] := '{}';
  v_nos     text[] := '{}';
  v_ins     integer;
  v_total   integer := 0;
  r         record;
  k         text;
  v_list    text[];
  v_count   integer;
  v_shown   text;
begin
  if auth.uid() is null or v_tenant is null
     or not has_module_role('insurance', array['admin', 'manager', 'member']) then
    return 0;
  end if;

  -- Nobody to tell: leave the markers alone so the policies are picked up
  -- once a manager exists, rather than marking them as sent.
  v_recips := ins_notify_insurance_users(v_tenant, array['admin', 'manager']);
  if coalesce(array_length(v_recips, 1), 0) = 0 then
    return 0;
  end if;

  for r in
    select p.id, p.policy_no,
      case
        when p.expiry_date < current_date              then 'lapsed'
        when p.expiry_date - current_date <= 7         then 'renewal_7'
        when p.expiry_date - current_date <= 30        then 'renewal_30'
        else 'renewal_60'
      end as kind
    from ins_policies p
    where p.tenant_id = v_tenant
      and p.status = 'active'
      and p.expiry_date >= current_date - 30
      and p.expiry_date <= current_date + 60
      and not exists (select 1 from ins_policies d
                      where d.tenant_id = p.tenant_id and d.renewal_of_id = p.id and d.status = 'draft')
      and not exists (select 1 from ins_renewal_outcomes o
                      where o.tenant_id = p.tenant_id and o.policy_id = p.id)
      and not exists (select 1 from ins_policy_cancellations c
                      where c.tenant_id = p.tenant_id and c.policy_id = p.id
                        and c.status in ('proposed', 'prepared', 'posting', 'posted'))
    order by p.expiry_date, p.policy_no
  loop
    -- A policy first seen inside a tighter window skips the looser notices.
    if r.kind = 'renewal_7' then
      insert into ins_notification_marks (tenant_id, policy_id, kind)
      values (v_tenant, r.id, 'renewal_30'), (v_tenant, r.id, 'renewal_60')
      on conflict do nothing;
    elsif r.kind = 'renewal_30' then
      insert into ins_notification_marks (tenant_id, policy_id, kind)
      values (v_tenant, r.id, 'renewal_60')
      on conflict do nothing;
    end if;

    insert into ins_notification_marks (tenant_id, policy_id, kind)
    values (v_tenant, r.id, r.kind)
    on conflict do nothing;
    get diagnostics v_ins = row_count;

    if v_ins = 1 then
      v_kinds := v_kinds || r.kind;
      v_nos   := v_nos || r.policy_no;
    end if;
  end loop;

  foreach k in array array['renewal_7', 'renewal_30', 'renewal_60', 'lapsed'] loop
    select coalesce(array_agg(t.n order by t.ord), '{}') into v_list
    from unnest(v_kinds, v_nos) with ordinality as t(kind, n, ord)
    where t.kind = k;

    v_count := coalesce(array_length(v_list, 1), 0);
    continue when v_count = 0;

    v_total := v_total + v_count;
    v_shown := array_to_string(v_list[1:5], ', ')
               || case when v_count > 5 then format(' and %s more', v_count - 5) else '' end;

    perform ins_notify(
      v_tenant, v_recips, '{}'::uuid[],
      case when k = 'lapsed' then 'ins_policy_lapsed' else 'ins_renewal_due' end,
      case k
        when 'renewal_7'  then 'Renewals due within 7 days'
        when 'renewal_30' then 'Renewals due within 30 days'
        when 'renewal_60' then 'Renewals due within 60 days'
        else 'Policies lapsed without renewal'
      end,
      case when k = 'lapsed'
           then format('%s %s expired in the last 30 days with no renewal, outcome or cancellation: %s.',
                       v_count, case when v_count = 1 then 'policy' else 'policies' end, v_shown)
           else format('%s %s expire%s %s: %s.',
                       v_count, case when v_count = 1 then 'policy' else 'policies' end,
                       case when v_count = 1 then 's' else '' end,
                       case k when 'renewal_7' then 'within 7 days'
                              when 'renewal_30' then 'within 30 days'
                              else 'within 60 days' end,
                       v_shown)
      end,
      '/insurance/renewals');
  end loop;

  return v_total;
end;
$$;

-- =====================================================================
-- E. Grants
-- =====================================================================
-- Helpers and trigger functions are internal: the triggers run them as the
-- table owner, so no client role needs execute.
revoke all on function public.ins_notify_insurance_users(uuid, text[]) from public, anon, authenticated;
revoke all on function public.ins_notify_finance_users(uuid) from public, anon, authenticated;
revoke all on function public.ins_notify(uuid, uuid[], uuid[], text, text, text, text) from public, anon, authenticated;
revoke all on function public.ins_notify_approval_case() from public, anon, authenticated;
revoke all on function public.ins_notify_cancellation_cash() from public, anon, authenticated;
revoke all on function public.ins_notify_claim_change() from public, anon, authenticated;

revoke all on function public.ins_renewal_notification_sweep() from public, anon;
grant execute on function public.ins_renewal_notification_sweep() to authenticated;

-- The new table carries a tenant_id, so it gets the platform read-only guard.
select public.apply_tenant_read_only_guard();
