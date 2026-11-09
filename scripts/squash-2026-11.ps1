# =====================================================================
# Checkpoint squash to a 2026-11-01 baseline (v13: raw-text dump cleanup, no line-ending rewrite; generated default privileges).
#
# Run from C:\dev\vestateck-erp (repo root). Requires a RUNNING local
# Supabase stack with the CURRENT (old-layout) migrations fully applied:
#   npx supabase@2.114.0 start
#   npx supabase@2.114.0 db reset --yes
#
# Steps:
#   1. safety tag
#   2. move all pre-Nov *.sql migrations into supabase/migrations_archive/2026-11/
#   3. verify the local DB is in the OLD state, then fingerprint its catalog (A)
#   3b. reset the DB with ONLY the pre-Nov migrations (dump source), then restore the layout
#   4. pg_dump public (schema-only; extensions emitted from catalog) inside the DB container,
#      piping through sed to strip pg_dump 16+ psql meta-commands
#      (\restrict, \set, \connect, \!) that the Supabase migration
#      runner (simple query protocol) refuses
#   5. append scripts/squash/baseline-post.sql
#   6. `supabase db reset` (baseline + Nov tail), fingerprint again (B), A must equal B
#   7. print prod migration repair commands
#
# Re-runnable: if it fails before step 6 nothing has touched the DB, so
# just fix the cause and run it again. If it fails AFTER the reset, the DB
# is in the new state; restore the old tree + `db reset` before re-running
# (step 3 refuses to continue otherwise).
# =====================================================================
$ErrorActionPreference = 'Continue'
$env:NPM_CONFIG_UPDATE_NOTIFIER = 'false'
$env:NPM_CONFIG_LOGLEVEL = 'error'   # hides the harmless 'npm notice run ...' stderr line

# Native-command encoding: keep UTF-8 in and out of docker/psql.
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$tag      = 'pre-squash-2026-11'
$cutoff   = '20261101000000'
$baseline = '20261031235900_squashed_baseline.sql'
$archive  = 'supabase/migrations_archive/2026-11'
$migDir   = 'supabase/migrations'
$postPath = Join-Path $PSScriptRoot 'squash/baseline-post.sql'

function Get-DbCid {
  $c = (& docker ps --filter "name=supabase_db" --format "{{.ID}}" 2>$null | Select-Object -First 1)
  if (-not $c) { $c = (& docker ps --filter "name=db" --format "{{.ID}}" 2>$null | Select-Object -First 1) }
  return $c
}

# Runs SQL (from the pipeline string) in the db container; returns stdout lines.
# Native stderr (NOTICEs) is ignored unless psql exits non-zero.
function Invoke-Psql([string]$sql, [string]$db = 'postgres') {
  $raw  = $sql | & docker exec -i $cid psql -U postgres -d $db -X -q -A -t -v ON_ERROR_STOP=1 2>&1
  $code = $LASTEXITCODE
  $errs = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
  if ($code -ne 0) { throw ("psql failed:`n" + ($errs -join "`n")) }
  return @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
           ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
}

