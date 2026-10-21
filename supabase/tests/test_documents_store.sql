-- Shared document store (20261021100000_shared_document_store.sql).
--
--   1. documents_register happy path: the row lands with the caller's tenant,
--      hash and created_by, and is readable through the table.
--   2. Input validation: bucket, tenant folder, hash, size, entity, kind, and
--      the unique (bucket, path) key.
--   3. The storage path pins the tenant: another tenant's folder is refused,
--      so the registry and the storage RLS can never disagree about ownership.
--   4. Writes are RPC-only: a direct insert meets the guard (42501
--      DOCUMENTS_RPC_ONLY); updates and deletes match nothing (there is no
--      UPDATE/DELETE policy -- the registry is append-only).
--   5. Reads: same tenant + a consuming module role (insurance/finance/PO).
--      A same-tenant user with none of them sees nothing; another tenant's
--      manager sees nothing.
--   6. Storage RLS: authenticated users write and read only their tenant's
--      folder in the tenant-documents bucket.
--
-- Run inside a transaction that is rolled back, so it leaves no data behind.
-- Any RAISE EXCEPTION is a real assertion failure and makes psql exit non-zero.

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_needle in sqlerrm) > 0 then
      return;
    end if;
    raise exception 'FAIL: % raised "%", expected "%"', p_label, sqlerrm, p_needle;
  end;
  raise exception 'FAIL: % succeeded but should have failed with "%"', p_label, p_needle;
end $$;

create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      return;
    end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
end $$;

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

create function pg_temp.doc_via_off() returns void language sql as $$
  select set_config('documents.via_rpc', 'off', true);
$$;

do $$
declare
  ta    uuid := gen_random_uuid();
  tb    uuid := gen_random_uuid();
  mgr   uuid := gen_random_uuid();   -- tenant A insurance manager
  mem   uuid := gen_random_uuid();   -- tenant A insurance member (read)
  plain uuid := gen_random_uuid();   -- tenant A user with no module role
  mgr_b uuid := gen_random_uuid();   -- tenant B insurance manager
  v_doc  documents%rowtype;
  v_n    integer;
  v_hash text := encode(extensions.digest('policy-pdf-bytes', 'sha256'), 'hex');
  v_path text;
