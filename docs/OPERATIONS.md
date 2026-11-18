# Operations runbook

How to keep VestaPortal running and how to recover when it is not. Items marked
**TODO** need a value only the owner has (a URL, a name); fill them in once and
commit.

## 1. What runs where

| Piece | Where | Deployed by |
|---|---|---|
| Web app (`apps/web`) and `/api/*` routes | Vercel | Push to `main` |
| Database, auth, edge functions | Supabase project `xownbroirovedkmqyybc` | Migrations applied by hand (`apply_migration` or the CLI); functions deployed with the CLI |
| CI | GitHub Actions (`.github/workflows`) | n/a |
| Off-platform database backups | S3-compatible bucket (**TODO**: name the provider and bucket) | `db-backup.yml` |

## 2. Backups

### What is backed up

`.github/workflows/db-backup.yml` runs every day at 01:30 UTC. It takes a
`pg_dump` of the `public`, `auth` and `storage` schemas, checks the file is
readable and not tiny, encrypts it with an **age** public key, and uploads it
to the bucket under `db/vestaportal-<UTC timestamp>.dump.age`. It is never
attached to the workflow run, because the repository is public.

Not covered: the files stored in Supabase Storage (the dump holds only their
metadata), Supabase project settings, and edge-function secrets. Keep the list
in section 6 so the secrets can be re-created.

### One-time setup

1. **Make an age key pair** on a trusted machine (`winget install
   FiloSottile.age`, then `age-keygen -o vestaportal-backup.key`). The file
   prints the public key (`age1...`). Store the private key file in a password
   manager and on one offline copy. If it is lost, every backup is unreadable.
2. **Create the bucket** (Cloudflare R2 has a free tier and no egress fees;
   Backblaze B2 and S3 also work). Add a lifecycle rule that deletes objects
   under `db/` after 30 days. Create an access key limited to this bucket.
3. **Create a database connection string for the session pooler.** In the
   Supabase dashboard: Connect, then Session pooler. It looks like
   `postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres`.
   Use the pooler because GitHub runners are IPv4 and the direct host is IPv6
   only. Consider a dedicated read-only database role instead of `postgres`.
4. **Add the six repository secrets** listed at the top of `db-backup.yml`.
5. **Set `PG_MAJOR`** in the workflow to the project's Postgres major version
   (Dashboard, Settings, Infrastructure).
6. **Run it once by hand** (Actions, Database backup, Run workflow) and confirm
   the object appears in the bucket. Then do the restore drill below before
   trusting it.

### Restore drill (do it after setup, then every quarter)

A backup you have never restored is a hope, not a backup. Never restore into
production for a drill.

```powershell
# 1. Download one backup from the bucket (any S3 tool), then decrypt it:
age -d -i vestaportal-backup.key -o restore.dump vestaportal-20261118T013000Z.dump.age

# 2. Start a throwaway Postgres (use the same major version as production):
docker run -d --name restore-drill -e POSTGRES_PASSWORD=drill -p 55432:5432 postgres:17

# 3. Restore into it. Errors about missing Supabase roles/extensions are
#    expected on plain Postgres; row counts are what matters.
docker cp restore.dump restore-drill:/restore.dump
docker exec restore-drill pg_restore -U postgres -d postgres --no-owner --no-privileges --exit-on-error=false /restore.dump

# 4. Check it: tables exist, and the biggest ones have rows.
docker exec restore-drill psql -U postgres -c "select count(*) from public.app_users;"
docker exec restore-drill psql -U postgres -c "select count(*) from auth.users;"

# 5. Clean up.
docker rm -f restore-drill; Remove-Item restore.dump
```

Record each drill below.

| Date | Backup used | Result | Time taken |
|---|---|---|---|
| | | | |

### Recovering production from a backup

1. Stop writes if you can (put the app in maintenance by pausing the Vercel
   deployment, or revoke `authenticated` temporarily).
2. Create a **new** Supabase project (never overwrite the damaged one until the
   new one is verified).
3. Replay the migrations onto it from `supabase/migrations` so roles, grants
   and policies exist, then restore the data into it from the dump
   (`pg_restore --data-only --disable-triggers`, schema by schema).