# Order-independent, oid-free catalog fingerprint. One line per object;
# long/multiline definitions are md5'd so a diff names the object that changed.
$fpSql = @'
select line from (
  select 'ext|' || extname as line from pg_extension
  union all
  select 'col|' || table_schema || '.' || table_name || '.' || column_name || '|' || data_type || '|' || udt_name || '|' || is_nullable || '|' || md5(coalesce(column_default, ''))
    from information_schema.columns where table_schema = 'public'
  union all
  select 'con|' || c.conrelid::regclass::text || '|' || c.conname || '|' || md5(pg_get_constraintdef(c.oid))
    from pg_constraint c join pg_namespace n on n.oid = c.connamespace where n.nspname = 'public'
  union all
  select 'idx|' || schemaname || '.' || tablename || '.' || indexname || '|' || md5(indexdef)
    from pg_indexes where schemaname = 'public'
  union all
  select 'rls|' || c.relname || '|' || c.relrowsecurity::text || '|' || c.relforcerowsecurity::text
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
  union all
  select 'pol|' || schemaname || '.' || tablename || '.' || policyname || '|' || cmd || '|' || permissive || '|' || roles::text || '|' || md5(coalesce(qual, '') || '~' || coalesce(with_check, ''))
    from pg_policies where schemaname in ('public', 'storage')
  union all
  select 'trg|' || c.relname || '|' || t.tgname || '|' || md5(pg_get_triggerdef(t.oid))
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where not t.tgisinternal and n.nspname = 'public'
  union all
  select 'fn|' || p.oid::regprocedure::text || '|' || md5(pg_get_functiondef(p.oid)) || '|' ||
         coalesce((select string_agg(coalesce(r.rolname, 'public') || ':' || a.privilege_type, ',' order by coalesce(r.rolname, 'public'), a.privilege_type)
                   from aclexplode(p.proacl) a left join pg_roles r on r.oid = a.grantee), '')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind in ('f', 'p')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  union all
  select 'acl|' || c.relkind::text || '|' || c.relname || '|' ||
         coalesce((select string_agg(coalesce(r.rolname, 'public') || ':' || a.privilege_type || ':' || a.is_grantable::text, ',' order by coalesce(r.rolname, 'public'), a.privilege_type)
                   from aclexplode(c.relacl) a left join pg_roles r on r.oid = a.grantee), '')
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S')
  union all
  select 'view|' || c.relname || '|' || coalesce(c.reloptions::text, '') || '|' || md5(pg_get_viewdef(c.oid))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('v', 'm')
  union all
  select 'enum|' || t.typname || '|' || string_agg(e.enumlabel, ',' order by e.enumsortorder)
    from pg_type t join pg_enum e on e.enumtypid = t.oid join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' group by t.typname
  union all
  select 'bucket|' || id || '|' || name || '|' || public::text || '|' || coalesce(file_size_limit::text, '') || '|' || coalesce(allowed_mime_types::text, '')
    from storage.buckets
  union all
  select 'defacl|' || r.rolname || '|' || coalesce(n.nspname, '') || '|' || d.defaclobjtype::text || '|' ||
         coalesce((select string_agg(coalesce(gr.rolname, 'public') || ':' || a.privilege_type || ':' || a.is_grantable::text, ',' order by coalesce(gr.rolname, 'public'), a.privilege_type)
                   from aclexplode(d.defaclacl) a left join pg_roles gr on gr.oid = a.grantee), '')
    from pg_default_acl d join pg_roles r on r.oid = d.defaclrole left join pg_namespace n on n.oid = d.defaclnamespace
    where r.rolname = 'postgres'
  union all
  select 'cron|' || coalesce(jobname, '') || '|' || schedule || '|' || md5(command)
    from cron.job
) q
where line is not null
order by line collate "C";
'@

# Informational per-table row counts (public). Reported, not enforced: audit/log tables can
# legitimately differ.
$cntSql = @'
select line from (
  select 'cnt|' || c.relname || '|' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', n.nspname, c.relname), false, true, '')))[1]::text as line
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
) t
order by line collate "C";
'@

# --- 0. sanity -------------------------------------------------------
if (-not (Test-Path $migDir))   { throw "Run from the repo root (no $migDir)." }
if (-not (Test-Path $postPath)) { throw "post-squash block not found: $postPath" }
$cid = Get-DbCid
if (-not $cid) { throw 'Supabase local stack is not up (docker cannot find a supabase_db container). Run `npx supabase@2.114.0 start` first.' }

# --- 1. safety tag ---------------------------------------------------
& git tag -a $tag -m "Pre-squash checkpoint 2026-11-01" 2>$null | Out-Null
Write-Host "tag $tag (created now, or already present from an earlier run)" -ForegroundColor Cyan

