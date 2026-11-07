-- =====================================================================
-- Correspondence depth: claims letters and endorsement notes.
-- Append-only correspondence logs, RPC-only writes, RLS reads.
-- =====================================================================

create table if not exists public.ins_claim_correspondence (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  claim_id    uuid not null,
  direction   text not null check (direction in ('in','out')),
  channel     text not null default 'email' check (channel in ('email','letter','portal','phone')),
  subject     text not null,
  body        text,
  reference   text,
  occurred_at timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  constraint ins_claim_correspondence_tenant_id_id_key unique (tenant_id, id),
  constraint ins_claim_correspondence_claim_fk foreign key (tenant_id, claim_id)
    references public.ins_claims (tenant_id, id) on delete cascade
);

create table if not exists public.ins_endorsement_notes (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  endorsement_id uuid not null,
  note          text not null,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint ins_endorsement_notes_tenant_id_id_key unique (tenant_id, id),
  constraint ins_endorsement_notes_endorsement_fk foreign key (tenant_id, endorsement_id)
    references public.ins_policy_endorsements (tenant_id, id) on delete cascade
);

create index if not exists ins_claim_correspondence_claim_idx
  on public.ins_claim_correspondence (tenant_id, claim_id, occurred_at);
create index if not exists ins_endorsement_notes_endorsement_idx
  on public.ins_endorsement_notes (tenant_id, endorsement_id, created_at);

alter table public.ins_claim_correspondence enable row level security;
alter table public.ins_endorsement_notes enable row level security;

create policy "ins_claim_correspondence_select" on public.ins_claim_correspondence
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());
create policy "ins_endorsement_notes_select" on public.ins_endorsement_notes
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on public.ins_claim_correspondence, public.ins_endorsement_notes from public, anon;

create or replace function public.ins_log_claim_correspondence(
  p_claim_id uuid, p_direction text, p_subject text, p_body text default null,
  p_channel text default 'email', p_reference text default null
)
returns public.ins_claim_correspondence
language plpgsql security definer set search_path = 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row public.ins_claim_correspondence;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_direction not in ('in','out') then raise exception 'INS_CORR_BAD_DIRECTION'; end if;
  if btrim(p_subject) = '' then raise exception 'INS_CORR_SUBJECT_REQUIRED'; end if;
  if not exists (select 1 from public.ins_claims c where c.tenant_id = v_tenant and c.id = p_claim_id) then
    raise exception 'INS_CLAIM_NOT_FOUND';
  end if;
  insert into public.ins_claim_correspondence
    (tenant_id, claim_id, direction, channel, subject, body, reference, created_by)
  values (v_tenant, p_claim_id, p_direction, p_channel, p_subject, p_body, p_reference, auth.uid())
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.ins_log_endorsement_note(
  p_endorsement_id uuid, p_note text
)
returns public.ins_endorsement_notes
language plpgsql security definer set search_path = 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row public.ins_endorsement_notes;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if btrim(p_note) = '' then raise exception 'INS_NOTE_REQUIRED'; end if;
  if not exists (select 1 from public.ins_policy_endorsements e where e.tenant_id = v_tenant and e.id = p_endorsement_id) then
    raise exception 'INS_ENDORSEMENT_NOT_FOUND';
  end if;
  insert into public.ins_endorsement_notes (tenant_id, endorsement_id, note, created_by)
  values (v_tenant, p_endorsement_id, p_note, auth.uid())
  returning * into v_row;
  return v_row;
end $$;

revoke all on function public.ins_log_claim_correspondence(uuid, text, text, text, text, text) from public, anon;
revoke all on function public.ins_log_endorsement_note(uuid, text) from public, anon;
grant execute on function public.ins_log_claim_correspondence(uuid, text, text, text, text, text) to authenticated;
grant execute on function public.ins_log_endorsement_note(uuid, text) to authenticated;
