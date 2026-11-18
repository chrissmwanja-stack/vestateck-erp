-- =====================================================================
-- Insurance: client-paid broker fees — VAT exemption, classification
-- and incoming withholding (item 7)
-- =====================================================================
--
-- What was already built, and what this changes
-- ---------------------------------------------
-- Charging a fee to the client is not new. Bind already takes broker fees with
-- VAT, posts each to its own revenue account, raises the client open item and
-- refunds a share at cancellation. None of that is touched here.
--
-- This patch fixes what was wrong or missing around it:
--
--   1. THE CLIENT STATEMENT UNDER-BILLED BY EVERY FEE. Verified on a harness:
--      a UGX 1,000,000 policy with a 50,000 fee at 18% VAT debits ar_control
--      1,059,000 and creates a 1,059,000 open item, while ins_client_statement
--      reported 1,000,000 billed. The statement recomputed billing as
--      gross_premium + endorsement premium_delta instead of reading the ledger,
--      so charges were never in it. Every fee-bearing policy in the book has
--      been under-reported to the client and to the aged-debtors report.
--
--   2. A BROKERAGE FEE DEFAULTS TO 18% VAT. It should not. Uganda's VAT Act
--      (Cap 344), Schedule 3, includes brokerage within insurance services, and
--      insurance services are exempt supplies. A genuine insurance-brokerage fee
--      is therefore EXEMPT and must default to no VAT. An 18% default
--      overcharged every client who was ever billed a fee, and over-declared
--      output VAT that was never due.
--
--   3. THERE WAS NO GOVERNED VAT RATE. 18% was typed per charge by whoever
--      configured the policy, with a test comment noting it must not be read as
--      a statutory rate. Because a taxable fee category still needs a rate, the
--      rate moves into the same approved, effective-dated parameter mechanism
--      the rest of the tax model uses.
--
--   4. FEES COULD NOT BE CLASSIFIED. All fees were one kind, so a taxable
--      consultancy charge was indistinguishable from exempt brokerage. Without
--      that distinction the exemption cannot be applied to one and not the
--      other.
--
--   5. INCOMING WITHHOLDING ON FEES WAS NOT MODELLED AT ALL. See section 9.
--
-- The VAT rule, stated as the law states it
-- -----------------------------------------
-- Exemption attaches to the NATURE of the supply, not to the fact that a broker
-- issued the invoice. So the fee carries an explicit classification, and the
-- classification decides the VAT treatment. A taxable category stays available
-- and standard-rated; it must be chosen deliberately, with a reason recorded.
--
-- What is deliberately NOT decided here
-- -------------------------------------
-- Whether a client-paid fee is a professional fee under s.129, and therefore
-- subject to 6% withheld by the client, is NOT settled. Being VAT-exempt does
-- not answer it; exemption and withholding are independent questions. So the
-- rate is parameterised, seeded as a draft that nobody may approve by accident,
-- and no withholding happens until somebody accountable says it does. Section 9.
--
-- Idempotent: add-column-if-not-exists, create-or-replace throughout, inserts
-- guarded by on-conflict.