# --- 2. archive pre-Nov files ---------------------------------------
New-Item -ItemType Directory -Force -Path $archive | Out-Null
# A stray copy of the generated baseline (from an earlier run) must never be archived;
# it is regenerated below. Exact-name match only: the old Aug-19 baseline IS archived.
$strayBaseline = Join-Path $archive $baseline
if (Test-Path $strayBaseline) { Remove-Item $strayBaseline; Write-Host "removed stray $baseline from archive" -ForegroundColor DarkYellow }
$moveNow = @(Get-ChildItem $migDir -File -Filter *.sql | Where-Object {
  $ts = ($_.Name -split '_')[0]
  $_.Name -ne $baseline -and $ts -match '^\d{14}$' -and $ts -lt $cutoff
} | Sort-Object Name)
if ($moveNow.Count -gt 0) {
  # -Force: a stale archive from an earlier failed run may already hold copies of these files;
  # the files in migrations/ are the source of truth, so overwrite them.
  $moveNow | Move-Item -Destination $archive -Force
  Write-Host ("moved {0} pre-Nov migrations -> {1}" -f $moveNow.Count, $archive) -ForegroundColor Cyan
}
# Full archived set = everything pre-cutoff in the archive dir (this run + earlier runs).
$toArchive = @(Get-ChildItem $archive -File -Filter *.sql | Where-Object {
  ($_.Name -split '_')[0] -match '^\d{14}$' -and ($_.Name -split '_')[0] -lt $cutoff
} | Sort-Object Name)
Write-Host ("{0} pre-Nov migrations archived in {1}" -f $toArchive.Count, $archive) -ForegroundColor Cyan
$tail = @(Get-ChildItem $migDir -File -Filter *.sql | Where-Object { $_.Name -ne $baseline })
$expectedOld = $toArchive.Count + $tail.Count

# --- 3. DB must be in the OLD state; fingerprint it (A) --------------
$r = @(Invoke-Psql 'select count(*) from supabase_migrations.schema_migrations;')
$applied = [int]$r[0]
if ($applied -ne $expectedOld) {
  throw ("Local DB has $applied applied migrations but the old layout has $expectedOld " +
         "($($toArchive.Count) archived + $($tail.Count) tail). Restore the old tree and run " +
         "'npx supabase@2.114.0 db reset --yes' first, otherwise the dump and the A/B comparison are meaningless.")
}
Write-Host "DB is in the old state ($applied migrations applied). Fingerprinting (A) ..." -ForegroundColor DarkGray
$fpA = @(Invoke-Psql $fpSql)
Write-Host ("  A: {0} catalog lines" -f $fpA.Count) -ForegroundColor DarkGray
if ($fpA.Count -lt 50) { throw "Fingerprint A suspiciously small ($($fpA.Count) lines); aborting." }
$cntA = @(Invoke-Psql $cntSql)

# --- 3b. build the PRE-NOV state, which is what the baseline must capture ---
# The baseline must equal the DB as of the cutoff (only pre-Nov migrations applied).
# Dumping the full old DB would bake the Nov tail's objects into the baseline, and the
# tail would then collide with them on replay (e.g. "policy ins_quotes_select already exists").
# So: temporarily park the tail, copy the archived files back, reset, dump from THAT db.
$tailTmp   = 'supabase/.squash_tail_tmp'
$tailNames = @($tail | ForEach-Object { $_.Name })
$archNames = @($toArchive | ForEach-Object { $_.Name })
$strayInMig = Join-Path $migDir $baseline
if (Test-Path $strayInMig) { Remove-Item $strayInMig }
New-Item -ItemType Directory -Force -Path $tailTmp | Out-Null
try {
  foreach ($n in $tailNames) { Move-Item (Join-Path $migDir $n) $tailTmp -Force }
  foreach ($n in $archNames) { Copy-Item (Join-Path $archive $n) $migDir -Force }
  Write-Host "--- supabase db reset (pre-Nov migrations only; this is the dump source) ---" -ForegroundColor DarkGray
  # --no-seed: seed.sql targets the FULL schema (it calls tail-only functions such as
  # ins_submit_policy_for_approval) and the dump only needs the schema anyway.
  & npx supabase@2.114.0 db reset --yes --no-seed 2>&1 | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'supabase db reset failed on the pre-Nov-only layout; see output above.' }
  $cid = Get-DbCid
  if (-not $cid) { throw 'db container not found after pre-Nov reset.' }
  $r = @(Invoke-Psql 'select count(*) from supabase_migrations.schema_migrations;')
  if ([int]$r[0] -ne $archNames.Count) { throw ("Pre-Nov DB has {0} applied migrations; expected {1}." -f $r[0], $archNames.Count) }
  Write-Host ("Pre-Nov DB ready ({0} migrations applied)." -f $r[0]) -ForegroundColor DarkGray
} finally {
  foreach ($n in $archNames) { Remove-Item (Join-Path $migDir $n) -ErrorAction SilentlyContinue }
  foreach ($n in $tailNames) { $src = Join-Path $tailTmp $n; if (Test-Path $src) { Move-Item $src $migDir -Force } }
  Remove-Item $tailTmp -Force -ErrorAction SilentlyContinue
}

