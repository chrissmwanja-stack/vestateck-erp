drop policy if exists request_line_items_select on request_line_items;

create policy request_line_items_select on request_line_items
for select using (
  exists (
    select 1 from requests r
    where r.id = request_line_items.request_id
      and r.tenant_id = get_my_tenant_id()
  )
);
