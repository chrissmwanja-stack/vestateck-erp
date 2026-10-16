-- Phase A, A3 slice 2 (see docs/insurance-brokerage/ROADMAP.md): transaction
-- currency, rate and base amount on journal lines.
--
-- Additive. No company's figures change:
--   * fx_rate is stored on every line and is set by a trigger, never by the caller.
--     A functional-currency line gets rate 1. A foreign line takes its rate from the
--     approved rate table (platform_fx_rate), so the rate cannot be chosen by the
--     caller. A missing rate raises FX_RATE_MISSING.
--   * base_debit and base_credit are generated from the stored rate. When the rate is
--     1 they are exactly debit and credit (no rounding), so every existing line is
--     unchanged.
--   * A journal must balance in transaction currency (as before) and in base
--     currency (new: JOURNAL_BASE_UNBALANCED). With no foreign lines this is the
--     same check.
--
-- Not in this slice: open items, settlements and bank accounts (slice 3), the
-- rounding account, realised and unrealised FX, and the currency guards. Those
-- guards are still in place.

alter table public.journal_entry_lines
  add column fx_rate numeric(20,8) not null default 1 check (fx_rate > 0),
  add column base_debit numeric generated always as
    (case when fx_rate = 1 then debit else round(debit * fx_rate, 2) end) stored,
  add column base_credit numeric generated always as
    (case when fx_rate = 1 then credit else round(credit * fx_rate, 2) end) stored;

create or replace function public.journal_lines_fx_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date       date;
  v_functional text;
  v_currency   text;
begin
  select entry_date into v_date
    from journal_entries
   where id = new.journal_entry_id and tenant_id = new.tenant_id;
  if v_date is null then
    raise exception 'JOURNAL_LINE: entry % does not belong to this company', new.journal_entry_id;
  end if;

  v_functional := fin_ledger_currency(new.tenant_id);
  v_currency   := coalesce(nullif(btrim(new.currency), ''), v_functional);
  new.currency := v_currency;

  if v_currency = v_functional then
    new.fx_rate := 1;
  else
    new.fx_rate := (platform_fx_rate(new.tenant_id, v_currency, v_date)).rate;
  end if;
  return new;
end;
$$;

revoke all on function public.journal_lines_fx_guard() from public, anon, authenticated;

create trigger journal_entry_lines_fx_guard
  before insert on public.journal_entry_lines
  for each row execute function public.journal_lines_fx_guard();

-- Same logic as before, plus the base-currency check. The transaction-currency
-- message is unchanged so existing expectations still match.
create or replace function public.check_journal_entry_balanced()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_id uuid;
  v_diff     numeric;
  v_base     numeric;
begin
  v_entry_id := coalesce(new.journal_entry_id, old.journal_entry_id);

  select coalesce(sum(debit), 0) - coalesce(sum(credit), 0),
         coalesce(sum(base_debit), 0) - coalesce(sum(base_credit), 0)
    into v_diff, v_base
    from journal_entry_lines
   where journal_entry_id = v_entry_id;

  if v_diff != 0 then
    raise exception 'journal entry % is not balanced (debit-credit = %)', v_entry_id, v_diff;
  end if;
  if v_base != 0 then
    raise exception 'JOURNAL_BASE_UNBALANCED: journal entry % does not balance in base currency (difference %)', v_entry_id, v_base;
  end if;
  return null;
end;
$$;
