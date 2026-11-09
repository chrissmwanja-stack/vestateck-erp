-- Index the 9 foreign keys the performance advisor still reports as
-- unindexed (re-verified live with a pg_constraint / pg_index query).
-- Plain CREATE INDEX IF NOT EXISTS, matching 20260925134000: these tables
-- are small/append-mostly, and CONCURRENTLY cannot run inside a migration
-- transaction. tenant_id / actor_id / decided_by indexes serve tenant-scoped
-- listing and FK cascade checks. Deliberately NOT touching the ~166 "unused"
-- indexes: that needs pg_stat_user_indexes evidence from real production
-- workload, not a one-shot migration.

create index if not exists machine_maintenance_events_actor_id_idx on public.machine_maintenance_events (actor_id);
create index if not exists machine_maintenance_events_tenant_id_idx on public.machine_maintenance_events (tenant_id);
create index if not exists maintenance_requests_assigned_to_idx on public.maintenance_requests (assigned_to);
create index if not exists platform_announcements_tenant_id_idx on public.platform_announcements (tenant_id);
create index if not exists platform_job_runs_tenant_id_idx on public.platform_job_runs (tenant_id);
create index if not exists pmo_project_decisions_decided_by_idx on public.pmo_project_decisions (decided_by);
create index if not exists pmo_project_decisions_tenant_id_idx on public.pmo_project_decisions (tenant_id);
create index if not exists pmo_projects_created_by_idx on public.pmo_projects (created_by);
create index if not exists tenant_feature_flags_flag_key_idx on public.tenant_feature_flags (flag_key);
