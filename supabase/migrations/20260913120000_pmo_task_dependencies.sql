-- PMO task dependencies + critical path support.
--
-- GanttChart.tsx and TasksList.tsx had no way to express "task B can't
-- start until task A finishes" -- this was flagged as a known gap in
-- the Sep 13 session (see PMO Gantt chart investigation notes). This
-- migration adds the predecessor/successor edge table the frontend
-- needs to draw dependency awareness and compute a critical path;
-- the critical-path *calculation* itself is done client-side in
-- GanttChart.tsx (longest-path-by-duration over this graph), so no
-- new RPC is needed here.
--
-- Design notes:
-- * One row per directed edge (predecessor_task_id -> successor_task_id),
--   finish-to-start only (no lag/lead, no other dependency types) --
--   the simplest model that supports a real critical path, matching
--   the scope of what's requested. FS-with-lag can be added later as
--   an additive column if it's ever needed.
-- * tenant_id is required on insert, same convention as pmo_tasks
--   itself (the app reads it off the task, doesn't rely on a trigger
--   default).
-- * Both tasks must belong to the same project -- cross-project
--   dependencies would make "critical path" ambiguous and aren't a
--   real PMO concept here (projects are the planning boundary
--   everywhere else in this module).
-- * A trigger blocks cycles via a recursive-CTE reachability check.
--   Without this, a bad predecessor/successor pair would make the
--   client's longest-path walk infinite-loop instead of failing loudly
--   at the one place (insert/update) where it's cheap to check.
-- * Write access follows the pmo_milestones pattern (admin/manager
--   only), not the pmo_tasks pattern (which also allows a task's own
--   assignee) -- sequencing tasks against each other is a planning
--   decision, not something that should hinge on which single task
--   happens to be "owned" by whoever is editing it.

CREATE TABLE IF NOT EXISTS public.pmo_task_dependencies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    predecessor_task_id uuid NOT NULL,
    successor_task_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pmo_task_dependencies_pkey PRIMARY KEY (id),
    CONSTRAINT pmo_task_dependencies_no_self_reference CHECK (predecessor_task_id <> successor_task_id),
    CONSTRAINT pmo_task_dependencies_unique_edge UNIQUE (predecessor_task_id, successor_task_id),
    CONSTRAINT pmo_task_dependencies_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE,
    CONSTRAINT pmo_task_dependencies_predecessor_task_id_fkey FOREIGN KEY (predecessor_task_id) REFERENCES public.pmo_tasks(id) ON DELETE CASCADE,
    CONSTRAINT pmo_task_dependencies_successor_task_id_fkey FOREIGN KEY (successor_task_id) REFERENCES public.pmo_tasks(id) ON DELETE CASCADE
);

ALTER TABLE public.pmo_task_dependencies OWNER TO postgres;

CREATE INDEX IF NOT EXISTS idx_pmo_task_dependencies_tenant ON public.pmo_task_dependencies USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_pmo_task_dependencies_predecessor ON public.pmo_task_dependencies USING btree (predecessor_task_id);
CREATE INDEX IF NOT EXISTS idx_pmo_task_dependencies_successor ON public.pmo_task_dependencies USING btree (successor_task_id);

-- Guard against cross-project edges and cycles. Runs on INSERT and
-- UPDATE (predecessor/successor could theoretically be repointed by an
-- UPDATE, even though the current UI only ever inserts/deletes edges).
CREATE OR REPLACE FUNCTION public.pmo_check_task_dependency_validity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_pred_project uuid;
  v_succ_project uuid;
  v_cycle_found boolean;
BEGIN
  SELECT project_id INTO v_pred_project FROM public.pmo_tasks WHERE id = NEW.predecessor_task_id;
  SELECT project_id INTO v_succ_project FROM public.pmo_tasks WHERE id = NEW.successor_task_id;

  IF v_pred_project IS DISTINCT FROM v_succ_project THEN
    RAISE EXCEPTION 'pmo_task_dependencies: predecessor and successor must belong to the same project';
  END IF;

  -- Would this edge close a loop? True iff the successor can already
  -- reach the predecessor through existing edges (excluding the row
  -- being updated, if this is an UPDATE) -- adding predecessor->successor
  -- on top of that path would complete a cycle.
  WITH RECURSIVE reachable AS (
    SELECT successor_task_id AS task_id
    FROM public.pmo_task_dependencies
    WHERE predecessor_task_id = NEW.successor_task_id
      AND (TG_OP = 'INSERT' OR id <> NEW.id)
    UNION
    SELECT d.successor_task_id
    FROM public.pmo_task_dependencies d
    JOIN reachable r ON d.predecessor_task_id = r.task_id
    WHERE (TG_OP = 'INSERT' OR d.id <> NEW.id)
  )
  SELECT EXISTS (SELECT 1 FROM reachable WHERE task_id = NEW.predecessor_task_id) INTO v_cycle_found;

  IF v_cycle_found THEN
    RAISE EXCEPTION 'pmo_task_dependencies: this dependency would create a cycle';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.pmo_check_task_dependency_validity() OWNER TO postgres;

CREATE OR REPLACE TRIGGER trg_pmo_task_dependencies_validate
  BEFORE INSERT OR UPDATE ON public.pmo_task_dependencies
  FOR EACH ROW EXECUTE FUNCTION public.pmo_check_task_dependency_validity();

ALTER TABLE public.pmo_task_dependencies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pmo_task_dependencies_select" ON public.pmo_task_dependencies
  FOR SELECT USING (tenant_id = public.get_my_tenant_id());

CREATE POLICY "pmo_task_dependencies_write_insert" ON public.pmo_task_dependencies
  FOR INSERT WITH CHECK (
    tenant_id = public.get_my_tenant_id()
    AND public.has_module_role('pmo', ARRAY['admin', 'manager'])
  );

CREATE POLICY "pmo_task_dependencies_write_update" ON public.pmo_task_dependencies
  FOR UPDATE USING (
    tenant_id = public.get_my_tenant_id()
    AND public.has_module_role('pmo', ARRAY['admin', 'manager'])
  ) WITH CHECK (
    tenant_id = public.get_my_tenant_id()
    AND public.has_module_role('pmo', ARRAY['admin', 'manager'])
  );

CREATE POLICY "pmo_task_dependencies_write_delete" ON public.pmo_task_dependencies
  FOR DELETE USING (
    tenant_id = public.get_my_tenant_id()
    AND public.has_module_role('pmo', ARRAY['admin', 'manager'])
  );

GRANT ALL ON TABLE public.pmo_task_dependencies TO anon;
GRANT ALL ON TABLE public.pmo_task_dependencies TO authenticated;
GRANT ALL ON TABLE public.pmo_task_dependencies TO service_role;