-- =====================================================================
-- Currency in the approval routing key
-- Accountant pack v2, B14; condition C4 of AE5
-- =====================================================================
-- The routing key used to be amount and role. A company working in shillings and dollars
-- could therefore express only one limit, and whichever currency it was chosen for the other
-- one would be wrong by orders of magnitude. These tests pin the behaviour that fixes it.
--
--   §1 an any-currency stage still matches every currency (nothing changes for a company
--      that never sets a currency)
--   §2 a currency-specific tier captures only its own currency
--   §3 a currency-specific tier does NOT capture another currency at the same amount
--   §4 a caller supplying no currency matches only any-currency stages (fail closed)
--   §5 an untrimmed or lowercase stored code still matches
--   §6 the refund helper resolves at both arities, and the two-argument form is unchanged
--   §7 a manual-journal chain routes on the journal's own currency
--
-- §4 is the one that matters most. Everything else is a feature; §4 is the difference between
-- "we cannot express a dollar limit" and "we silently applied a dollar limit to shillings".
--
-- One transaction, rolled back. Disposable database only.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

do $$
declare
  ta     uuid := gen_random_uuid();
  other  uuid := gen_random_uuid();
begin
  insert into tenants(id, name) values (ta, 'Currency routing test'), (other, 'Unconfigured company');

  insert into workflow_stages (tenant_id, name, sequence_order, approver_role,
                               threshold_amount, currency, applies_to, is_active)
  values
    -- Level 1 exists in every currency.
    (ta, 'base', 1, 'finance', 0, null, 'manual_journals', true),
    -- Level 2 is for large shilling entries only.
    (ta, 'UGX tier', 2, 'admin', 50000000, 'UGX', 'manual_journals', true),
    -- Level 3 is for large dollar entries only, stored untrimmed and lowercase on purpose.
    (ta, 'USD tier', 3, 'manager', 20000, ' usd ', 'manual_journals', true),
    -- And one refund tier, to prove the refund helper reaches it.
    (ta, 'refund UGX', 2, 'admin', 1000000, 'UGX', 'insurance_refunds', true),
    (ta, 'refund base', 1, 'finance', 0, null, 'insurance_refunds', true);

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('other', other);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;

-- =====================================================================
-- §1 an any-currency stage matches any currency
-- =====================================================================
do $$
declare t uuid := pg_temp.id('tenant'); r record;
begin
  -- 100,000 reaches no currency tier; level 1 exists in every currency so it must be found.
  select * into r from public.platform_approval_required_level(t, 100000, 'manual_journals', 'UGX');
  perform pg_temp.assert(r.level = 1,
    '§1 UGX 100,000 is above no tier, so it routes to the any-currency level 1');

  -- 100,000 USD is above the 20,000 USD tier, so it must reach level 3. The any-currency stage
  -- is not "the only thing that can match" — it is the floor. This also shows the USD tier is
  -- not being excluded merely because a currency was supplied.
  select * into r from public.platform_approval_required_level(t, 100000, 'manual_journals', 'USD');
  perform pg_temp.assert(r.level = 3,
    '§1 USD 100,000 is above the USD tier and must reach level 3');
  raise notice 'PASS: §1 an any-currency stage matches in every currency';
end $$;

-- =====================================================================
-- §2 a currency tier captures its own currency
-- =====================================================================
do $$
declare t uuid := pg_temp.id('tenant'); r record;
begin
  select * into r from public.platform_approval_required_level(t, 120000000, 'manual_journals', 'UGX');
  perform pg_temp.assert(r.level = 2, '§2 a 120,000,000 UGX journal should reach the UGX tier at level 2');

  select * into r from public.platform_approval_required_level(t, 30000, 'manual_journals', 'USD');
  perform pg_temp.assert(r.level = 3, '§2 a 30,000 USD journal should reach the USD tier at level 3');
  raise notice 'PASS: §2 each currency tier captures its own currency';
end $$;

-- =====================================================================
-- §3 a currency tier does not capture another currency
-- =====================================================================
do $$
declare t uuid := pg_temp.id('tenant'); r record;
begin
  -- 120,000,000 is a large shilling figure and an absurd dollar figure. It must reach the UGX
  -- tier for UGX and must NOT reach the USD tier for USD... it exceeds the USD tier too, but
  -- the point here is the reverse direction: the USD tier's threshold is 20,000, so a
  -- 30,000 UGX journal must not be captured by it.
  select * into r from public.platform_approval_required_level(t, 30000, 'manual_journals', 'UGX');
  perform pg_temp.assert(r.level = 1,
    '§3 30,000 UGX must not be captured by the 20,000 USD tier, which is a different currency');

  -- And the UGX tier must not capture a dollar journal of a similar magnitude.
  select * into r from public.platform_approval_required_level(t, 120000000, 'manual_journals', 'USD');
  perform pg_temp.assert(r.level = 3,
    '§3 a large USD journal reaches the USD tier, not the UGX tier');
  raise notice 'PASS: §3 a tier in one currency is invisible to another currency';
