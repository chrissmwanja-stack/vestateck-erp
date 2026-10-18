-- Product lines say whether their policies need a certificate before binding.
--
-- Until now the certificate gate keyed on the exact product line code 'MOTOR'. Product
-- lines are not seeded: each company's admin chooses the codes, and the form suggested
-- 'MOT'. A company whose motor line was 'MOT' or 'MOTORS' therefore bound motor policies
-- with no certificate, with no error, and the risk register treated the line as ordinary.
--
-- What this does:
--   * ins_product_lines.requires_certificate: an admin or manager switches it on for any
--     line whose policies need an issued certificate (motor, and any other certificate
--     business such as a different code for the same thing).
--   * platform_ins_line_needs_certificate(tenant, line): the single rule. A line needs a
--     certificate when the flag is on OR its code is 'MOTOR'. The code stays on for
--     back-compatibility, so seeds, tests and companies that already use MOTOR behave
--     exactly as before and nothing silently loses its gate. The flag only adds lines.
--   * The flag is backfilled on for existing MOTOR lines so the screen shows the truth.
--   * ins_bind_policy and ins_register_risk use the rule instead of comparing the code.
--     Both bodies are otherwise unchanged from 20261017100000.
--
-- Not changed: the gate itself, certificate stock, risk linking, or any posting.

alter table public.ins_product_lines
  add column if not exists requires_certificate boolean not null default false;

update public.ins_product_lines
   set requires_certificate = true
 where code = 'MOTOR' and requires_certificate is false;

comment on column public.ins_product_lines.requires_certificate is
  'When true, a policy on this line cannot be bound until an issued certificate is attached to it, and its risks must be vehicles with a chassis number. A line coded MOTOR always needs a certificate.';

create or replace function public.platform_ins_line_needs_certificate(p_tenant_id uuid, p_line_id uuid)
returns boolean
language sql stable security definer set search_path = pg_catalog, public, pg_temp as $$
  select coalesce((select l.requires_certificate or l.code = 'MOTOR'
                     from ins_product_lines l
                    where l.id = p_line_id and l.tenant_id = p_tenant_id), false);
$$;
revoke all on function public.platform_ins_line_needs_certificate(uuid, uuid) from public, anon, authenticated;

-- ins_register_risk: a certificate line needs a vehicle risk with a chassis number.
create or replace function public.ins_register_risk(
  p_client_id uuid,
  p_product_line_id uuid,
  p_risk_type text,
  p_description text,
  p_reg_no text default null,
  p_chassis_no text default null,
  p_engine_no text default null,
  p_make text default null,
  p_model text default null,
  p_year_made integer default null,
  p_sum_insured numeric default 0
) returns uuid
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); needs_cert boolean; new_id uuid;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  if not exists (select 1 from ins_clients where id = p_client_id and tenant_id = t) then raise exception 'INS_NOT_FOUND: client'; end if;
  perform 1 from ins_product_lines where id = p_product_line_id and tenant_id = t and is_active;
  if not found then raise exception 'INS_NOT_FOUND: active product line'; end if;
  needs_cert := public.platform_ins_line_needs_certificate(t, p_product_line_id);
  if needs_cert and p_risk_type <> 'vehicle' then
    raise exception 'INS_RISK_TYPE: a motor product line needs a vehicle risk';
  end if;
  if needs_cert and nullif(btrim(coalesce(p_chassis_no, '')), '') is null then
    raise exception 'INS_RISK_INPUT: a vehicle needs a chassis number';
  end if;
  begin
    insert into ins_risks (tenant_id, client_id, product_line_id, risk_type, description, reg_no, chassis_no, engine_no,
      make, model, year_made, sum_insured)
    values (t, p_client_id, p_product_line_id, p_risk_type, btrim(p_description),
      nullif(btrim(coalesce(p_reg_no, '')), ''), nullif(btrim(coalesce(p_chassis_no, '')), ''),
      nullif(btrim(coalesce(p_engine_no, '')), ''), nullif(btrim(coalesce(p_make, '')), ''),
      nullif(btrim(coalesce(p_model, '')), ''), p_year_made, coalesce(p_sum_insured, 0))
    returning id into new_id;
  exception when unique_violation then
    raise exception 'INS_DUPLICATE: a risk with this chassis number already exists';
  end;
  return new_id;
end $$;

-- ins_bind_policy: runs the existing bind first, then requires and consumes a certificate
-- on a certificate line. Any failure rolls back the whole bind, journal included.
create or replace function public.ins_bind_policy(p_policy_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare p ins_policies%rowtype; is_motor boolean;
begin
  p := platform_ins_bind_policy_risk_legacy_impl(p_policy_id);
  is_motor := public.platform_ins_line_needs_certificate(p.tenant_id, p.product_line_id);
  if is_motor then
    if not exists (select 1 from ins_certificate_stock c where c.tenant_id = p.tenant_id and c.policy_id = p.id and c.status = 'issued') then
      raise exception 'INS_MOTOR_CERTIFICATE_REQUIRED: attach an issued motor certificate to this policy before binding';
    end if;
    update ins_certificate_stock set status = 'used' where tenant_id = p.tenant_id and policy_id = p.id and status = 'issued';
  end if;
  return p;
end $$;