# --- 4. schema dump (inside the db container) ------------------------
# Pipe pg_dump through sed inside the container to strip lines starting
# with "\" (\restrict, \set, \connect, \!) -- pg_dump 16+ emits these and
# the Supabase migration runner (simple query protocol) refuses them with
# "syntax error at or near \" . Writing raw pg_dump output and then
# stripping in PowerShell is unreliable because the dump is large and
# encodings differ; sed inside the container is the same codepath pg_dump
# uses.
$dumpPath = Join-Path $migDir $baseline
if (Test-Path $dumpPath) { Remove-Item $dumpPath }
$dumpTmp = '/tmp/baseline.sql'
"dumping via pg_dump inside container $cid ..." | Write-Host -ForegroundColor DarkGray
& docker exec -i $cid pg_dump -U postgres -d postgres `
  --schema=public `
  --no-owner --no-privileges --schema-only --no-comments `
  --no-publications --no-subscriptions `
  -F p -f $dumpTmp 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'pg_dump inside container failed; see output above.' }
& docker cp "${cid}:$dumpTmp" $dumpPath 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dumpPath)) {
  throw "docker cp of pg_dump output failed; $dumpPath not produced."
}
& docker exec -i $cid rm -f $dumpTmp 2>$null | Out-Null
# Clean up the dump so it plays nicely with supabase's migration runner
# (which already creates extensions/public schemas and loads extensions
# during the global-init step):
#   1. Drop lines starting with "\" (pg_dump 16+ emits \restrict/\set/
#      \connect/\! which the simple-query protocol refuses).
#   2. "CREATE SCHEMA extensions" -> "CREATE SCHEMA IF NOT EXISTS extensions"
#      (and same for public), since supabase creates them before migrations.
#   3. "CREATE EXTENSION ..." without IF NOT EXISTS -> add IF NOT EXISTS,
#      same reason.
# NOTE (v4): we no longer dump the `extensions` schema. Besides the extensions
# themselves it holds helper functions/triggers created by the Supabase image
# (grant_pg_cron_access, grant_pg_net_access, set_graphql_placeholder, pgrst_*)
# that already exist on `db reset` and made the baseline fail with SQLSTATE 42723.
# Instead, emit idempotent CREATE EXTENSION lines from the live catalog.
$extSql = @'
select 'CREATE EXTENSION IF NOT EXISTS ' || quote_ident(e.extname) || ' WITH SCHEMA ' || quote_ident(n.nspname) || ';'
from pg_extension e join pg_namespace n on n.oid = e.extnamespace
where n.nspname in ('extensions', 'public', 'pg_catalog') and e.extname <> 'plpgsql'
order by e.extname;
'@
$extLines = @(Invoke-Psql $extSql)
Write-Host ("  extensions to create in baseline: {0}" -f $extLines.Count) -ForegroundColor DarkGray
# IMPORTANT: clean up the RAW text. Never ReadAllLines/WriteAllLines here: that rewrites every line
# ending to the platform default (CRLF on Windows), and line endings inside $function$ bodies are part
# of the function source (pg_proc.prosrc) -- which made ~500 function bodies differ from the old layout.
$dumpFileFull = (Resolve-Path $dumpPath).Path
$raw = [System.IO.File]::ReadAllText($dumpFileFull, $utf8)
$raw = [regex]::Replace($raw, '(?m)^\\[^\r\n]*(?:\r?\n|\z)', '')
$raw = [regex]::Replace($raw, '(?m)^CREATE SCHEMA extensions\b[^\r\n]*', 'CREATE SCHEMA IF NOT EXISTS extensions;')
$raw = [regex]::Replace($raw, '(?m)^CREATE SCHEMA public\b[^\r\n]*', 'CREATE SCHEMA IF NOT EXISTS public;')
$raw = [regex]::Replace($raw, '(?m)^CREATE EXTENSION (?!IF NOT EXISTS\b)', 'CREATE EXTENSION IF NOT EXISTS ')
$hdr = "-- extensions (generated from catalog)`n" + ($extLines -join "`n") + "`n`n"
[System.IO.File]::WriteAllText($dumpFileFull, $hdr + $raw, $utf8)
Write-Host ("dumped baseline -> " + $dumpPath) -ForegroundColor Cyan

