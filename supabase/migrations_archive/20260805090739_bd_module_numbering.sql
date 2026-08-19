
create or replace function public.next_proposal_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(proposal_number, '^PRP-', ''), proposal_number)::int), 0) + 1
  into v_next_num
  from bd_proposals
  where tenant_id = p_tenant_id and proposal_number like 'PRP-%';

  return 'PRP-' || lpad(v_next_num::text, 5, '0');
end;
$$;

create or replace function public.set_proposal_number()
returns trigger
language plpgsql
as $$
begin
  if NEW.proposal_number is null then
    NEW.proposal_number := next_proposal_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$$;

create trigger trg_set_proposal_number
  before insert on public.bd_proposals
  for each row execute function set_proposal_number();

create or replace function public.next_tender_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_next_num int;
begin
  select coalesce(max(nullif(regexp_replace(tender_number, '^TND-', ''), tender_number)::int), 0) + 1
  into v_next_num
  from bd_tenders
  where tenant_id = p_tenant_id and tender_number like 'TND-%';

  return 'TND-' || lpad(v_next_num::text, 5, '0');
end;
$$;

create or replace function public.set_tender_number()
returns trigger
language plpgsql
as $$
begin
  if NEW.tender_number is null then
    NEW.tender_number := next_tender_number(NEW.tenant_id);
  end if;
  return NEW;
end;
$$;

create trigger trg_set_tender_number
  before insert on public.bd_tenders
  for each row execute function set_tender_number();
