-- Fix 20261108030000: ins_import_post_opening_position added its balancing
-- line to opening_balance_clearing unconditionally, with both a debit and a
-- credit amount (one of them 0). Receivable = payable + unearned commission
-- by construction, so the plug is normally 0/0, which journal_entry_lines_
-- one_side_check rejects (exactly one side must be > 0). Add the line only
-- when there is a difference, on the correct side. Otherwise identical.

create or replace function public.ins_import_post_opening_position(p_batch_id uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  v_plug numeric := 0;
  v_tenant uuid := public.get_my_tenant_id();
  b public.ins_import_batches;
  pol record;
  v_je journal_entries;
  v_lines jsonb := '[]'::jsonb;
  v_desc text;
  v_ar_gl uuid; v_pay_gl uuid; v_unearned_gl uuid; v_clearing_gl uuid;
  v_ar_acc uuid; v_ins_acc uuid;
  v_comm numeric; v_net numeric;
  v_total_ar numeric := 0; v_total_pay numeric := 0; v_total_unearned numeric := 0;
  v_posted boolean := false;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into b from public.ins_import_batches
  where id = p_batch_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if b.status <> 'committed' then
    raise exception 'INS_IMPORT_NOT_COMMITTED: commit policies before posting the opening position';
  end if;
  if exists (select 1 from public.ins_import_receipts where batch_id = p_batch_id)
     or exists (select 1 from public.journal_entries
                 where tenant_id = v_tenant and source_type = 'ins_import_opening'
                   and source_id = p_batch_id) then
    return jsonb_build_object('already_posted', true, 'batch_id', p_batch_id);
  end if;

  v_ar_gl       := public.get_posting_account(v_tenant, 'ar_control');
  v_pay_gl      := public.get_posting_account(v_tenant, 'insurer_payable');
  v_unearned_gl := public.get_posting_account(v_tenant, 'unearned_commission');
  v_clearing_gl := public.get_posting_account(v_tenant, 'opening_balance_clearing');
  if v_ar_gl is null or v_pay_gl is null or v_unearned_gl is null or v_clearing_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: chart needs ar_control, insurer_payable, unearned_commission, opening_balance_clearing';
  end if;

  set local ins.via_rpc = 'on';

  for pol in
    select p.id, p.policy_no, p.inception_date, p.gross_premium, p.currency,
           p.commission_amount, p.client_id, p.insurer_id
    from public.ins_policies p
    where p.tenant_id = v_tenant and p.import_batch_id = p_batch_id
    order by p.policy_no
  loop
    v_comm := coalesce(pol.commission_amount, 0);
    v_net  := pol.gross_premium - v_comm;

    v_ar_acc  := public.ins_ensure_client_account(pol.client_id);
    v_ins_acc := public.ins_ensure_insurer_account(pol.insurer_id);

    v_desc := 'Opening position (import ' || left(p_batch_id::text, 8) || '): ' || pol.policy_no;

    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ar_gl, 'debit', pol.gross_premium, 'currency', pol.currency, 'description', v_desc));
    v_total_ar := v_total_ar + pol.gross_premium;

    perform public.fin_create_open_item_fx(
      v_tenant, v_ar_acc, 'ar_control', 'ins_policy_premium', pol.id,
      pol.policy_no, pol.inception_date, b.cut_over_date, pol.gross_premium,
      'Opening receivable: ' || pol.policy_no, pol.currency, null);

    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_pay_gl, 'credit', v_net, 'currency', pol.currency, 'description', v_desc));
    v_total_pay := v_total_pay + v_net;

    perform public.fin_create_open_item_fx(
      v_tenant, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', pol.id,
      pol.policy_no, pol.inception_date, b.cut_over_date, v_net,
      'Opening payable: ' || pol.policy_no, pol.currency, null);

    if v_comm > 0 then
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object('gl_account_id', v_unearned_gl, 'credit', v_comm, 'currency', pol.currency,
                           'description', v_desc || ' - unearned commission'));
      v_total_unearned := v_total_unearned + v_comm;
      insert into public.ins_commission_entries (tenant_id, policy_id, amount, status)
      values (v_tenant, pol.id, v_comm, 'deferred');
    end if;
  end loop;

  -- balancing line to opening_balance_clearing. By construction receivable =
  -- payable + unearned commission, so the plug is normally zero; a journal
  -- line must have exactly one non-zero side, so the line is added only when
  -- there is a difference to clear.
  v_plug := v_total_pay + v_total_unearned - v_total_ar;   -- > 0: debit clearing
  if v_plug <> 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_clearing_gl,
        case when v_plug > 0 then 'debit' else 'credit' end, abs(v_plug),
        'currency', (select distinct currency from public.ins_policies where tenant_id = v_tenant and import_batch_id = p_batch_id),
        'description', 'Opening balance clearing (import ' || left(p_batch_id::text, 8) || ')'));
  end if;

  v_je := public.post_journal_entry(v_tenant, 'ins_import_opening', p_batch_id, b.cut_over_date,
    'Opening position for import batch ' || left(p_batch_id::text, 8), v_lines);
  v_posted := true;
  reset ins.via_rpc;

  return jsonb_build_object(
    'already_posted', false, 'batch_id', p_batch_id, 'journal_entry_id', v_je.id,
    'ar_total', v_total_ar, 'payable_total', v_total_pay, 'unearned_total', v_total_unearned);
end $$;
revoke all on function public.ins_import_post_opening_position(uuid) from public, anon;
grant execute on function public.ins_import_post_opening_position(uuid) to authenticated;