# --- 4b. reference DATA inserted by the pre-Nov migrations -----------
# pg_dump --schema-only loses every row a migration inserted (platform_modules registry,
# templates, regulatory parameters, ...). The dump-source DB was reset with --no-seed, so all
# rows currently in public came from migrations. --inserts (not COPY): the migration runner
# uses the simple query protocol. session_replication_role=replica keeps audit/guard triggers
# from firing while the rows are loaded (same approach the supabase CLI uses for data dumps).
$dataTmp = '/tmp/baseline-data.sql'
& docker exec -i $cid pg_dump -U postgres -d postgres `
  --schema=public --data-only --inserts --rows-per-insert=100 `
  --no-owner --no-privileges -f $dataTmp 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'pg_dump (data) inside container failed; see output above.' }
$dataPath = Join-Path $migDir 'baseline-data.tmp'
& docker cp "${cid}:$dataTmp" $dataPath 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dataPath)) { throw 'docker cp of data dump failed.' }
& docker exec -i $cid rm -f $dataTmp 2>$null | Out-Null
$dataText = [System.IO.File]::ReadAllText((Resolve-Path $dataPath).Path, $utf8)
$dataText = [regex]::Replace($dataText, '(?m)^\\[^\r\n]*(?:\r?\n|\z)', '')   # raw text: embedded line endings stay intact
Remove-Item $dataPath
$dataLines = @([regex]::Matches($dataText, "`n"))
$dataBlock = "`n`n-- reference data inserted by the pre-Nov migrations (generated)`n" +
             "SET session_replication_role = replica;`n" +
             $dataText.TrimEnd() +
             "`nRESET session_replication_role;`n"
[System.IO.File]::AppendAllText((Join-Path (Get-Location).Path $dumpPath), $dataBlock, $utf8)
Write-Host ("appended reference data ({0} lines)" -f $dataLines.Count) -ForegroundColor Cyan

# --- 5. append post-block (UTF-8, no BOM) ---------------------------
$dumpFull = Join-Path (Get-Location).Path $dumpPath
# pg_dump's header sets search_path='' (and check_function_bodies=off, row_security=off) for the
# whole session. The post-block was written as ordinary migrations, so restore session defaults first.
$resetBlock = "`n`n-- restore session defaults before the post-block (pg_dump header emptied search_path)`n" +
              "RESET search_path;`nRESET check_function_bodies;`nRESET row_security;`nRESET client_min_messages;`nRESET xmloption;`n`n"
[System.IO.File]::AppendAllText($dumpFull, $resetBlock + [System.IO.File]::ReadAllText($postPath), $utf8)
Write-Host "appended post-block from $postPath" -ForegroundColor Cyan

