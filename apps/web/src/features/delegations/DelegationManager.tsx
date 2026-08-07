import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Chip,
  Divider,
  MenuItem,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";

interface Colleague {
  id: string;
  name: string;
  email: string;
  role_title: string;
}

interface Stage {
  id: string;
  name: string;
}

interface Delegation {
  id: string;
  delegator_user_id: string;
  delegate_user_id: string;
  workflow_stage_id: string | null;
  starts_at: string;
  ends_at: string;
  status: string;
  created_at: string;
}

// datetime-local wants "YYYY-MM-DDTHH:mm" in local time, no timezone suffix
function toLocalInputValue(date: Date) {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(
    date.getHours()
  )}:${pad(date.getMinutes())}`;
}

export default function DelegationManager({ userId }: { userId: string }) {
  const [colleagues, setColleagues] = useState<Colleague[]>([]);
  const [myStages, setMyStages] = useState<Stage[]>([]);
  const [granted, setGranted] = useState<Delegation[]>([]);
  const [received, setReceived] = useState<Delegation[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // form state
  const [delegate, setDelegate] = useState<Colleague | null>(null);
  const [stageId, setStageId] = useState<string>("__all__");
  const defaultEnd = useMemo(() => {
    const d = new Date();
    d.setDate(d.getDate() + 7);
    return toLocalInputValue(d);
  }, []);
  const [endsAt, setEndsAt] = useState(defaultEnd);
  const [startsAt, setStartsAt] = useState(toLocalInputValue(new Date()));

  const nameById = useMemo(() => {
    const map = new Map<string, string>();
    colleagues.forEach((c) => map.set(c.id, c.name));
    map.set(userId, "You");
    return map;
  }, [colleagues, userId]);

  const stageNameById = useMemo(() => {
    const map = new Map<string, string>();
    myStages.forEach((s) => map.set(s.id, s.name));
    return map;
  }, [myStages]);

  const loadAll = useCallback(async () => {
    setError(null);

    const [{ data: users, error: usersErr }, { data: assignments, error: assignErr }] =
      await Promise.all([
        supabase.from("app_users").select("id, name, email, role_title").neq("id", userId),
        supabase
          .from("approval_assignments")
          .select("workflow_stage_id, workflow_stages(id, name)")
          .eq("user_id", userId),
      ]);

    if (usersErr) setError(usersErr.message);
    else setColleagues((users ?? []) as Colleague[]);

    if (assignErr) {
      // Embedded select can fail if the FK relationship isn't set up for
      // PostgREST embedding — fall back to two flat queries.
      const { data: aa } = await supabase
        .from("approval_assignments")
        .select("workflow_stage_id")
        .eq("user_id", userId);
      const stageIds = (aa ?? []).map((r) => r.workflow_stage_id);
      if (stageIds.length > 0) {
        const { data: stages } = await supabase
          .from("workflow_stages")
          .select("id, name")
          .in("id", stageIds);
        setMyStages((stages ?? []) as Stage[]);
      } else {
        setMyStages([]);
      }
    } else {
      const stages = (assignments ?? [])
        .map((a) => {
          // PostgREST embeds a to-one relationship as an object normally,
          // but as a single-element array in some FK/schema-cache states.
          // Handle both rather than assuming one shape via `any`.
          const ws = a.workflow_stages as Stage | Stage[] | null;
          return Array.isArray(ws) ? ws[0] : ws;
        })
        .filter((s): s is Stage => Boolean(s));
      setMyStages(stages);
    }

    const { data: grantedRows } = await supabase
      .from("approval_delegations")
      .select("*")
      .eq("delegator_user_id", userId)
      .order("created_at", { ascending: false });
    setGranted((grantedRows ?? []) as Delegation[]);

    const { data: receivedRows } = await supabase
      .from("approval_delegations")
      .select("*")
      .eq("delegate_user_id", userId)
      .order("created_at", { ascending: false });
    setReceived((receivedRows ?? []) as Delegation[]);
  }, [userId]);

  useEffect(() => {
    loadAll();
  }, [loadAll]);

  const handleSubmit = async () => {
    setError(null);
    setSuccess(null);

    if (!delegate) {
      setError("Pick who you're delegating to.");
      return;
    }
    if (!endsAt) {
      setError("An end date/time is required.");
      return;
    }

    setSubmitting(true);
    const { error: rpcError } = await supabase.rpc("grant_delegation", {
      p_delegate_user_id: delegate.id,
      p_workflow_stage_id: stageId === "__all__" ? null : stageId,
      p_starts_at: startsAt ? new Date(startsAt).toISOString() : null,
      p_ends_at: new Date(endsAt).toISOString(),
    });
    setSubmitting(false);

    if (rpcError) {
      setError(rpcError.message);
      return;
    }

    setSuccess(`Delegation granted to ${delegate.name}.`);
    setDelegate(null);
    setStageId("__all__");
    await loadAll();
  };

  const handleRevoke = async (id: string) => {
    setError(null);
    const { error: revokeError } = await supabase
      .from("approval_delegations")
      .update({ status: "revoked" })
      .eq("id", id);
    if (revokeError) {
      setError(revokeError.message);
      return;
    }
    await loadAll();
  };

  const statusChip = (d: Delegation) => {
    const now = new Date();
    const ended = new Date(d.ends_at) < now;
    if (d.status === "revoked") return <Chip size="small" label="Revoked" />;
    if (ended) return <Chip size="small" label="Expired" />;
    return <Chip size="small" color="success" label="Active" />;
  };

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Delegations
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Delegate your approval authority to a colleague for a specific stage, or for everything
        you can act on, over a set time window. A delegate's authority is capped at your own —
        they can't act beyond what you could.
      </Typography>

      <Paper sx={{ p: 3, mb: 4 }}>
        <Typography variant="subtitle1" gutterBottom>
          Grant a delegation
        </Typography>

        {myStages.length === 0 && (
          <Alert severity="info" sx={{ mb: 2 }}>
            You don't currently hold any approval assignments, so there's nothing to delegate.
          </Alert>
        )}

        {error && (
          <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
            {error}
          </Alert>
        )}
        {success && (
          <Alert severity="success" sx={{ mb: 2 }} onClose={() => setSuccess(null)}>
            {success}
          </Alert>
        )}

        <Stack spacing={2}>
          <Autocomplete
            options={colleagues}
            getOptionLabel={(c) => `${c.name} — ${c.role_title}`}
            value={delegate}
            onChange={(_, value) => setDelegate(value)}
            renderInput={(params) => (
              <TextField {...params} label="Delegate to" placeholder="Search colleagues" />
            )}
            disabled={myStages.length === 0}
          />

          <TextField
            select
            label="Stage"
            value={stageId}
            onChange={(e) => setStageId(e.target.value)}
            disabled={myStages.length === 0}
          >
            <MenuItem value="__all__">All stages I hold</MenuItem>
            {myStages.map((s) => (
              <MenuItem key={s.id} value={s.id}>
                {s.name}
              </MenuItem>
            ))}
          </TextField>

          <Stack direction="row" spacing={2}>
            <TextField
              label="Starts"
              type="datetime-local"
              value={startsAt}
              onChange={(e) => setStartsAt(e.target.value)}
              InputLabelProps={{ shrink: true }}
              fullWidth
              disabled={myStages.length === 0}
            />
            <TextField
              label="Ends"
              type="datetime-local"
              value={endsAt}
              onChange={(e) => setEndsAt(e.target.value)}
              InputLabelProps={{ shrink: true }}
              fullWidth
              required
              disabled={myStages.length === 0}
            />
          </Stack>

          <Box>
            <Button
              variant="contained"
              onClick={handleSubmit}
              disabled={submitting || myStages.length === 0}
            >
              Grant delegation
            </Button>
          </Box>
        </Stack>
      </Paper>

      <Paper sx={{ p: 3, mb: 4 }}>
        <Typography variant="subtitle1" gutterBottom>
          Delegations you've granted
        </Typography>
        {granted.length === 0 ? (
          <Typography variant="body2" color="text.secondary">
            None yet.
          </Typography>
        ) : (
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Delegate</TableCell>
                <TableCell>Stage</TableCell>
                <TableCell>Window</TableCell>
                <TableCell>Status</TableCell>
                <TableCell align="right">Action</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {granted.map((d) => (
                <TableRow key={d.id}>
                  <TableCell>{nameById.get(d.delegate_user_id) ?? d.delegate_user_id}</TableCell>
                  <TableCell>
                    {d.workflow_stage_id
                      ? stageNameById.get(d.workflow_stage_id) ?? d.workflow_stage_id
                      : "All stages"}
                  </TableCell>
                  <TableCell>
                    {new Date(d.starts_at).toLocaleString()} →{" "}
                    {new Date(d.ends_at).toLocaleString()}
                  </TableCell>
                  <TableCell>{statusChip(d)}</TableCell>
                  <TableCell align="right">
                    {d.status === "active" && new Date(d.ends_at) > new Date() && (
                      <Button size="small" color="error" onClick={() => handleRevoke(d.id)}>
                        Revoke
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Paper>

      <Paper sx={{ p: 3 }}>
        <Typography variant="subtitle1" gutterBottom>
          Delegated to you
        </Typography>
        {received.length === 0 ? (
          <Typography variant="body2" color="text.secondary">
            No one has delegated approval authority to you.
          </Typography>
        ) : (
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>From</TableCell>
                <TableCell>Stage</TableCell>
                <TableCell>Window</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {received.map((d) => (
                <TableRow key={d.id}>
                  <TableCell>{nameById.get(d.delegator_user_id) ?? d.delegator_user_id}</TableCell>
                  <TableCell>
                    {d.workflow_stage_id
                      ? stageNameById.get(d.workflow_stage_id) ?? d.workflow_stage_id
                      : "All stages"}
                  </TableCell>
                  <TableCell>
                    {new Date(d.starts_at).toLocaleString()} →{" "}
                    {new Date(d.ends_at).toLocaleString()}
                  </TableCell>
                  <TableCell>{statusChip(d)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Paper>

      <Divider sx={{ my: 3 }} />
      <Typography variant="caption" color="text.disabled">
        Delegation authority can't exceed what you personally hold — you can't grant a stage you
        don't have, and a delegate can't sub-delegate what they receive from you.
      </Typography>
    </Box>
  );
}