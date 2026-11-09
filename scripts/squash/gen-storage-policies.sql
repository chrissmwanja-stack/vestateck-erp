select 'drop policy if exists ' || quote_ident(policyname) || ' on storage.objects;' || E'\n' ||
       'create policy ' || quote_ident(policyname) || ' on storage.objects as permissive for ' || lower(cmd) ||
       ' to ' || array_to_string(roles, ', ') ||
       coalesce(' using (' || qual || ')', '') ||
       coalesce(' with check (' || with_check || ')', '') || ';'
from pg_policies
where schemaname='storage' and tablename='objects' and policyname like 'po_documents_tenant%'
order by policyname;