end $$;

-- =====================================================================
-- §4 no currency supplied means only any-currency stages match
-- =====================================================================
-- This is the fail-closed rule. A caller that has not been taught about currency must not be
-- able to trip a currency-specific tier, because it has no idea whether the number it is
-- passing is shillings or dollars.
do $$
declare t uuid := pg_temp.id('tenant'); r record;
begin
  select * into r from public.platform_approval_required_level(t, 120000000, 'manual_journals', null);
  perform pg_temp.assert(r.level = 1,
    '§4 with no currency, the 120,000,000 must not reach the UGX tier — it could be dollars');

  select * into r from public.platform_approval_required_level(t, 30000, 'manual_journals', null);
  perform pg_temp.assert(r.level = 1,
    '§4 with no currency, the 30,000 must not reach the USD tier');

  -- The three-argument call has to keep working, and behaves as the null case above.
  select * into r from public.platform_approval_required_level(t, 120000000, 'manual_journals');
  perform pg_temp.assert(r.level = 1,
    '§4 omitting the currency entirely must behave exactly like passing null');
  raise notice 'PASS: §4 a currency tier can never be applied when the caller has not said which currency';
end $$;

-- =====================================================================
-- §5 stored codes are compared case- and space-insensitively
-- =====================================================================
do $$
declare t uuid := pg_temp.id('tenant'); r record;
begin
  -- The USD tier was stored as ' usd '. A hand-typed code in an admin screen arrives like that.
  select * into r from public.platform_approval_required_level(t, 30000, 'manual_journals', 'USD');
  perform pg_temp.assert(r.level = 3, '§5 a stored '' usd '' must match a caller passing ''USD''');
  select * into r from public.platform_approval_required_level(t, 30000, 'manual_journals', 'usd');
  perform pg_temp.assert(r.level = 3, '§5 a caller passing lowercase ''usd'' must match too');
  raise notice 'PASS: §5 currency comparison is trimmed and case-insensitive';
end $$;

-- =====================================================================
-- §6 the refund helper resolves at every arity it is used at
-- =====================================================================
-- A defaulted third parameter collides with the existing two-argument function and makes
-- two-argument calls fail with 42725 at CALL time. Both were tried against a database before
-- this file was written; these assertions are here so the next person cannot reintroduce it.
do $$
declare t uuid := pg_temp.id('tenant'); r record;
begin
  -- Two arguments: still resolvable, and does not use the UGX refund tier.
  select * into r from public.platform_ins_refund_required_level(t, 5000000);
  perform pg_temp.assert(r.level = 1,
    '§6 the two-argument refund lookup must still resolve and must ignore currency tiers');

  -- Three arguments: currency-aware, and reaches the UGX refund tier.
  select * into r from public.platform_ins_refund_required_level(t, 5000000, 'UGX');
  perform pg_temp.assert(r.level = 2, '§6 a 5,000,000 UGX refund should reach the UGX refund tier');

  select * into r from public.platform_ins_refund_required_level(t, 5000000, 'USD');
  perform pg_temp.assert(r.level = 1, '§6 a USD refund must not use the UGX refund tier');
  raise notice 'PASS: §6 the refund lookup resolves at both arities and routes on currency';
end $$;

-- =====================================================================
-- §7 an unconfigured company is untouched
-- =====================================================================
do $$
declare o uuid := pg_temp.id('other'); r record; n integer;
begin
  select count(*) into n from public.platform_approval_required_level(o, 100000000, 'manual_journals', 'USD');
  perform pg_temp.assert(n = 0,
    '§7 a company with no manual-journal stages must still require no extra level');

  -- And the refund minimum control still applies, in any currency.
  select * into r from public.platform_ins_refund_required_level(o, 100000000, 'UGX');
  perform pg_temp.assert(r.level = 1 and r.approver_role = 'finance',
    '§7 the refund minimum control (Appendix B Q2) must survive, in every currency');
  raise notice 'PASS: §7 adding currency to the key changed nothing for a company that configures no stages';
end $$;

do $$ begin
  raise notice 'ALL PASS: approval routing is per currency, a currency tier cannot capture another currency, and a caller that does not say which currency it means can only reach any-currency stages';
end $$;

rollback;
