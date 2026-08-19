
-- Knowledge Base articles and FAQ entries. Any tenant user can read
-- published items; only IT support can author/edit, mirroring the
-- is_it_support() gate used for tickets/assets.

create table public.kb_articles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  title text not null,
  category text,
  content text not null,
  is_published boolean not null default true,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.kb_articles enable row level security;

create policy kb_articles_select on public.kb_articles
  for select
  using (
    tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
  );

create table public.faqs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  question text not null,
  answer text not null,
  category text,
  sort_order integer not null default 0,
  is_published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.faqs enable row level security;

create policy faqs_select on public.faqs
  for select
  using (
    tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
  );

create or replace function public.get_kb_articles(p_category text default null)
returns setof public.kb_articles
language sql
security definer
set search_path = public
as $$
  select * from kb_articles
  where tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
    and (p_category is null or category = p_category)
  order by updated_at desc;
$$;

create or replace function public.create_kb_article(
  p_title text,
  p_content text,
  p_category text default null,
  p_is_published boolean default true
) returns public.kb_articles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_article public.kb_articles%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create knowledge base articles';
  end if;
  insert into kb_articles (tenant_id, title, content, category, is_published, created_by)
  values (get_my_tenant_id(), p_title, p_content, p_category, p_is_published, auth.uid())
  returning * into v_article;
  return v_article;
end;
$$;

create or replace function public.update_kb_article(
  p_article_id uuid,
  p_title text default null,
  p_content text default null,
  p_category text default null,
  p_is_published boolean default null
) returns public.kb_articles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_article public.kb_articles%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update knowledge base articles';
  end if;
  select * into v_article from kb_articles where id = p_article_id for update;
  if not found or v_article.tenant_id != get_my_tenant_id() then
    raise exception 'article not found';
  end if;

  update kb_articles
  set title = coalesce(p_title, title),
      content = coalesce(p_content, content),
      category = coalesce(p_category, category),
      is_published = coalesce(p_is_published, is_published),
      updated_at = now()
  where id = p_article_id
  returning * into v_article;

  return v_article;
end;
$$;

create or replace function public.get_faqs(p_category text default null)
returns setof public.faqs
language sql
security definer
set search_path = public
as $$
  select * from faqs
  where tenant_id = get_my_tenant_id()
    and (is_published or is_it_support())
    and (p_category is null or category = p_category)
  order by sort_order, created_at;
$$;

create or replace function public.create_faq(
  p_question text,
  p_answer text,
  p_category text default null,
  p_sort_order integer default 0,
  p_is_published boolean default true
) returns public.faqs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_faq public.faqs%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to create FAQ entries';
  end if;
  insert into faqs (tenant_id, question, answer, category, sort_order, is_published)
  values (get_my_tenant_id(), p_question, p_answer, p_category, p_sort_order, p_is_published)
  returning * into v_faq;
  return v_faq;
end;
$$;

create or replace function public.update_faq(
  p_faq_id uuid,
  p_question text default null,
  p_answer text default null,
  p_category text default null,
  p_sort_order integer default null,
  p_is_published boolean default null
) returns public.faqs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_faq public.faqs%rowtype;
begin
  if not is_it_support() then
    raise exception 'not authorized to update FAQ entries';
  end if;
  select * into v_faq from faqs where id = p_faq_id for update;
  if not found or v_faq.tenant_id != get_my_tenant_id() then
    raise exception 'FAQ not found';
  end if;

  update faqs
  set question = coalesce(p_question, question),
      answer = coalesce(p_answer, answer),
      category = coalesce(p_category, category),
      sort_order = coalesce(p_sort_order, sort_order),
      is_published = coalesce(p_is_published, is_published),
      updated_at = now()
  where id = p_faq_id
  returning * into v_faq;

  return v_faq;
end;
$$;
