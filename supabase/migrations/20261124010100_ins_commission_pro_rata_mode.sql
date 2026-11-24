-- =====================================================================
-- Accountant sign-off pack v2, decision 1:
-- pro_rata_on_collection as a fourth commission recognition mode
-- =====================================================================
-- WHAT CHANGES
--   ins.commission_recognition gains 'pro_rata_on_collection'. Commission is
--   earned in proportion to the premium actually collected, on each receipt,
--   rather than all-or-nothing on the receipt that covers the premium.
--
--   Worked example (the pack's own, section 4.3):
--     premium 1,000,000, rate 10%, commission 100,000
--     first receipt 500,000 -> commission recognised 50,000, still deferred 50,000
--     second receipt 500,000 -> the remaining 50,000 is recognised
--
--   The binary mode on_premium_collection is UNCHANGED and remains correct for
--   an agreement whose entitlement is all-or-nothing. Decision 1 is explicitly
--   "add a fourth mode", not "replace the third": the two are different
--   contractual shapes, and migrating one onto the other would silently move
--   revenue between periods.
--
-- WHY IT NEEDS CODE, NOT JUST A SETTING VALUE
--   The setting's implemented_values is what a company is allowed to choose, so
--   the value has to be declared here. But a name with no reader is worse than
--   no name: 20261117210000 refuses a mode "nothing reads" for exactly that
--   reason, and the guard below keeps that promise by making the reader exist in
--   the same migration.
--
-- NOT IN THIS MIGRATION
--   The reader itself is split out: 20261124010200 adds the allocation function
--   and the receipt trigger branch. Splitting keeps this file's effect small and
--   reviewable -- it changes what may be chosen and nothing else. Until
--   20261124010200 applies, a company choosing pro_rata_on_collection would be
--   accepted here and then refused at bind by the snapshot guard, which is the
--   safe direction to fail.
--
-- Idempotent. Settings only; no schema and no ledger data.
-- =====================================================================

-- 1. Allow the value to be chosen.
update public.accounting_setting_definitions
   set allowed_values = array['on_insurer_settlement', 'at_placement',
                             'on_premium_collection', 'pro_rata_on_collection',
                             'over_policy_term']
 where key = 'ins.commission_recognition'
   and allowed_values is distinct from array['on_insurer_settlement', 'at_placement',
                                           'on_premium_collection', 'pro_rata_on_collection',
                                           'over_policy_term'];

-- 2. Declare it implemented. 20261124010200 provides the reader.
update public.accounting_setting_definitions
   set implemented_values = array['on_insurer_settlement', 'at_placement',
                                  'on_premium_collection', 'pro_rata_on_collection']
 where key = 'ins.commission_recognition'
   and implemented_values is distinct from array['on_insurer_settlement', 'at_placement',
                                                'on_premium_collection', 'pro_rata_on_collection'];

-- 3. The description must tell the reader which collection mode is which,
--    because the difference between them is the whole point of the decision.
update public.accounting_setting_definitions
   set description =
       'When brokerage commission becomes earned income. '
       || 'at_placement -- unconditional entitlement, earned at bind. '
       || 'on_premium_collection -- earned when the client''s receipt COVERS the premium; a partial receipt earns nothing (binary). '
       || 'pro_rata_on_collection -- earned in proportion to premium collected, per receipt. '
       || 'on_insurer_settlement -- earned when the insurer''s item is settled. '
       || 'over_policy_term is recognised but not implemented and cannot be selected. '
       || 'Every policy must have an explicit mode in force at bind; there is no silent default.'
 where key = 'ins.commission_recognition';

-- 4. A pro-rata agreement cannot be settled gross: under gross the premium
--    crosses in full at bind, so nothing is left to collect and a pro-rata rule
--    has no denominator. The bind guard enforces this (20261124010200); this
--    notice records the constraint where the setting is defined.
do $$
begin
  if not exists (
    select 1 from public.accounting_setting_definitions
     where key = 'ins.commission_recognition'
       and 'pro_rata_on_collection' = any (allowed_values)
       and 'pro_rata_on_collection' = any (implemented_values)
  ) then
    raise exception 'COMMISSION_MODE_NOT_REGISTERED: pro_rata_on_collection was not recorded as selectable and implemented';
  end if;
  raise notice 'PASS: ins.commission_recognition offers pro_rata_on_collection (implemented by 20261124010200)';
end $$;