# --- 5b. exact object privileges, generated from the pre-Nov catalog ----
# pg_dump's ACL statements do not undo what Supabase's default privileges grant at CREATE time
# (anon/authenticated/service_role get ALL, incl. PG17's MAINTAIN, on every new table), and the
# DML grants the old chain gave explicitly were not reproduced. So: for every table/view/matview/
# sequence/function in public, REVOKE from the API roles, then re-GRANT exactly what the old
# catalog has. Objects whose ACL is NULL (default) end up back at the default.
$aclRelSql = @'
select line from (
  select c.relname as nm, 1 as ord, '' as g,
         format('REVOKE ALL ON %s public.%I FROM PUBLIC, anon, authenticated, service_role;',
                case when c.relkind = 'S' then 'SEQUENCE' else 'TABLE' end, c.relname) as line
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S')
     and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
  union all
  select c.relname, 2, coalesce(r.rolname, 'public') || ':' || a.is_grantable::text,
         format('GRANT %s ON %s public.%I TO %s%s;',
                string_agg(a.privilege_type, ', ' order by a.privilege_type),
                case when c.relkind = 'S' then 'SEQUENCE' else 'TABLE' end, c.relname,
                case when a.grantee = 0 then 'PUBLIC' else quote_ident(r.rolname) end,
                case when a.is_grantable then ' WITH GRANT OPTION' else '' end)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) a
    left join pg_roles r on r.oid = a.grantee
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S') and a.grantee <> c.relowner
     and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
   group by c.relname, c.relkind, a.grantee, r.rolname, a.is_grantable
) q
order by nm collate "C", ord, g collate "C";
'@
$aclFnSql = @'
select line from (
  select p.oid::regprocedure::text as nm, 1 as ord, '' as g,
         format('REVOKE ALL ON %s %s FROM %s;',
                case when p.prokind = 'p' then 'PROCEDURE' else 'FUNCTION' end, p.oid::regprocedure,
                case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) x where x.grantee = 0)
                     then 'anon, authenticated, service_role'
                     else 'PUBLIC, anon, authenticated, service_role' end) as line
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  union all
  select p.oid::regprocedure::text, 2, coalesce(r.rolname, 'public') || ':' || a.is_grantable::text,
         format('GRANT EXECUTE ON %s %s TO %s%s;',
                case when p.prokind = 'p' then 'PROCEDURE' else 'FUNCTION' end, p.oid::regprocedure,
                case when a.grantee = 0 then 'PUBLIC' else quote_ident(r.rolname) end,
                case when a.is_grantable then ' WITH GRANT OPTION' else '' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(p.proacl) a
    left join pg_roles r on r.oid = a.grantee
   where n.nspname = 'public' and p.prokind in ('f', 'p') and a.grantee <> p.proowner
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
) q
order by nm collate "C", ord, g collate "C";
'@
# Default privileges: pg_dump --no-privileges drops them, so tables created by the Nov tail got the
# image defaults instead of the ones the old chain set (service_role lost SELECT/INSERT/UPDATE/DELETE).
$aclDefSql = @'
select line from (
  select d.defaclobjtype::text as ot, 1 as ord, '' as g,
         format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON %s FROM PUBLIC, anon, authenticated, service_role;', r.rolname, n.nspname, k.kind) as line
    from pg_default_acl d join pg_roles r on r.oid = d.defaclrole join pg_namespace n on n.oid = d.defaclnamespace
    cross join lateral (select case d.defaclobjtype when 'r' then 'TABLES' when 'S' then 'SEQUENCES' when 'f' then 'FUNCTIONS' when 'T' then 'TYPES' end as kind) k
   where r.rolname = 'postgres' and n.nspname = 'public' and k.kind is not null
  union all
  select d.defaclobjtype::text, 2, coalesce(gr.rolname, 'public'),
         format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT %s ON %s TO %s%s;', r.rolname, n.nspname,
                string_agg(a.privilege_type, ', ' order by a.privilege_type), k.kind,
                case when a.grantee = 0 then 'PUBLIC' else quote_ident(gr.rolname) end,
                case when a.is_grantable then ' WITH GRANT OPTION' else '' end)
    from pg_default_acl d join pg_roles r on r.oid = d.defaclrole join pg_namespace n on n.oid = d.defaclnamespace
    cross join lateral (select case d.defaclobjtype when 'r' then 'TABLES' when 'S' then 'SEQUENCES' when 'f' then 'FUNCTIONS' when 'T' then 'TYPES' end as kind) k
    cross join lateral aclexplode(d.defaclacl) a
    left join pg_roles gr on gr.oid = a.grantee
   where r.rolname = 'postgres' and n.nspname = 'public' and k.kind is not null and a.grantee <> d.defaclrole
   group by d.defaclobjtype, r.rolname, n.nspname, k.kind, a.grantee, gr.rolname, a.is_grantable
) q
order by ot, ord, g collate "C";
'@
$aclRel = @(Invoke-Psql $aclRelSql)
$aclFn  = @(Invoke-Psql $aclFnSql)
$aclDef = @(Invoke-Psql $aclDefSql)
if ($aclDef.Count -lt 3) { throw ("Default-privilege generation returned {0} statements; expected at least 3 (tables, sequences, functions)." -f $aclDef.Count) }
if ($aclRel.Count -lt 100 -or $aclFn.Count -lt 100) { throw ("ACL generation returned too few statements (relations {0}, functions {1}); aborting." -f $aclRel.Count, $aclFn.Count) }
$aclBlock = "`n`n-- exact privileges of public relations and functions, generated from the pre-Nov catalog`n" +
            "RESET search_path;`n" + ($aclRel -join "`n") + "`n" + ($aclFn -join "`n") + "`n" + ($aclDef -join "`n") + "`n"
