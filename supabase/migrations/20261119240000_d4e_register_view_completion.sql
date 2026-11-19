-- ============================================================================
-- D4e register view: catch it up with the table, and be the single definition
-- the screens and the reports share.
--
-- bank_adjustment_register (20261119064626) was written before the completion
-- pass. It therefore lacks three things the screens now need, and the web
-- register had to read bank_adjustments directly with its own joins:
--   * approval_mode       - how a decision was allowed (two_person vs the
--                           one-person exception), added in 20261119210000;
--   * the statement line  - its id (a rework or a drill-through needs it) and
--                           its description (the register showed only the
--                           reference);
--   * counter_account_id  - the id behind the code/name pair, for links.
-- Reading the view instead of the table is also what makes
-- bank_adjustment_exceptions one definition rather than two.
--
-- CREATE OR REPLACE VIEW can only append columns, and these are appended, so
-- bank_adjustment_exceptions (which selects * from the register) keeps working
-- and gains them too. security_invoker is restated: without it the view would
-- run as its owner and bypass the caller's RLS.
--
-- Fix forward (rule 9): 20261119064626 and 20261119210000 are not edited.
-- Idempotent; safe to replay. Views hold no data.
-- ============================================================================

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
  a.reversed_at,
  -- appended by 20261119240000
  a.approval_mode,
  a.bank_statement_line_id,
  l.description         as bank_line_description,
  a.counter_account_id
from public.bank_adjustments a
join public.bank_statement_lines l on l.id = a.bank_statement_line_id
join public.gl_accounts ga        on ga.id = a.counter_account_id
left join public.app_users cu     on cu.id = a.created_by
left join public.app_users du     on du.id = a.decided_by;

comment on view public.bank_adjustment_register is
  'One row per bank adjustment or reversal, with the statement line, the counter-account, both actors and how the decision was allowed (approval_mode). security_invoker: RLS of the caller applies (finance-only, same tenant). The accountant register and the exception report both read this.';

-- The exception report is defined off the register; recreating it here keeps its
-- columns and its invoker setting explicit rather than inherited by accident.
create or replace view public.bank_adjustment_exceptions
with (security_invoker = true) as
select * from public.bank_adjustment_register
where self_approved = true and status in ('posted', 'reversed');

comment on view public.bank_adjustment_exceptions is
  'Posted or reversed adjustments that were approved by the person who proposed them, under an approved and compliance-reviewed one-person exception (allow_self_approved_bank_adjustments). This is the accountant sign-off list.';