begin
  insert into tenants (id, name) values (ta, 'Docstore A'), (tb, 'Docstore B');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'docs-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{}', '{}', now(), now(), '', ''
    from (values (mgr), (mem), (plain), (mgr_b)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,   ta, 'Docstore manager',   'docs-' || mgr   || '@test.local'),
    (mem,   ta, 'Docstore member',    'docs-' || mem   || '@test.local'),
    (plain, ta, 'Docstore plain',     'docs-' || plain || '@test.local'),
    (mgr_b, tb, 'Docstore manager B', 'docs-' || mgr_b || '@test.local');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (ta, mgr, 'insurance', 'manager'), (ta, mem, 'insurance', 'member'),
    (tb, mgr_b, 'insurance', 'manager');

  perform pg_temp.jwt(mgr);
  set local role authenticated;

  -------------------------------------------------------------------
  -- 1. Happy path
  -------------------------------------------------------------------
  v_path := ta::text || '/insurance/policy/9b2d1f3e-0000-4000-8000-000000000001/debit-note.pdf';
  v_doc := documents_register('insurance_policy', '9b2d1f3e-0000-4000-8000-000000000001'::uuid,
                              'tenant-documents', v_path, 'debit-note.pdf', v_hash, 1234,
                              'application/pdf', 'client_debit_note', 'ins_debit_note', 1);
  perform pg_temp.assert(v_doc.tenant_id = ta, 'register pins the caller''s tenant');
  perform pg_temp.assert(v_doc.created_by = mgr, 'register records the caller');
  perform pg_temp.assert(v_doc.doc_kind = 'client_debit_note' and v_doc.template_version = 1,
                         'register keeps kind and template version');
  perform pg_temp.assert((select count(*) from documents where id = v_doc.id) = 1,
                         'the registered document is readable');

  -------------------------------------------------------------------
  -- 2. Input validation
  -------------------------------------------------------------------
  perform pg_temp.expect_error(format(
    'select documents_register(''insurance_policy'', %L::uuid, ''po-documents'', %s, ''x.pdf'', %s, 10)',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(v_path), quote_literal(v_hash)),
    'DOCUMENTS_BUCKET', 'register into another bucket');
  perform pg_temp.expect_error(format(
    'select documents_register(''insurance_policy'', %L::uuid, ''tenant-documents'', ''other-tenant/inline.pdf'', ''x.pdf'', %s, 10)',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(v_hash)),
    'DOCUMENTS_PATH', 'register outside the tenant folder');
  perform pg_temp.expect_error(format(
    'select documents_register(''insurance_policy'', %L::uuid, ''tenant-documents'', %s, ''x.pdf'', ''deadbeef'', 10)',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(ta::text || '/x.pdf')),
    'DOCUMENTS_HASH', 'register with a non-sha256 hash');
  perform pg_temp.expect_error(format(
    'select documents_register(''insurance_policy'', %L::uuid, ''tenant-documents'', %s, ''x.pdf'', %s, -1)',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(ta::text || '/x.pdf'), quote_literal(v_hash)),
    'DOCUMENTS_SIZE', 'register with a negative size');
  perform pg_temp.expect_error(format(
    'select documents_register(null, %L::uuid, ''tenant-documents'', %s, ''x.pdf'', %s, 10)',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(ta::text || '/x.pdf'), quote_literal(v_hash)),
    'DOCUMENTS_ENTITY', 'register without an entity type');
  perform pg_temp.expect_error(format(
    'select documents_register(''insurance_policy'', %L::uuid, ''tenant-documents'', %s, ''x.pdf'', %s, 10, ''application/pdf'', '''')',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(ta::text || '/x.pdf'), quote_literal(v_hash)),
    'DOCUMENTS_KIND', 'register with an empty doc kind');
  perform pg_temp.expect_state(format(
    'select documents_register(''insurance_policy'', %L::uuid, ''tenant-documents'', %s, ''again.pdf'', %s, 10)',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(v_path), quote_literal(v_hash)),
    '23505', 'register the same bucket+path twice');

  -------------------------------------------------------------------
  -- 3. Another tenant's folder is refused even for their own manager
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr_b);
  perform pg_temp.expect_error(format(
    'select documents_register(''insurance_policy'', %L::uuid, ''tenant-documents'', %s, ''x.pdf'', %s, 10)',
    '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(v_path), quote_literal(v_hash)),
    'DOCUMENTS_PATH', 'tenant B registering a tenant A path');

  -------------------------------------------------------------------
  -- 4. Writes are RPC-only; the registry is append-only
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  perform pg_temp.doc_via_off();
  perform pg_temp.expect_state(format(
    'insert into documents (tenant_id, entity_type, entity_id, doc_kind, bucket, path, file_name, mime_type, byte_size, content_hash) values (%L, ''insurance_policy'', %L::uuid, ''attachment'', ''tenant-documents'', %s, ''direct.pdf'', ''application/pdf'', 1, %s)',
    ta, '9b2d1f3e-0000-4000-8000-000000000001', quote_literal(ta::text || '/direct.pdf'), quote_literal(v_hash)),
    '42501', 'direct insert');
  -- No UPDATE/DELETE policy: the same manager who can read the row updates
  -- and deletes nothing (the guard is the second lock behind the RPC flag).
  update documents set file_name = 'renamed.pdf' where id = v_doc.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'no UPDATE policy: the update matches nothing');
  perform pg_temp.assert((select file_name from documents where id = v_doc.id) = 'debit-note.pdf',
                         'the update changed nothing');
  delete from documents where id = v_doc.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'no DELETE policy: the delete matches nothing');

  -------------------------------------------------------------------
  -- 5. Reads: same tenant + a consuming module
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  perform pg_temp.assert((select count(*) from documents where id = v_doc.id) = 1,
                         'insurance manager reads the store');
  perform pg_temp.jwt(mem);
  perform pg_temp.assert((select count(*) from documents where id = v_doc.id) = 1,
                         'insurance member reads the store');
  perform pg_temp.jwt(plain);
  perform pg_temp.assert((select count(*) from documents) = 0,
                         'a user with no consuming module role sees nothing');
  perform pg_temp.jwt(mgr_b);
  perform pg_temp.assert((select count(*) from documents) = 0,
                         'another tenant''s manager sees nothing');

  -------------------------------------------------------------------
  -- 6. Storage: one folder per tenant, enforced by the bucket policies
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  insert into storage.objects (bucket_id, name) values ('tenant-documents', ta::text || '/insurance/policy/x.pdf');
  perform pg_temp.assert((select count(*) from storage.objects where bucket_id = 'tenant-documents'
                          and name = ta::text || '/insurance/policy/x.pdf') = 1,
                         'own-folder upload lands');
  perform pg_temp.expect_state(format(
    'insert into storage.objects (bucket_id, name) values (''tenant-documents'', %s)',
    quote_literal(tb::text || '/escape.pdf')),
    '42501', 'upload into another tenant''s folder');

  raise notice 'ALL PASS: shared document store';
end $$;

rollback;
