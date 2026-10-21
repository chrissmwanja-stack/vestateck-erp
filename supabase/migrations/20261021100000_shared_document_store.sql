-- Shared document store (Phase C item 3, slice 1 -- the seam).
--
-- A generic registry of documents that belong to a business entity: policy
-- wordings and the printed document pack, claim evidence, and (later)
-- finance attachments. The bytes live in object storage under a per-tenant
-- folder; this table is what makes them findable, auditable and hash-checked:
--   documents(entity_type, entity_id) -> bucket + path + sha256 + who/when,
-- with template_code/template_version recorded for generated documents so a
-- PDF can be reproduced years later (see the gap report 5.4/5.9).
--
-- Rules:
--   * Reads: same tenant, and the caller holds at least one module role that
--     consumes the store today (insurance, finance, procurement).
--   * Writes: RPC only (documents_register). The table has no insert/update/
--     delete policies and a guard trigger, exactly like the insurance tables.
--     There is no delete: the registry is append-only.
--   * Storage: the private 'tenant-documents' bucket, one folder per tenant
--     (same convention as 'po-documents'). The RPC refuses to register a path
--     outside the caller's tenant folder, so the storage RLS and this
--     registry always agree on who owns a file.
--
-- The store is deliberately NOT insurance-prefixed: insurance is only its
-- first consumer. Nothing here inspects entity_type, so new consumers are a
-- new entity_type string, not a migration.

-- =====================================================================
-- A. The registry
-- =====================================================================
create table if not exists public.documents (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  entity_type      text not null,
  entity_id        uuid not null,
  doc_kind         text not null default 'attachment',
  bucket           text not null,
  path             text not null,
  file_name        text not null,
  mime_type        text not null default 'application/pdf',
  byte_size        bigint not null check (byte_size >= 0),
  content_hash     text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  template_code    text,
  template_version integer,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  constraint documents_bucket_path_unique unique (bucket, path)
);

create index if not exists documents_entity_idx
  on public.documents (tenant_id, entity_type, entity_id);
create index if not exists documents_tenant_created_idx
  on public.documents (tenant_id, created_at desc);

alter table public.documents enable row level security;

-- Read: same tenant, and a module that consumes the store. (ORed permissive
-- policies would defeat the module gate, so this stays a single policy.)
drop policy if exists "documents_select" on public.documents;
create policy "documents_select" on public.documents
  for select to authenticated
  using (
    tenant_id = public.get_my_tenant_id()
    and (
      public.can_access_insurance()
      or public.is_finance_team_member(null::text)
      or public.has_po_access()
    )
  );
-- No INSERT/UPDATE/DELETE policies: writes go through documents_register(),
-- and the registry is append-only.

-- =====================================================================
-- B. The guard (same shape as the insurance guards)
-- =====================================================================
create or replace function public.documents_via_rpc()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('documents.via_rpc', true), '') = 'on';
$$;

create or replace function public.documents_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.documents_via_rpc() then
    raise exception 'DOCUMENTS_RPC_ONLY: register documents with documents_register()' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists documents_guard_trg on public.documents;
create trigger documents_guard_trg
  before insert or update or delete on public.documents
  for each row execute function public.documents_guard();

-- =====================================================================
-- C. Storage: the shared private bucket, one folder per tenant
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('tenant-documents', 'tenant-documents', false)
on conflict (id) do nothing;

drop policy if exists "tenant_documents_tenant_insert" on storage.objects;
create policy "tenant_documents_tenant_insert"
  on storage.objects for insert to authenticated
with check (
  bucket_id = 'tenant-documents'
  and (storage.foldername(name))[1] = (public.get_my_tenant_id())::text
);

drop policy if exists "tenant_documents_tenant_select" on storage.objects;
create policy "tenant_documents_tenant_select"
  on storage.objects for select to authenticated
using (
  bucket_id = 'tenant-documents'
  and (storage.foldername(name))[1] = (public.get_my_tenant_id())::text
);

