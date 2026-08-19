-- Security fix: move the btree_gist extension out of the public schema
-- into Supabase's standard `extensions` schema, per advisor recommendation
-- (extension_in_public). Extensions in public are writable by any role
-- with CREATE on public, which is broader than necessary.
--
-- Confirmed live dependency: approval_delegations_no_overlap, the GIST
-- exclusion-style index backing the delegation overlap guard
-- (grant_delegation_rpc_and_overlap_guard), uses btree_gist operator
-- classes for uuid equality alongside the tstzrange overlap check.
--
-- ALTER EXTENSION ... SET SCHEMA relocates the extension's objects in
-- place -- it does not drop and recreate them, so the existing index and
-- its operator classes are unaffected. `extensions` is already on the
-- default search_path in this project (Supabase's standard convention),
-- so no application code or other migration needs to change.

alter extension btree_gist set schema extensions;