-- =====================================================================
-- Insurance brokerage, slice C1: claims depth — excess handling and a
-- per-claim document checklist.
--
-- Excess (roadmap gap #9 / accountant answer 21): never brokerage income.
-- Four handling modes, stored on the claim. Documents: one row per
-- (claim, doc_type) with missing -> provided -> verified.
-- Writes go through RPCs only; reads RLS-scoped to insurance access.
-- =====================================================================

-- Excess on the claim (additive columns; no drops).
alter table public.ins_claims
  add column if not exists excess_amount numeric(18,2) not null default 0
    check (excess_amount >= 0),
  add column if not exists excess_handling text not null default 'insurer_deducts'
    check (excess_handling in ('insurer_deducts', 'collected_from_client', 'paid_to_provider', 'insurer_pays_full'));

-- =====================================================================
-- Document checklist
-- =====================================================================
create table if not exists public.ins_claim_documents (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  claim_id   uuid not null,
  doc_type   text not null,
  status     text not null default 'missing'
             check (status in ('missing', 'provided', 'verified')),
  note       text,
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ins_claim_documents_tenant_id_id_key unique (tenant_id, id),
  constraint ins_claim_documents_claim_fk foreign key (tenant_id, claim_id)
    references public.ins_claims (tenant_id, id) on delete cascade,
  constraint ins_claim_documents_one_per_type unique (tenant_id, claim_id, doc_type)
);

create index if not exists ins_claim_documents_claim_idx
  on public.ins_claim_documents (tenant_id, claim_id);

alter table public.ins_claim_documents enable row level security;

create policy "ins_claim_documents_select" on public.ins_claim_documents
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on public.ins_claim_documents from public, anon;

-- =====================================================================
-- RPCs
-- =====================================================================

-- Upsert a checklist row (missing/provided). Idempotent per (claim, doc_type).
create or replace function public.ins_set_claim_document(
  p_claim_id uuid,
  p_doc_type text,
  p_status text,
  p_note text default null
)
returns public.ins_claim_documents
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_doc public.ins_claim_documents;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_status not in ('missing', 'provided') then
    raise exception 'INS_CLAIM_DOC_BAD_STATUS';  -- 'verified' is manager-only, below
  end if;
  if btrim(p_doc_type) = '' then
    raise exception 'INS_CLAIM_DOC_TYPE_REQUIRED';
  end if;
  if not exists (
    select 1 from public.ins_claims c
    where c.tenant_id = v_tenant and c.id = p_claim_id
  ) then
    raise exception 'INS_CLAIM_NOT_FOUND';
  end if;

  set local ins.via_rpc = 'on';
  insert into public.ins_claim_documents (tenant_id, claim_id, doc_type, status, note, updated_by)
  values (v_tenant, p_claim_id, p_doc_type, p_status, p_note, auth.uid())
  on conflict (tenant_id, claim_id, doc_type) do update
    set status = excluded.status, note = excluded.note, updated_by = auth.uid(), updated_at = now()
  returning * into v_doc;
  reset ins.via_rpc;

  return v_doc;
end;
$$;

revoke all on function public.ins_set_claim_document(uuid, text, text, text) from public, anon;
grant execute on function public.ins_set_claim_document(uuid, text, text, text) to authenticated;

-- Manager-only verification.
create or replace function public.ins_verify_claim_document(
  p_claim_id uuid,
  p_doc_type text
)
returns public.ins_claim_documents
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_doc public.ins_claim_documents;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_doc from public.ins_claim_documents
  where tenant_id = v_tenant and claim_id = p_claim_id and doc_type = p_doc_type;
  if v_doc.id is null then raise exception 'INS_CLAIM_DOC_NOT_FOUND'; end if;
  if v_doc.status <> 'provided' then
    raise exception 'INS_CLAIM_DOC_NOT_PROVIDED';
  end if;

  set local ins.via_rpc = 'on';
  update public.ins_claim_documents
  set status = 'verified', updated_by = auth.uid(), updated_at = now()
  where tenant_id = v_tenant and id = v_doc.id
  returning * into v_doc;
  reset ins.via_rpc;

  return v_doc;
end;
$$;

revoke all on function public.ins_verify_claim_document(uuid, text) from public, anon;
grant execute on function public.ins_verify_claim_document(uuid, text) to authenticated;
