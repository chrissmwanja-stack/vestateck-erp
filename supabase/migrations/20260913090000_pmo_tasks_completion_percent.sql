-- pmo_tasks had no completion_percent column, unlike pmo_milestones which
-- already tracks one. GanttChart.tsx was estimating task progress from
-- status (todo/in_progress/review/done -> 10/50/75/100) as a stopgap.
-- This adds a real column, defaulted and bounded the same way
-- pmo_milestones.completion_percent already is, so the two tables share
-- one convention. No RLS changes needed: pmo_tasks_write_update already
-- covers pmo/admin/manager plus the task's own assignee, which is exactly
-- who should be allowed to move this number.

ALTER TABLE public.pmo_tasks
  ADD COLUMN IF NOT EXISTS completion_percent integer NOT NULL DEFAULT 0;

-- Backfill from status using the same mapping GanttChart.tsx's getProgress()
-- was estimating with, so existing in_progress/review/done tasks don't
-- visually regress to 0% the moment this column starts being read instead
-- of estimated. New tasks going forward start at the column default (0)
-- and move via the task edit dialog, same as pmo_milestones already works.
UPDATE public.pmo_tasks
  SET completion_percent = CASE status
    WHEN 'done' THEN 100
    WHEN 'review' THEN 75
    WHEN 'in_progress' THEN 50
    ELSE 0
  END
  WHERE completion_percent = 0;

ALTER TABLE public.pmo_tasks
  ADD CONSTRAINT pmo_tasks_completion_percent_check
  CHECK (completion_percent >= 0 AND completion_percent <= 100);