-- ---------------------------------------------------------------------
-- 1. Two more parameter keys: the statutory rate, and the fee WHT rate
-- ---------------------------------------------------------------------
insert into public.regulatory_parameter_definitions (key, category, description, value_type, class_scoped)
values
  ('tax.vat_standard_rate_percent', 'tax',
   'Standard VAT rate applied to taxable supplies. Insurance brokerage fees are exempt under Schedule 3 of the VAT Act and must not default to this rate.',
   'percent', false),
  ('tax.wht_client_fee_percent', 'tax',
   'Rate at which a client withholds tax on a fee the brokerage invoices (Income Tax Act s.129 and s.136). Whether a brokerage fee is a professional fee under s.129 is not settled; see the source reference on the seeded row.',
   'percent', false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. A fee now says what kind of fee it is
-- ---------------------------------------------------------------------
-- Two kinds, because the VAT answer differs and the difference is the whole
-- point. 'insurance_brokerage' is the exempt one; 'other_taxable_service' exists
-- so that a genuinely taxable charge is not forced into the exempt bucket, and
-- so that choosing it is a visible act.
alter table public.ins_policy_charges
  add column if not exists fee_class text,
  add column if not exists fee_class_reason text,
  add column if not exists vat_rate_parameter_ref uuid;

comment on column public.ins_policy_charges.fee_class is
  'What kind of supply this fee is. Insurance brokerage is VAT-exempt under Schedule 3 of the VAT Act; a separate taxable service is not. Null on pass-through charges, which never carry VAT.';
comment on column public.ins_policy_charges.fee_class_reason is
  'Why a fee was classified as taxable, when the default is exempt. Required for other_taxable_service: the exemption is the default, so departing from it has to be a recorded decision with a stated basis.';
comment on column public.ins_policy_charges.vat_rate_parameter_ref is
  'The approved tax.vat_standard_rate_percent row the rate was copied from. Copied rather than joined, so a later rate change cannot rewrite a bound policy.';

-- Existing fee rows: every fee in the book was charged as taxable, and the
-- honest description of a fee already invoiced with VAT is that it was
-- classified as a taxable service. Rewriting it to exempt now would reverse VAT
-- that has already been declared. Historical rows therefore keep their
-- treatment; only new configurations get the exempt default.
update public.ins_policy_charges
   set fee_class = 'other_taxable_service',
       fee_class_reason = coalesce(fee_class_reason,
         'Backfilled: invoiced with VAT before fee classification existed. Retained as taxable because the output VAT was declared.')
 where kind = 'broker_fee' and fee_class is null;

alter table public.ins_policy_charges
  drop constraint if exists ins_policy_charges_fee_class_check;
alter table public.ins_policy_charges
  add constraint ins_policy_charges_fee_class_check check (
    (kind = 'insurer_pass_through' and fee_class is null)
    or (kind = 'broker_fee' and fee_class in ('insurance_brokerage', 'other_taxable_service')));

-- The rule that keeps the two in step, enforced by the database rather than by
-- whichever screen happens to be used:
--   * exempt brokerage never carries VAT;
--   * a taxable service that charges VAT must say why it is not exempt;
--   * a taxable service may still be charged without VAT (zero-rated or exempt
--     for another reason), but it cannot silently carry a rate with no basis.
alter table public.ins_policy_charges
  drop constraint if exists ins_policy_charges_fee_vat_consistency_check;
alter table public.ins_policy_charges
  add constraint ins_policy_charges_fee_vat_consistency_check check (
    kind <> 'broker_fee'
    or (fee_class = 'insurance_brokerage'
        and vat_mode = 'not_calculated' and vat_rate_pct is null and coalesce(vat_amount, 0) = 0)
    or (fee_class = 'other_taxable_service'
        and (vat_mode = 'not_calculated'
             or (vat_mode = 'exclusive'
                 and vat_rate_pct is not null
                 and fee_class_reason is not null
                 and length(btrim(fee_class_reason)) >= 20))));

-- ---------------------------------------------------------------------
-- 3. Configuration: classify, default to exempt, price the rate
-- ---------------------------------------------------------------------
-- The old body is reproduced unchanged except where marked. The changes are:
--   * a fee must arrive with a fee_class;
--   * vat_rate_pct may be omitted for a taxable fee, in which case the approved
--     standard rate is used and remembered;
--   * an exempt fee carrying VAT is refused here with a message that explains
--     the law, rather than only by the constraint;
--   * a taxable fee must carry a reason.
create or replace function public.ins_set_policy_financial_configuration(
  p_policy_id uuid, p_shares jsonb, p_charges jsonb)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  p ins_policies%rowtype; x jsonb; lead_id uuid; n integer; total numeric;
  v_rate numeric; v_param uuid; v_class text; v_reason text;
begin
 if not can_manage_insurance() or effective_user_id() is distinct from auth.uid() then
   raise exception 'INS_FORBIDDEN: an Insurance manager acting as themselves is required' using errcode='42501';
 end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 if p.status<>'draft' then raise exception 'INS_FINANCIAL_IMMUTABLE: only drafts can be configured'; end if;
 if jsonb_typeof(p_shares) is distinct from 'array' or jsonb_typeof(p_charges) is distinct from 'array'
    or jsonb_array_length(p_shares)>30 or jsonb_array_length(p_charges)>100 then raise exception 'INS_CONFIG_INPUT: invalid configuration arrays'; end if;
 delete from ins_policy_charges where policy_id=p.id;
 delete from ins_policy_insurer_shares where policy_id=p.id;
 for x in select * from jsonb_array_elements(p_shares) loop
   if (x->>'share_pct')::numeric is null or (x->>'share_pct')::numeric<>round((x->>'share_pct')::numeric,4)
      or (x->>'commission_rate_pct')::numeric is null or (x->>'commission_rate_pct')::numeric<>round((x->>'commission_rate_pct')::numeric,4)
      or not exists(select 1 from ins_insurers where id=(x->>'insurer_id')::uuid and tenant_id=p.tenant_id and is_active) then
     raise exception 'INS_CONFIG_INPUT: active insurer, share and commission rate are required (maximum four decimals)';
   end if;
   insert into ins_policy_insurer_shares(tenant_id,policy_id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,reviewed)
   values(p.tenant_id,p.id,(x->>'insurer_id')::uuid,coalesce((x->>'is_lead')::boolean,false),
    (x->>'share_pct')::numeric,(x->>'commission_rate_pct')::numeric,nullif(btrim(x->>'insurer_policy_no'),''),coalesce((x->>'reviewed')::boolean,false));
 end loop;
 select count(*) filter(where is_lead),sum(share_pct) into n,total from ins_policy_insurer_shares where policy_id=p.id;
 if jsonb_array_length(p_shares)>0 and (n<>1 or total<>100) then raise exception 'INS_SHARE_TOTAL: shares must total exactly 100%% with exactly one lead insurer'; end if;
 if jsonb_array_length(p_shares)=0 and jsonb_array_length(p_charges)>0 then raise exception 'INS_SHARE_REQUIRED: charges require explicit insurer allocation'; end if;

 for x in select * from jsonb_array_elements(p_charges) loop
   if (x->>'amount')::numeric is not null and ((x->>'amount')::numeric<>round((x->>'amount')::numeric,2) or (x->>'amount')::numeric>9999999999999999.99) then
     raise exception 'INS_CONFIG_INPUT: charge amounts need at most two decimals';
   end if;
   if (x->>'vat_rate_pct')::numeric is not null and (x->>'vat_rate_pct')::numeric<>round((x->>'vat_rate_pct')::numeric,4) then
     raise exception 'INS_CONFIG_INPUT: VAT rate accepts at most four decimals';
   end if;
   if x->>'recipient_mode'='one_insurer' and not exists(select 1 from ins_policy_insurer_shares where policy_id=p.id and insurer_id=(x->>'recipient_insurer_id')::uuid) then
     raise exception 'INS_CHARGE_RECIPIENT: intended insurer must participate in this policy';
   end if;

   -- --- new: fee classification drives the VAT treatment -----------------
   v_class  := nullif(btrim(coalesce(x->>'fee_class', '')), '');
   v_reason := nullif(btrim(coalesce(x->>'fee_class_reason', '')), '');
   v_rate   := (x->>'vat_rate_pct')::numeric;
   v_param  := null;

   if x->>'kind' = 'broker_fee' then
     if v_class is null then
       -- Refused rather than defaulted. A silent default to exempt would be
       -- right for a brokerage fee and wrong for a consultancy charge, and the
       -- caller is the only one who knows which it is.
       raise exception 'INS_FEE_CLASS_REQUIRED: every broker fee must say what kind of supply it is. Use insurance_brokerage for a genuine brokerage fee (exempt under Schedule 3 of the VAT Act) or other_taxable_service for a separate taxable service'
         using errcode = '22023';
     end if;
     if v_class not in ('insurance_brokerage', 'other_taxable_service') then
       raise exception 'INS_FEE_CLASS_INVALID: % is not a fee class; use insurance_brokerage or other_taxable_service', v_class
         using errcode = '22023';
     end if;

     if v_class = 'insurance_brokerage' then
       if coalesce(x->>'vat_mode', 'not_calculated') = 'exclusive' or v_rate is not null then
         raise exception 'INS_FEE_VAT_EXEMPT: a genuine insurance brokerage fee is exempt under Schedule 3 of the VAT Act (brokerage is included in insurance services) and cannot carry VAT. If this charge is a separate taxable service, classify it as other_taxable_service with the reason'
           using errcode = '23514';
       end if;
     else
       if v_reason is null or length(v_reason) < 20 then
         raise exception 'INS_FEE_CLASS_REASON: classifying a fee as a taxable service departs from the exempt default, so it needs a reason of at least 20 characters. It is what an auditor reads when asking why this fee, unlike a brokerage fee, carried VAT'
           using errcode = '22023';
       end if;
       if coalesce(x->>'vat_mode', 'not_calculated') = 'exclusive' and v_rate is null then
         -- The rate may be omitted: the approved standard rate is the default
         -- for a taxable supply, and it is copied so a later change cannot
         -- rewrite this policy.
         select r.value_num, r.id into v_rate, v_param
           from public.regulatory_parameters r
          where r.tenant_id = p.tenant_id
            and r.parameter_key = 'tax.vat_standard_rate_percent'
            and r.status = 'approved'
            and r.effective_from <= p.inception_date
            and coalesce(r.effective_to, 'infinity'::date) >= p.inception_date
          order by r.effective_from desc
          limit 1;
         if v_rate is null then
           raise exception 'INS_FEE_VAT_RATE_MISSING: this fee is taxable but no approved standard VAT rate covers %. Approve tax.vat_standard_rate_percent, or supply vat_rate_pct explicitly if this supply carries a different rate',
             p.inception_date;
         end if;
       end if;
     end if;
   end if;

   insert into ins_policy_charges(tenant_id,policy_id,kind,description,amount,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,reviewed,
                                  fee_class,fee_class_reason,vat_rate_parameter_ref)
   values(p.tenant_id,p.id,x->>'kind',x->>'description',(x->>'amount')::numeric,x->>'recipient_mode',(x->>'recipient_insurer_id')::uuid,
    coalesce(x->>'vat_mode','not_calculated'),v_rate,(x->>'income_gl_account_id')::uuid,coalesce((x->>'reviewed')::boolean,false),
    v_class,v_reason,v_param);
 end loop;

 select insurer_id into lead_id from ins_policy_insurer_shares where policy_id=p.id and is_lead;
 if lead_id is not null then
   perform set_config('ins.via_rpc','on',true);
   update ins_policies set insurer_id=lead_id,
    commission_rate_pct=case when jsonb_array_length(p_shares)=1 then (select commission_rate_pct from ins_policy_insurer_shares where policy_id=p.id) else commission_rate_pct end
    where id=p.id;
 end if;
end $function$;

revoke all on function public.ins_set_policy_financial_configuration(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.ins_set_policy_financial_configuration(uuid, jsonb, jsonb) to authenticated;


-- The rule this module already follows: an insurance reporting view runs as the
-- caller (security_invoker) and must not read a table an insurance-only user
-- cannot see. So the billed amount is reached through a definer helper that
-- re-checks tenant and module access on every call, exactly as
-- ins_policy_endorsement_receipts and ins_branch_name do for receipts and
-- branch names.
--
-- Helper rather than a widened grant: the finance table stays finance-only, and
-- the one number insurance needs is exposed by a function that cannot be used
-- to read anything else.
create or replace function public.ins_policy_billed_amount(p_policy_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  -- The amount raised less any credit applied, NOT the outstanding balance: the
  -- statement reports receipts separately, so netting payments here would count
  -- them twice. A credit note is a reduction of what was billed and belongs in
  -- this figure; a payment does not.
  select coalesce(sum(b.amount - b.credited_amount), 0)
    from public.fin_open_item_balances b
   where b.tenant_id = public.get_my_tenant_id()
     and b.side = 'receivable'
     and (
          (b.source_type = 'ins_policy_premium' and b.source_id = p_policy_id)
          -- Endorsements raise their own receivable rather than adjusting the
          -- bind item, so "what the client was billed" is the bind receivable
          -- plus whatever is still outstanding on the posted endorsements. A
          -- credit note against either reduces its outstanding, which is what
          -- makes this net cancellations without a separate adjustment.
          or (b.source_type = 'ins_policy_endorsement'
              and exists (select 1 from public.ins_policy_endorsements x
                           where x.id = b.source_id
                             and x.tenant_id = b.tenant_id
                             and x.policy_id = p_policy_id
                             and x.status = 'posted'))
        )
     and public.can_access_insurance();
$function$;

revoke all on function public.ins_policy_billed_amount(uuid) from public, anon;
grant execute on function public.ins_policy_billed_amount(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The client statement reads the ledger
-- ---------------------------------------------------------------------
-- This is the defect, and the fix is a change of method rather than a tweak.
--
-- The view recomputed what a client had been billed:
--
--     billed = gross_premium + sum(posted endorsement premium_delta)
--
-- but the amount the client actually owes is the `ins_policy_premium` open item
-- created at bind, which includes every charge and its VAT. The recomputation
-- got endorsements right by adding their delta, and got everything else wrong:
-- broker fees, their VAT, and any future charge are all absent from it.
--
-- Verified before the change: a 1,000,000 policy with a 50,000 fee at 18% VAT
-- had an open item and an ar_control debit of 1,059,000, and this view reported
-- 1,000,000. The aged-debtors report is built on the same figure, so 59,000 per
-- policy was invisible to collections.
--
-- The new definition asks the ledger. Cancellations reduce the receivable
-- through credit notes, which is already reflected in the open item's
-- outstanding amount, so no separate adjustment is needed.
create or replace view public.ins_client_statement
with (security_invoker = true) as
select
  p.tenant_id,
  p.id as policy_id,
  p.policy_no,
  p.client_id,
  bd.name as client_name,
  p.currency,
  -- What the client was billed: the receivable raised at bind, in full. This is
  -- a ledger figure, not a recomputation, so it cannot drift from ar_control.
  public.ins_policy_billed_amount(p.id) as billed_amount,
  coalesce(r.received, 0::numeric) as received_amount,
  public.ins_policy_billed_amount(p.id) - coalesce(r.received, 0::numeric) as balance_amount,
  p.bound_at::date as bound_date,
  p.expiry_date,
  p.status,
  -- New, and the reason a client can now be told why: what the fee contributed
  -- to the bill, and how much of it carried VAT. Zero when no fee was charged.
  coalesce(fees.fee_total, 0::numeric) as broker_fee_amount,
  coalesce(fees.vat_total, 0::numeric) as broker_fee_vat_amount
from public.ins_policies p
  join public.ins_clients c on c.id = p.client_id
  join public.bd_clients bd on bd.id = c.client_id
  -- Fees and their VAT, for the client's own information. Read from the charge
  -- rows rather than the journal so that a fee is attributable to its
  -- description; the totals are the same numbers the bind posted.
  left join lateral (
    select sum(ch.amount) as fee_total, sum(coalesce(ch.vat_amount, 0)) as vat_total
      from public.ins_policy_charges ch
     where ch.tenant_id = p.tenant_id
       and ch.policy_id = p.id
       and ch.kind = 'broker_fee'
  ) fees on true
  left join lateral (
    select (
      (select coalesce(sum(q.amount), 0::numeric)
         from public.ins_policy_cash_requests q
        where q.tenant_id = p.tenant_id
          and q.policy_id = p.id
          and q.kind = 'receipt'
          and q.status = 'posted')
      + public.ins_policy_endorsement_receipts(p.id)
    ) as received
  ) r on true
where p.status = any (array['active', 'renewed'])
  and p.tenant_id = public.get_my_tenant_id()
  and public.can_access_insurance();

-- ---------------------------------------------------------------------
-- 5. Incoming withholding on a client-paid fee
-- ---------------------------------------------------------------------
-- A client who is a designated withholding agent may pay less than the invoice
-- and withhold the difference. That is not the brokerage's tax: it is money the
-- brokerage has already earned and will claim as a credit, so it cannot reduce
-- revenue and it is not a liability. It goes to wht_receivable (1210), which
-- already exists and was previously reached only by opening balances.
--
--   Dr  Bank                940,000
--   Dr  WHT receivable       60,000
--     Cr AR control                1,000,000
--
-- Revenue stays at the full 1,000,000 because the full fee was earned; the
-- 60,000 is an asset.
--
-- NOTHING IS WITHHELD AUTOMATICALLY. Whether a client-paid insurance brokerage
-- fee is a professional fee under s.129 is unsettled, and being VAT-exempt does
-- not answer it. The rate is a parameter, seeded unapproved, and a settlement
-- can only record withholding that a human asserted on the specific receipt,
-- with a reason. Withholding is customer money movement, so recording it here
-- does not invent the client's legal obligation.
create table if not exists public.ins_fee_wht_records (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete cascade,
  cash_request_id   uuid not null,
  client_id         uuid not null,
  currency          text not null,
  gross_amount      numeric(14,2) not null,
  wht_amount        numeric(14,2) not null,
  net_received      numeric(14,2) not null,
  wht_rate_pct      numeric(7,4) not null,
  wht_parameter_ref uuid,
  basis             text not null,
  reason            text not null,
  journal_entry_id  uuid,
  recorded_by       uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  constraint ins_fee_wht_records_amount_check check (wht_amount > 0 and gross_amount > 0),
  constraint ins_fee_wht_records_identity_check check (net_received = gross_amount - wht_amount),
  constraint ins_fee_wht_records_once_key unique (tenant_id, cash_request_id),
  constraint ins_fee_wht_records_basis_check check (basis in ('s129_professional_fee', 's136_designated_agent', 'other_approved')),
  constraint ins_fee_wht_records_reason_check check (length(btrim(reason)) >= 20)
);

comment on table public.ins_fee_wht_records is
  'Tax a client withheld from a fee the brokerage invoiced. An asset (a credit to claim), never a reduction of revenue and never a liability: the full fee was earned.';
comment on column public.ins_fee_wht_records.basis is
  'Which provision the withholding was asserted under: s129 professional fee, s136 designated withholding agent, or another basis a manager approved. Recorded because the same 6% under a different section is a different claim.';

create index if not exists ins_fee_wht_records_client_idx
  on public.ins_fee_wht_records (tenant_id, client_id);

alter table public.ins_fee_wht_records enable row level security;

drop policy if exists ins_fee_wht_records_select on public.ins_fee_wht_records;
create policy ins_fee_wht_records_select on public.ins_fee_wht_records
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on table public.ins_fee_wht_records from public, anon;
revoke insert, update, delete on table public.ins_fee_wht_records from authenticated;

-- ---------------------------------------------------------------------
-- 6. Recording it, once the receipt has settled
-- ---------------------------------------------------------------------
-- Deliberately after settlement rather than instead of it: the existing receipt
-- flow posts the cash and clears the receivable. This records that part of what
-- the client owed was withheld, and moves that part out of cash into a
-- recoverable asset, in one balanced entry. Splitting it into two flows would
-- let the two halves disagree.
create or replace function public.ins_record_fee_withholding(
  p_cash_request_id uuid,
  p_wht_amount      numeric,
  p_basis           text,
  p_reason          text,
  p_wht_rate_pct    numeric default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  q        public.ins_policy_cash_requests;
  v_rate   numeric;
  v_param  uuid;
  v_net    numeric;
  v_ar     uuid;
  v_wht_gl uuid;
  v_bank_gl uuid;
  v_je     public.journal_entries;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into q from public.ins_policy_cash_requests
   where id = p_cash_request_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_CASH_REQUEST_NOT_FOUND'; end if;
  if q.kind <> 'receipt' then
    raise exception 'INS_FEE_WHT_NOT_A_RECEIPT: withholding is recorded against money received from a client, not against a %', q.kind;
  end if;
  if q.status <> 'posted' then
    raise exception 'INS_FEE_WHT_NOT_POSTED: the receipt is %; record withholding once the cash is actually in, otherwise the entry describes money that has not arrived', q.status;
  end if;
  if exists (select 1 from public.ins_fee_wht_records r
              where r.tenant_id = v_tenant and r.cash_request_id = q.id) then
    return jsonb_build_object('recorded', false, 'already_recorded', true, 'cash_request_id', q.id);
  end if;

  if p_wht_amount is null or p_wht_amount <= 0 then
    raise exception 'INS_FEE_WHT_AMOUNT: the withheld amount must be positive; record nothing rather than zero';
  end if;
  if p_wht_amount >= q.amount then
    raise exception 'INS_FEE_WHT_EXCEEDS: the withheld amount % must be less than the receipt of %', p_wht_amount, q.amount;
  end if;
  if p_reason is null or length(btrim(p_reason)) < 20 then
    raise exception 'INS_FEE_WHT_REASON: recording withholding needs a reason of at least 20 characters. It is the evidence for a claim against the revenue authority';
  end if;

  -- The rate is the caller's if supplied (a specific arrangement), otherwise the
  -- approved parameter for the receipt date. Never assumed.
  v_rate := p_wht_rate_pct;
  if v_rate is null then
    select r.value_num, r.id into v_rate, v_param
      from public.regulatory_parameters r
     where r.tenant_id = v_tenant
       and r.parameter_key = 'tax.wht_client_fee_percent'
       and r.status = 'approved'
       and r.effective_from <= q.cash_date
       and coalesce(r.effective_to, 'infinity'::date) >= q.cash_date
     order by r.effective_from desc
     limit 1;
    if v_rate is null then
      raise exception 'INS_FEE_WHT_RATE_MISSING: no approved rate for client withholding on fees covers %. Whether a brokerage fee is a professional fee under s.129 is unsettled, so the rate cannot be assumed; approve tax.wht_client_fee_percent or pass the rate explicitly with the basis', q.cash_date;
    end if;
  end if;

  v_net := round(q.amount - p_wht_amount, 2);

  v_ar     := public.get_posting_account(v_tenant, 'ar_control');
  v_wht_gl := public.get_posting_account(v_tenant, 'wht_receivable');
  if v_ar is null or v_wht_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: recording client withholding needs the ar_control and wht_receivable posting rules';
  end if;
  -- The cash side is the receipt's own bank account, so the entry lands in the
  -- account the money actually went to.
  select b.gl_account_id into v_bank_gl
    from public.fin_bank_accounts b
   where b.id = q.bank_account_id and b.tenant_id = v_tenant;
  if v_bank_gl is null then
    raise exception 'INS_BANK_ACCOUNT_NOT_FOUND: the receipt names a bank account with no ledger account';
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_fee_withholding', q.id, q.cash_date,
    'Client withholding on fee, receipt ' || coalesce(q.reference, q.id::text),
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_bank_gl, 'debit',  v_net,
                         'currency', (select currency from public.fin_bank_accounts where id = q.bank_account_id),
                         'description', 'Received net of withholding'),
      jsonb_build_object('gl_account_id', v_wht_gl, 'debit', p_wht_amount,
                         'currency', (select currency from public.fin_bank_accounts where id = q.bank_account_id),
                         'description', 'Tax withheld by client: ' || btrim(p_reason)),
      jsonb_build_object('gl_account_id', v_ar, 'credit', q.amount,
                         'currency', (select currency from public.fin_bank_accounts where id = q.bank_account_id),
                         'description', 'Fee settled in full, part withheld')));

  insert into public.ins_fee_wht_records
    (tenant_id, cash_request_id, client_id, currency, gross_amount, wht_amount,
     net_received, wht_rate_pct, wht_parameter_ref, basis, reason, journal_entry_id)
  select v_tenant, q.id, p.client_id,
         (select currency from public.fin_bank_accounts where id = q.bank_account_id),
         q.amount, p_wht_amount, v_net, v_rate, v_param, p_basis, btrim(p_reason), v_je.id
    from public.ins_policies p where p.id = q.policy_id;

  return jsonb_build_object('recorded', true, 'cash_request_id', q.id,
                            'gross_amount', q.amount, 'wht_amount', p_wht_amount,
                            'net_received', v_net, 'rate_pct', v_rate,
                            'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_record_fee_withholding(uuid, numeric, text, text, numeric) from public, anon;
grant execute on function public.ins_record_fee_withholding(uuid, numeric, text, text, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- 7. The claim position: what is recoverable and against what
-- ---------------------------------------------------------------------
create or replace function public.ins_fee_withholding_position()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_total numeric := 0;
  v_rows jsonb;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select coalesce(sum(r.wht_amount), 0) into v_total
    from public.ins_fee_wht_records r where r.tenant_id = v_tenant;

  select coalesce(jsonb_agg(jsonb_build_object(
           'client_id', r.client_id,
           'currency', r.currency,
           'basis', r.basis,
           'wht_amount', r.wht_amount,
           'gross_amount', r.gross_amount,
           'recorded_on', r.created_at::date) order by r.created_at desc), '[]'::jsonb)
    into v_rows
    from public.ins_fee_wht_records r where r.tenant_id = v_tenant;

  return jsonb_build_object('recoverable_total', v_total, 'records', v_rows);
end
$function$;

revoke all on function public.ins_fee_withholding_position() from public, anon;
grant execute on function public.ins_fee_withholding_position() to authenticated;

-- ---------------------------------------------------------------------
-- 8. Journal source type and the read-only guard
-- ---------------------------------------------------------------------
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries
  add constraint journal_entries_source_type_check check (
    source_type = any (array[
      'supplier_invoice'::text, 'receivable_invoice'::text, 'cash_bank_transaction'::text,
      'opening_balance'::text, 'manual'::text, 'payroll_run'::text,
      'machine_fuel_log'::text, 'machine_maintenance_request'::text,
      'fin_settlement'::text, 'fin_settlement_void'::text,
      'fin_credit_note'::text, 'fin_credit_note_void'::text,
      'ins_policy_bind'::text, 'ins_commission_recognition'::text,
      'ins_commission_recognition_reversal'::text, 'ins_commission_transfer'::text,
      'ins_commission_transfer_void'::text, 'ins_claim_accrual'::text,
      'ins_policy_cancellation'::text, 'ins_cancellation_cash'::text,
      'fx_revaluation'::text, 'fx_revaluation_void'::text,
      'ins_policy_endorsement'::text, 'ins_import_opening'::text,
      'ins_agent_commission_accrual'::text,
      'ins_agent_commission_payment'::text,
      'ins_agent_commission_reversal'::text,
      'ins_wht_remittance'::text,
      'ins_fee_withholding'::text
    ]));

select public.apply_tenant_read_only_guard();

-- ---------------------------------------------------------------------
-- 9. Renewals carry the classification forward
-- ---------------------------------------------------------------------
-- platform_ins_create_renewal_pre_outcome_impl copies the charges of the policy
-- being renewed onto the new draft. It names its columns explicitly, so the
-- three new ones were silently dropped -- and the consistency constraint then
-- refused the copy, because a taxable fee arrived with a rate and no reason.
-- Every fee-bearing renewal would have failed.
--
-- The classification is carried, not recomputed: the renewed policy is the same
-- supply to the same client, so re-deriving it would let a rule change in
-- between flip an exempt fee to taxable on the renewal alone. The rate is
-- carried for the same reason. The rest of the body is reproduced unchanged.
create or replace function public.platform_ins_create_renewal_pre_outcome_impl(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare p ins_policies%rowtype;
begin
  if exists (
    select 1 from ins_policy_endorsements
     where policy_id = p_policy_id and status in ('proposed','prepared','posting')
  ) then
    raise exception 'INS_ENDORSEMENT_LIVE: finish or withdraw the live endorsement before renewing this policy';
  end if;
  p := platform_ins_create_renewal_legacy_impl(p_policy_id);
  insert into ins_policy_insurer_shares(tenant_id,policy_id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,reviewed)
  select tenant_id,p.id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,false from ins_policy_insurer_shares where policy_id=p_policy_id;
  insert into ins_policy_charges(tenant_id,policy_id,kind,description,amount,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,reviewed,
                                 fee_class,fee_class_reason,vat_rate_parameter_ref)
  select tenant_id,p.id,kind,description,null,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,false,
         fee_class,fee_class_reason,vat_rate_parameter_ref from ins_policy_charges where policy_id=p_policy_id;
  return p;
end $function$;

revoke all on function public.platform_ins_create_renewal_pre_outcome_impl(uuid) from public, anon;
