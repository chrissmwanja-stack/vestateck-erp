drop policy if exists po_documents_tenant_insert on storage.objects;
create policy po_documents_tenant_insert on storage.objects as permissive for insert to authenticated with check (((bucket_id = 'po-documents'::text) AND ((storage.foldername(name))[1] = (get_my_tenant_id())::text)));
drop policy if exists po_documents_tenant_select on storage.objects;
create policy po_documents_tenant_select on storage.objects as permissive for select to authenticated using (((bucket_id = 'po-documents'::text) AND ((storage.foldername(name))[1] = (get_my_tenant_id())::text)));
drop policy if exists po_documents_tenant_update on storage.objects;
create policy po_documents_tenant_update on storage.objects as permissive for update to authenticated using (((bucket_id = 'po-documents'::text) AND ((storage.foldername(name))[1] = (get_my_tenant_id())::text)));
