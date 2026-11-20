-- =====================================================================
-- The commission_recognition definition describes all three cases
-- =====================================================================
-- Its description still said only what on_insurer_settlement does, which is
-- what a company sees in the settings screen when choosing. A company cannot
-- make a sound choice from a description of one option out of three.
--
-- The default is deliberately NOT changed to at_placement. The owner's decision
-- is that recognition follows the insurer agreement, and that placement
-- recognition must not be unconditional: some agreements make commission
-- conditional on the policyholder paying, and earning those at bind overstates
-- both revenue and the amount recoverable. A global default of at_placement
-- would do exactly that to every policy of every company that has not
-- classified its agreements -- it would be the unconditional rule the decision
-- rejects. on_insurer_settlement stays the default because it is the historic
-- behaviour and the conservative one: nothing is recognised before an event
-- proves the entitlement. The classification is a per-company choice, and the
-- accountant pack (section 5.13) asks for it explicitly.
update public.accounting_setting_definitions
   set description =
       'When brokerage commission is recognised as income. Recognise the entitlement the insurer agreement actually gives, not a house rule: '
       || 'at_placement -- the entitlement is unconditional once the policy is placed, so bind earns it (income credited at bind, unearned commission never used). '
       || 'on_premium_collection -- the agreement makes commission conditional on the policyholder paying, so it is earned by the receipt that covers the premium; a part payment earns nothing and a voided receipt un-earns it. '
       || 'on_insurer_settlement (the default) -- entitlement follows the insurer, so commission sits in unearned commission until a posted settlement fully pays the insurer''s item for the policy. '
       || 'A gross settlement basis forces at_placement, because the premium crosses in full at bind and there is nothing left to collect or settle.'
 where key = 'ins.commission_recognition';

update public.accounting_setting_definitions
   set label = 'Commission recognition (insurance brokerage) -- one of three, by agreement'
 where key = 'ins.commission_recognition';
