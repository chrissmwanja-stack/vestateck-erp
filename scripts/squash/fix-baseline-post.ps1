# fix-baseline-post.ps1  --  rebuilds scripts/squash/baseline-post.sql in place.
#
# Keeps everything from `drop extension if exists "pg_net";` to EOF verbatim (pg_net drop,
# po_documents policies, REVOKE/GRANT block, default privileges, RC-7 view, RC-9 cron job) and
# replaces everything above it (patch header, duplicate PATCH A, verification SELECTs) with a clean
# head that adds the pieces that were missing: the two storage buckets and the tenant_documents
# policies on storage.objects (verbatim from 20261021100000_shared_document_store.sql).
#
# Deliberately NOT included: material_catalog_insert. 20260824064800_remote_schema.sql drops it and
# nothing recreates it, so the pre-Nov DB (and prod) do not have it. If you want that policy, ship
# it as a NEW dated migration after the baseline, not inside the baseline.
#
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File scripts\squash\fix-baseline-post.ps1
$ErrorActionPreference = 'Stop'
$path   = 'scripts\squash\baseline-post.sql'
$marker = 'drop extension if exists "pg_net";'
$utf8   = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $path)) { throw "$path not found. Run from the repo root." }
$lines = [System.IO.File]::ReadAllLines((Resolve-Path $path), $utf8)

if ($lines.Count -gt 0 -and $lines[0] -like '-- Post-squash block (v2)*') {
  Write-Host 'baseline-post.sql already fixed (v2 header present); nothing to do.' -ForegroundColor Yellow
  return
}

$idx = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -eq $marker })
if ($idx.Count -ne 1) { throw "Expected exactly one '$marker' line, found $($idx.Count). Aborting without changes." }
$tail = $lines[$idx[0]..($lines.Count - 1)]

# sanity: the kept region must be the verbatim block we expect
foreach ($need in @('po_documents_tenant_insert','po_documents_tenant_select','po_documents_tenant_update',
                    'REVOKE ALL ON ROUTINE','fin_unregistered_bank_accounts','cron.schedule')) {
  if (-not ($tail | Where-Object { $_ -like "*$need*" })) { throw "Kept region is missing '$need'. Aborting without changes." }
}

$head = @'
-- Post-squash block (v2): objects that `pg_dump --schema=public` cannot carry.
-- Appended verbatim to the dump by scripts/squash-2026-11.ps1 to form
-- 20261031235900_squashed_baseline.sql. Everything here must reproduce the pre-Nov
-- state exactly; anything that did not exist before November belongs in a dated
-- migration after the baseline, not here.

-- 1. Storage buckets ------------------------------------------------
-- po-documents: 20260902150000_recreate_po_documents_bucket.sql
-- tenant-documents: 20261021100000_shared_document_store.sql
insert into storage.buckets (id, name, public)
  values ('po-documents', 'po-documents', false)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public)
  values ('tenant-documents', 'tenant-documents', false)
  on conflict (id) do nothing;

-- 2. tenant-documents policies on storage.objects -------------------
-- Verbatim from 20261021100000_shared_document_store.sql. (The po_documents_*
-- policies are further down, verbatim from 20260910133254_remote_schema.sql.)
-- No delete policy, mirroring po-documents: removals are an operator job.
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

-- 3. pg_net, po-documents policies, routine privileges, RC-7 view, RC-9 cron job
--    (verbatim from the previous version of this file)

'@ -split "`r?`n"

Copy-Item $path "$path.bak" -Force
[System.IO.File]::WriteAllLines((Join-Path (Get-Location).Path $path), ($head + $tail), $utf8)
Write-Host ("rewrote {0}: {1} lines (was {2}); backup at {0}.bak" -f $path, ($head.Count + $tail.Count), $lines.Count) -ForegroundColor Cyan
Write-Host 'checks:' -ForegroundColor DarkGray
Select-String $path -Pattern 'tenant_documents_tenant_(insert|select|update)"','insert into storage.buckets','material_catalog_insert' |
  ForEach-Object { '  {0,5}: {1}' -f $_.LineNumber, $_.Line.Trim() }
