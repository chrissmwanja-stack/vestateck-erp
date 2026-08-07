
-- Pre-existing trigger from before the table rename/redesign -- referenced
-- NEW.status, which no longer exists on this table. Fully superseded by
-- trg_set_material_request_batch_defaults (also sets requester_id).
drop trigger if exists material_request_defaults on public.material_request_batches;
drop function if exists public.set_material_request_defaults();