[System.IO.File]::AppendAllText($dumpFull, $aclBlock, $utf8)
Write-Host ("appended generated privileges ({0} relation + {1} function + {2} default-privilege statements)" -f $aclRel.Count, $aclFn.Count, $aclDef.Count) -ForegroundColor Cyan

# --- 6. replay new layout via the CLI, fingerprint (B), compare -----
"`n--- supabase db reset (baseline + Nov tail) ---" | Write-Host -ForegroundColor DarkGray
& npx supabase@2.114.0 db reset --yes 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'supabase db reset failed on the squashed layout; see output above. (DB is now in a partial state; restore the old tree + db reset before re-running.)' }
$cid = Get-DbCid
if (-not $cid) { throw 'db container not found after reset.' }

$r = @(Invoke-Psql 'select count(*) from supabase_migrations.schema_migrations;')
$appliedNew = [int]$r[0]
$expectedNew = 1 + $tail.Count
if ($appliedNew -ne $expectedNew) { throw "After reset $appliedNew migrations are applied; expected $expectedNew (baseline + $($tail.Count) tail)." }

$fpB = @(Invoke-Psql $fpSql)
Write-Host ("  B: {0} catalog lines" -f $fpB.Count) -ForegroundColor DarkGray

$cntB = @(Invoke-Psql $cntSql)
$cntDiff = @(Compare-Object -ReferenceObject $cntA -DifferenceObject $cntB -CaseSensitive)
if ($cntDiff.Count -gt 0) {
  Write-Host "ROW COUNT DIFFERENCES (informational; old vs new, after seed):" -ForegroundColor Yellow
  $cntDiff | ForEach-Object { ($(if ($_.SideIndicator -eq '<=') { 'OLD ' } else { 'NEW ' })) + $_.InputObject } | Out-Host
} else { Write-Host "ROW COUNTS EQUIVALENT." -ForegroundColor Green }

$diffFile = 'squash-catalog-diff.txt'
$diff = @(Compare-Object -ReferenceObject $fpA -DifferenceObject $fpB -CaseSensitive)
if ($diff.Count -gt 0) {
  $diff | ForEach-Object { ($(if ($_.SideIndicator -eq '<=') { 'OLD ONLY ' } else { 'NEW ONLY ' })) + $_.InputObject } |
    Set-Content -Path $diffFile -Encoding UTF8
  Write-Host "CATALOG DIFFERENCES FOUND (OLD ONLY = in old layout, missing/different in baseline):" -ForegroundColor Yellow
  $dl = Get-Content $diffFile
  Write-Host "diff counts by side/kind:" -ForegroundColor Yellow
  $dl | Group-Object { ($_ -split '\|')[0] } | Sort-Object Name | ForEach-Object { '{0,5}  {1}' -f $_.Count, $_.Name } | Out-Host
  Write-Host "samples (first 3 per side/kind; full list in $diffFile):" -ForegroundColor Yellow
  $dl | Group-Object { ($_ -split '\|')[0] } | ForEach-Object { $_.Group | Select-Object -First 3 } | Out-Host
  throw "Baseline is NOT equivalent; see $diffFile"
} else {
  Write-Host "CATALOG EQUIVALENT." -ForegroundColor Green
  Remove-Item $diffFile -ErrorAction SilentlyContinue
}

# --- 7. summary -----------------------------------------------------
Write-Host "`nMigrations directory NOW:" -ForegroundColor Cyan
Get-ChildItem $migDir -File -Filter *.sql | Sort-Object Name | ForEach-Object { "  " + $_.Name }

$archivedVersions = ($toArchive | ForEach-Object { ($_.Name -split '_')[0] }) -join ' '
Write-Host @"

---------------------------------------------------------------------
ON PROD (after CI passes on this squashed branch):
  1. git pull
  2. For EACH archived version ($($toArchive.Count) total):
       npx supabase@2.114.0 migration repair --status reverted <version>
     Versions (one line, space separated, you can feed to xargs or a loop):
       $archivedVersions
  3. npx supabase@2.114.0 migration repair --status applied 20261031235900
  4. npx supabase@2.114.0 migration up
Never run `supabase db push` before step 2 -- it will see the archived
files as "not applied" and try to replay them on top of prod.
---------------------------------------------------------------------
"@ -ForegroundColor Yellow