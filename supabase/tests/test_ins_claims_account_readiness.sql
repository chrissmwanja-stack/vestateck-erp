-- =====================================================================
-- Which claims controls are blocked, and by what
-- Accountant pack v2, Appendix B Q1
-- =====================================================================
-- The accountant will not name a claims-expense account code until they have seen the live
-- chart of accounts. Until they do, ins_write_off_claim refuses -- correctly, but only when
-- someone attempts a write-off, which is the worst moment to find out.
--
--   §1 an unmapped role is reported as unmapped, and named           (before anything exists)
--   §2 mapping it makes it read as mapped, with the real account    (after the accountant acts)
--   §3 the readiness view agrees with the write-off function itself (no drift between the
--                                                                   report and the refusal)
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

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  ta    uuid := gen_random_uuid();
  maker uuid := gen_random_uuid();
  v_row record;
  v_acct uuid;
  v_before boolean;
begin
  insert into tenants(id, name) values (ta, 'Claims readiness test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (maker, 'cr-' || maker || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now());
  insert into app_users(id, tenant_id, name, email)
    values (maker, ta, 'Claims clerk', 'cr-' || maker || '@test.local');
  perform pg_temp.jwt(maker);

  -- ------------------------------------------------------------------
  -- §1 unmapped is reported as unmapped
  -- ------------------------------------------------------------------
  -- This tenant has no gl_posting_rules at all, so the answer must be "no" rather than an
  -- empty result: a readiness view that hides the row it is warning about is worse than none.
  select * into v_row from public.ins_posting_role_readiness()
   where account_role = 'ins_claim_write_off_expense';
  perform pg_temp.assert(found, '§1 the claims account role must be listed even when unmapped');
  perform pg_temp.assert(not v_row.mapped, '§1 an unmapped role must not read as mapped');
  perform pg_temp.assert(v_row.says like 'NOT MAPPED%', '§1 an unmapped role must say so plainly');
  -- The message has to name the role and where the account belongs, or the reader still
  -- does not know what to do next.
  perform pg_temp.assert(v_row.says like '%ins_claim_write_off_expense%',
    '§1 the warning must name the posting role');
  perform pg_temp.assert(v_row.says like '%claims-expense%',
    '§1 the warning must say which range the account belongs in (Q1: the existing claims-expense range)');

  -- ------------------------------------------------------------------
  -- §2 once the accountant maps it, the view follows
  -- ------------------------------------------------------------------
  -- Deliberately a code this test invents for itself. The repository does not invent one:
  -- the real code is the accountant's decision, and hard-coding it here would be the
  -- software making that decision by accident.
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, 'ZZ-TEST-CLAIMS', 'Claims write-off expense (test only)', 'expense')
    returning id into v_acct;

  v_before := v_row.mapped;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
    values (ta, 'ins_claim_write_off_expense', v_acct);

  select * into v_row from public.ins_posting_role_readiness()
   where account_role = 'ins_claim_write_off_expense';
  perform pg_temp.assert(v_row.mapped, '§2 the role must read as mapped once it has an account');
  perform pg_temp.assert(v_row.account_code = 'ZZ-TEST-CLAIMS',
    format('§2 the view must name the mapped account, got %s', coalesce(v_row.account_code, 'null')));
  perform pg_temp.assert(v_row.says = 'mapped', '§2 a mapped role needs no warning');
  perform pg_temp.assert(not v_before, '§2 the §1 reading must have been the unmapped one, or §2 proves nothing');

  -- ------------------------------------------------------------------
  -- §3 the view and the function agree
  -- ------------------------------------------------------------------
  -- ins_claim_contra_account is what the write-off path actually resolves. If it ever
  -- started reading a different rule from the one the readiness view reports, an accountant
  -- would be told the control is configured while a write-off failed.
  perform pg_temp.assert(public.ins_claim_contra_account(ta) = v_acct,
    '§3 the contra account the write-off path resolves must be the one the readiness view reports');

  raise notice 'PASS: §1 an unmapped claims account says so, §2 mapping it is reflected, and §3 the report agrees with the write-off path';
end $$;

rollback;