drop policy if exists "tenant_documents_tenant_update" on storage.objects;
create policy "tenant_documents_tenant_update"
  on storage.objects for update to authenticated
using (
  bucket_id = 'tenant-documents'
  and (storage.foldername(name))[1] = (public.get_my_tenant_id())::text
)
with check (
  bucket_id = 'tenant-documents'
  and (storage.foldername(name))[1] = (public.get_my_tenant_id())::text
);
-- No delete policy, mirroring 'po-documents': removals are an operator job,
-- never an application path.

-- =====================================================================
-- D. documents_register -- the only way in
-- =====================================================================
create or replace function public.documents_register(
  p_entity_type      text,
  p_entity_id        uuid,
  p_bucket           text,
  p_path             text,
  p_file_name        text,
  p_content_hash     text,
  p_byte_size        bigint,
  p_mime_type        text default 'application/pdf',
  p_doc_kind         text default 'attachment',
  p_template_code    text default null,
  p_template_version integer default null
)
returns public.documents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.documents;
begin
  if v_tenant is null then
    raise exception 'DOCUMENTS_NO_TENANT: caller has no tenant' using errcode = '42501';
  end if;
  if p_entity_type is null or btrim(p_entity_type) = '' then
    raise exception 'DOCUMENTS_ENTITY: entity type is required' using errcode = 'P0001';
  end if;
  if p_entity_id is null then
    raise exception 'DOCUMENTS_ENTITY: entity id is required' using errcode = 'P0001';
  end if;
  if p_bucket is distinct from 'tenant-documents' then
    raise exception 'DOCUMENTS_BUCKET: documents live in the tenant-documents bucket' using errcode = 'P0001';
  end if;
  if p_path is null or (storage.foldername(p_path))[1] is distinct from v_tenant::text then
    raise exception 'DOCUMENTS_PATH: path must live in the caller''s tenant folder' using errcode = 'P0001';
  end if;
  if p_file_name is null or btrim(p_file_name) = '' then
    raise exception 'DOCUMENTS_NAME: file name is required' using errcode = 'P0001';
  end if;
  if p_content_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'DOCUMENTS_HASH: content hash must be lower-case sha-256 hex' using errcode = 'P0001';
  end if;
  if p_byte_size is null or p_byte_size < 0 then
    raise exception 'DOCUMENTS_SIZE: byte size must be zero or more' using errcode = 'P0001';
  end if;
  if p_doc_kind is null or btrim(p_doc_kind) = '' then
    raise exception 'DOCUMENTS_KIND: doc kind is required' using errcode = 'P0001';
  end if;

  perform set_config('documents.via_rpc', 'on', true);
  insert into public.documents (
    tenant_id, entity_type, entity_id, doc_kind, bucket, path, file_name,
    mime_type, byte_size, content_hash, template_code, template_version, created_by
  ) values (
    v_tenant, p_entity_type, p_entity_id, p_doc_kind, p_bucket, p_path,
    btrim(p_file_name), coalesce(p_mime_type, 'application/pdf'), p_byte_size,
    p_content_hash, p_template_code, p_template_version, auth.uid()
  )
  returning * into v_row;
  perform set_config('documents.via_rpc', 'off', true);
  return v_row;
end;
$$;

-- =====================================================================
-- E. Grants
-- =====================================================================
revoke all on public.documents from public, anon;
grant select on public.documents to authenticated;

revoke all on function public.documents_via_rpc() from public, anon;
grant execute on function public.documents_via_rpc() to authenticated;
revoke all on function public.documents_guard() from public, anon, authenticated;
revoke all on function public.documents_register(text, uuid, text, text, text, text, bigint, text, text, text, integer) from public, anon;
grant execute on function public.documents_register(text, uuid, text, text, text, text, bigint, text, text, text, integer) to authenticated;

-- The tenant tables drift test requires the read-only guard on every new table.
select public.apply_tenant_read_only_guard();
