-- =====================================================================
-- In-force import: the post-commit opening-position report.
--
-- 20261110170000 / 20261111090000 make five measures (plus client_money)
-- binding BEFORE commit, because those are facts about the staged book.
-- The control sheet also records receivables, payables and
-- unearned_commission. They are stored by the sync and compared by nothing,
-- and they cannot gate the commit: they only exist once the opening
-- position has been posted (spec 4.6, step 5), and the legacy unearned
-- commission in particular can legitimately differ from ours (Option A
-- recognises commission when the insurer net is settled, not over time).
--
-- So they get a report instead of a gate. For each currency it sets three
-- things side by side:
--
--   posted_amount     what the opening journal put on the control account
--   open_item_amount  what the sub-ledger (fin_open_items) holds for the
--                     same journal. NULL for unearned_commission, which has
--                     no open-item sub-ledger.
--   control_amount    what the legacy ledger said at cut-over (NULL when the
--                     sheet did not record that measure)
--
--   match             posted = control   (NULL when not recorded)
--   subledger_match   posted = open items (NULL when there is no sub-ledger)
--
-- Read-only; it changes nothing and blocks nothing. A difference is for a
-- reviewer to explain, the same way "not recorded" is not "differs".
--
-- The currency list is the union of every currency the journal, the open
-- items, the batch's policies and the control sheet know about, so a
-- currency that appears only in the legacy sheet shows up as a difference
-- instead of silently disappearing (the same lesson as 20261111090000).
--
-- Signs: receivables = debit less credit on ar_control; payables and
-- unearned_commission = credit less debit on their accounts.
-- =====================================================================

create or replace function public.ins_import_opening_report(p_batch_id uuid)
returns table (currency text, measure text, posted_amount numeric,
               open_item_amount numeric, control_amount numeric,
               match boolean, subledger_match boolean)
language plpgsql stable security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  v_totals   jsonb;
  v_je       uuid;
  v_ar       uuid;
  v_pay      uuid;
  v_unearned uuid;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select coalesce(b.control_totals, '[]'::jsonb) into v_totals
    from public.ins_import_batches b
   where b.id = p_batch_id and b.tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;

  select j.id into v_je
    from public.journal_entries j
   where j.tenant_id = v_tenant and j.source_type = 'ins_import_opening'
     and j.source_id = p_batch_id;
  if v_je is null then
    raise exception 'INS_IMPORT_OPENING_NOT_POSTED: post the opening position before reading this report';
  end if;

  v_ar       := public.get_posting_account(v_tenant, 'ar_control');
  v_pay      := public.get_posting_account(v_tenant, 'insurer_payable');
  v_unearned := public.get_posting_account(v_tenant, 'unearned_commission');

  return query
  with lines as (
    select l.currency as cur, l.gl_account_id, l.debit, l.credit
      from public.journal_entry_lines l
     where l.journal_entry_id = v_je and l.tenant_id = v_tenant
  ),
  posted as (
    select x.cur,
           coalesce(sum(x.debit - x.credit)  filter (where x.gl_account_id = v_ar), 0)       as receivables,
           coalesce(sum(x.credit - x.debit)  filter (where x.gl_account_id = v_pay), 0)      as payables,
           coalesce(sum(x.credit - x.debit)  filter (where x.gl_account_id = v_unearned), 0) as unearned
      from lines x
     group by x.cur
  ),
  items as (
    select i.currency as cur,
           coalesce(sum(i.amount) filter (where i.control_role = 'ar_control'), 0)       as receivables,
           coalesce(sum(i.amount) filter (where i.control_role = 'insurer_payable'), 0)  as payables
      from public.fin_open_items i
     where i.tenant_id = v_tenant and i.journal_entry_id = v_je
     group by i.currency
  ),
  ctl as (
    select distinct on (upper(btrim(e.obj ->> 'currency')))
           upper(btrim(e.obj ->> 'currency')) as cur,
           e.obj as totals
      from jsonb_array_elements(v_totals) as e(obj)
     where nullif(btrim(e.obj ->> 'currency'), '') is not null
     order by upper(btrim(e.obj ->> 'currency'))
  ),
  cur as (
    select p.cur from posted p
    union select i.cur from items i
    union select c.cur from ctl c
    union select pol.currency from public.ins_policies pol
           where pol.tenant_id = v_tenant and pol.import_batch_id = p_batch_id
  )
  select u.cur,
         m.measure,
         round(m.posted, 2),
         round(m.sub, 2),
         m.ctl,
         case when m.ctl is null then null else round(m.posted, 2) = m.ctl end,
         case when m.sub is null then null else round(m.posted, 2) = round(m.sub, 2) end
    from cur u
    left join posted p on p.cur = u.cur
    left join items  i on i.cur = u.cur
    left join ctl    c on c.cur = u.cur
    cross join lateral (values
      ('receivables',          coalesce(p.receivables, 0), coalesce(i.receivables, 0),
         (c.totals ->> 'receivables')::numeric),
      ('payables',             coalesce(p.payables, 0),    coalesce(i.payables, 0),
         (c.totals ->> 'payables')::numeric),
      ('unearned_commission',  coalesce(p.unearned, 0),    null::numeric,
         (c.totals ->> 'unearned_commission')::numeric)
    ) m(measure, posted, sub, ctl)
   order by u.cur, m.measure;
end $$;

revoke all on function public.ins_import_opening_report(uuid) from public, anon;
grant execute on function public.ins_import_opening_report(uuid) to authenticated;