4. Point `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` in Vercel and the
   edge-function secrets at the new project, redeploy, and re-run the checks in
   section 5.
5. Tell users that anything entered after the backup time (up to 24 hours) is
   lost and has to be re-entered.

The most data you can lose is one day. If that is too much, upgrade to a
Supabase plan with point-in-time recovery.

## 3. Monitoring

| Signal | State today | What to do |
|---|---|---|
| Uptime of app and database | Not configured in the repo | Add an external monitor (UptimeRobot, Better Stack) on `https://<project-ref>.supabase.co/rest/v1/rpc/health_check` (POST, `apikey` header, expect `status: ok`) and one on the Vercel app URL (**TODO**). Alert to email and phone. |
| Client-side errors | `/api/client-errors` writes one `console.error` line per error to the Vercel function logs | In Vercel, add a log drain or a log alert on the string `[client-error]`. Without this nobody is told. The endpoint's rate limit is in memory, so it is per function instance, not global. |
| CSP violations | `/api/csp-report` | Same: alert on its log line, or review weekly. |
| Edge function errors | Supabase dashboard, Edge Functions, Logs | Check after each deploy. A `[cors] ALLOWED_ORIGINS is not set` warning means browser calls are being blocked. |
| Database keep-alive | `supabase-keepalive.yml` every 3 days | Only needed on the Free plan; it keeps the project from pausing. |
| Backup success | `db-backup.yml` | A failed run emails the repository owner. Keep GitHub notifications for failed workflows on. |
| Dependency and secret scanning | `security-scan.yml`, Dependabot | Read the weekly results. |

## 4. Incident response

1. **Decide the size.** Data leak or wrong money posted: stop and treat as
   serious. App down: serious if users cannot work. Cosmetic bug: ordinary
   fix.
2. **Contain first.** Leak: rotate the exposed key or password (section 6),
   revoke sessions, and restrict the affected table or function with a
   migration. Wrong postings: do not edit journals; use the void and reverse
   functions so the audit trail stays intact.
3. **Roll back the web app** in Vercel (Deployments, previous deployment,
   Promote). This is instant and does not touch the database.
4. **Database changes are not rolled back; they are fixed forward.** Applied
   migrations are never edited (`supabase/MIGRATION_POLICY.md`). Write a new
   migration that undoes the change, test it on a fresh replay, apply it. New
   migrations must not use `DROP COLUMN` or `DROP TABLE` on existing objects.
5. **Write it down** within a day: what happened, when it started, what fixed
   it, and which check would have caught it. Add that check to CI or this file.

## 5. After every deploy

- [ ] CI was green on the merged PR (all eight required checks).
- [ ] If a migration was applied: `supabase_migrations.schema_migrations` has
      the version, and the file in the repo is named with that exact version.
- [ ] If edge functions were deployed: `ALLOWED_ORIGINS` is set
      (`supabase secrets list` shows the name) and includes the production app
      origin; sign in and open one screen that calls a function (invite a user
      or generate a PO).
- [ ] The monitors in section 3 are green.
- [ ] Supabase advisors (security and performance) show nothing new.

## 6. Secrets inventory

Names only. Never write values in this file or anywhere in the repository.

| Name | Where it lives | Used by |
|---|---|---|
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | Vercel environment | Web app (public by design) |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | GitHub Actions secrets | `supabase-keepalive.yml` |
| `SUPABASE_DB_URL`, `BACKUP_AGE_RECIPIENT`, `BACKUP_S3_BUCKET`, `BACKUP_S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | GitHub Actions secrets | `db-backup.yml` |
| age private key | Password manager and one offline copy | Decrypting backups; **not** in GitHub |
| `ALLOWED_ORIGINS` | Supabase edge-function secrets | CORS allowlist (`supabase/functions/_shared/cors.ts`) |
| `OPERATOR_DIGEST_SECRET` | Supabase edge-function secrets and the scheduler | `send-operator-digest` |
| `BOOTSTRAP_ADMIN_CODE` | Supabase edge-function secrets | `bootstrap-admin` |
| Supabase service-role key | Supabase (injected into functions); never in the browser or in GitHub | Edge functions |

If any of these is exposed: rotate it, redeploy whatever reads it, then check
the logs for use of the old one.
