import { useEffect, useState } from "react";
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog,
  DialogActions, DialogContent, DialogTitle, Divider, Grid, IconButton,
  MenuItem, Table, TableBody, TableCell, TableHead, TableRow, TextField,
  Tooltip, Typography,
} from "@mui/material";
import { Add, Build, CheckCircle, Delete, Edit, History } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Machine { id: string; name: string; machine_no: string; }
interface MaintenanceType { id: string; name: string; }
interface AppUser { id: string; name: string; }
interface MaintenanceRequest {
  id: string;
  tenant_id: string;
  machine_id: string;
  type: string | null;
  description: string | null;
  status: "scheduled" | "in_progress" | "completed" | "cancelled";
  requested_by: string | null;
  assigned_to: string | null;
  scheduled_date: string | null;
  completed_date: string | null;
  actual_cost: number | null;
  created_at: string;
  machines?: { name: string; machine_no: string } | null;
  assignee?: { name: string } | null;
}
interface MaintenanceEvent {
  id: string;
  status: string;
  note: string | null;
  actual_cost: number | null;
  created_at: string;
  app_users?: { name: string } | null;
}

const emptyForm = { machine_id: "", type: "", description: "", scheduled_date: "", assigned_to: "" };

export default function MaintenanceRequests() {
  const [requests, setRequests] = useState<MaintenanceRequest[]>([]);
  const [machines, setMachines] = useState<Machine[]>([]);
  const [types, setTypes] = useState<MaintenanceType[]>([]);
  const [users, setUsers] = useState<AppUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<MaintenanceRequest | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState(emptyForm);

  // complete dialog (cost capture posts to GL when gl_control_accounts exist)
  const [completeFor, setCompleteFor] = useState<MaintenanceRequest | null>(null);
  const [completeCost, setCompleteCost] = useState("");
  const [completeNote, setCompleteNote] = useState("");
  const [costError, setCostError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // history dialog
  const [historyFor, setHistoryFor] = useState<MaintenanceRequest | null>(null);
  const [events, setEvents] = useState<MaintenanceEvent[]>([]);
  const [eventsLoading, setEventsLoading] = useState(false);

  const fetchData = async () => {
    setLoading(true);
    const [reqRes, machinesRes, typesRes, usersRes] = await Promise.all([
      supabase.from("maintenance_requests").select("*, machines(name, machine_no), assignee:app_users!maintenance_requests_assigned_to_fkey(name)").order("created_at", { ascending: false }).limit(200),
      supabase.from("machines").select("id, name, machine_no").order("name"),
      supabase.from("maintenance_types").select("id, name").eq("is_active", true).order("name"),
      supabase.from("app_users").select("id, name").order("name").limit(200),
    ]);
    if (reqRes.data) {
      const normalized = (reqRes.data as any[]).map((r: any) => ({
        ...r,
        machines: Array.isArray(r.machines) ? r.machines[0] ?? null : r.machines ?? null,
        assignee: Array.isArray(r.assignee) ? r.assignee[0] ?? null : r.assignee ?? null,
      }));
      setRequests(normalized as MaintenanceRequest[]);
    }
    if (machinesRes.data) setMachines(machinesRes.data as Machine[]);
    if (typesRes.data) setTypes(typesRes.data as MaintenanceType[]);
    if (usersRes.data) setUsers(usersRes.data as AppUser[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const openCreate = () => { setEditing(null); setForm(emptyForm); setError(null); setOpen(true); };
  const openEdit = (row: MaintenanceRequest) => {
    setEditing(row);
    setForm({ machine_id: row.machine_id || "", type: row.type || "", description: row.description || "", scheduled_date: row.scheduled_date || "", assigned_to: row.assigned_to || "" });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.machine_id) { setError("Select a machine."); return; }
    if (!form.type) { setError("Select a maintenance type."); return; }
    setSaving(true);
    let res;
    if (editing) {
      // Status is no longer editable here -- it moves via the workflow
      // actions (Start / Complete / Cancel) so every step is audited.
      const payload: any = { machine_id: form.machine_id, type: form.type, description: form.description.trim() || null, scheduled_date: form.scheduled_date || null, assigned_to: form.assigned_to || null };
      res = await supabase.from("maintenance_requests").update(payload).eq("id", editing.id);
    } else {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) { setSaving(false); setError("You need to be signed in."); return; }
      const { data: profile, error: profileError } = await supabase.from("app_users").select("tenant_id").eq("id", user.id).single();
      if (profileError || !profile?.tenant_id) { setSaving(false); setError(profileError?.message || "Could not determine organization."); return; }
      const payload: any = { machine_id: form.machine_id, type: form.type, description: form.description.trim() || null, status: "scheduled", requested_by: user.id, assigned_to: form.assigned_to || null, scheduled_date: form.scheduled_date || null, tenant_id: profile.tenant_id };
      res = await supabase.from("maintenance_requests").insert(payload);
    }
    setSaving(false);
    if (res.error) { setError(res.error.message); return; }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this request?")) return;
    const { error } = await supabase.from("maintenance_requests").delete().eq("id", id);
    if (error) alert(error.message);
    else fetchData();
  };

  // All status changes go through transition_maintenance_request -- never
  // a direct update -- so the audit table, notifications and GL posting
  // all stay consistent (20260921120000).
  const transition = async (row: MaintenanceRequest, to: string, note?: string | null, actualCost?: number | null) => {
    setBusy(true);
    const { error } = await supabase.rpc("transition_maintenance_request", {
      p_request_id: row.id,
      p_status: to,
      p_note: note ?? null,
      p_actual_cost: actualCost ?? null,
    });
    setBusy(false);
    if (error) setCostError(error.message);
    else { fetchData(); }
  };

  const confirmComplete = async () => {
    if (!completeFor) return;
    const cost = completeCost.trim() ? parseFloat(completeCost) : null;
    if (completeCost.trim() && (isNaN(cost!) || cost! < 0)) {
      setCostError("Cost must be a non-negative number (leave empty if the work wasn't costed).");
      return;
    }
    await transition(completeFor, "completed", completeNote.trim() || null, cost);
    setCompleteFor(null);
    setCompleteCost("");
    setCompleteNote("");
    setCostError(null);
  };

  const openHistory = async (row: MaintenanceRequest) => {
    setHistoryFor(row);
    setEvents([]);
    setEventsLoading(true);
    const { data } = await supabase
      .from("machine_maintenance_events")
      .select("id, status, note, actual_cost, created_at, app_users(name)")
      .eq("request_id", row.id)
      .order("created_at", { ascending: false });
    if (data) {
      setEvents(data.map((e: any) => ({ ...e, app_users: Array.isArray(e.app_users) ? e.app_users[0] ?? null : e.app_users ?? null })) as MaintenanceEvent[]);
    }
    setEventsLoading(false);
  };

  const statusColor = (status: string | null) => {
    if (status === "completed") return "success";
    if (status === "cancelled") return "default";
    if (status === "in_progress") return "warning";
    return "info";
  };

  const eventColor = (status: string) => {
    if (status === "completed") return "success";
    if (status === "cancelled") return "default";
    if (status === "in_progress") return "warning";
    return "info";
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Maintenance Requests</Typography>
          <Typography variant="body2" color="text.secondary">
            {requests.length} requests. Statuses move through the audited workflow; completing with a cost posts to the GL.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Request</Button>
      </Box>

      {costError && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setCostError(null)}>{costError}</Alert>}

      <Card><CardContent sx={{ p: 0 }}>
        <Table>
          <TableHead>
            <TableRow>
              <TableCell>Machine</TableCell>
              <TableCell>Type</TableCell>
              <TableCell>Description</TableCell>
              <TableCell>Assignee</TableCell>
              <TableCell>Status</TableCell>
              <TableCell>Scheduled</TableCell>
              <TableCell align="right">Cost</TableCell>
              <TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {requests.length === 0 ? (
              <TableRow><TableCell colSpan={8} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No maintenance requests yet. Create breakdown or preventive requests.</Typography></TableCell></TableRow>
            ) : requests.map(r => (
              <TableRow key={r.id} hover>
                <TableCell>{r.machines ? `${r.machines.machine_no} - ${r.machines.name}` : "-"}</TableCell>
                <TableCell sx={{ textTransform: "capitalize" }}>{r.type}</TableCell>
                <TableCell><Typography variant="body2" sx={{ maxWidth: 260, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.description?.slice(0, 80) || "-"}</Typography></TableCell>
                <TableCell>{r.assignee?.name || "-"}</TableCell>
                <TableCell><Chip label={r.status} size="small" color={statusColor(r.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                <TableCell>{r.scheduled_date ? new Date(r.scheduled_date).toLocaleDateString() : "-"}</TableCell>
                <TableCell align="right">{r.actual_cost != null ? Number(r.actual_cost).toLocaleString() : "-"}</TableCell>
                <TableCell align="right">
                  {r.status === "scheduled" && (
                    <Tooltip title="Start work"><IconButton size="small" aria-label="Start maintenance" color="primary" disabled={busy} onClick={() => transition(r, "in_progress")}><Build fontSize="small" /></IconButton></Tooltip>
                  )}
                  {r.status === "in_progress" && (
                    <Tooltip title="Complete (capture cost)"><IconButton size="small" aria-label="Complete maintenance" color="success" disabled={busy} onClick={() => { setCompleteFor(r); setCompleteCost(r.actual_cost != null ? String(r.actual_cost) : ""); setCompleteNote(""); setCostError(null); }}><CheckCircle fontSize="small" /></IconButton></Tooltip>
                  )}
                  <Tooltip title="History"><IconButton size="small" aria-label="Maintenance history" onClick={() => openHistory(r)}><History fontSize="small" /></IconButton></Tooltip>
                  <Tooltip title="Edit"><IconButton size="small" aria-label="Edit request" onClick={() => openEdit(r)}><Edit fontSize="small" /></IconButton></Tooltip>
                  <Tooltip title="Delete"><IconButton size="small" aria-label="Delete request" onClick={() => handleDelete(r.id)}><Delete fontSize="small" /></IconButton></Tooltip>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent></Card>

      {/* Create / edit (fields only -- status moves via workflow) */}
      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Maintenance Request" : "New Maintenance Request"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField select label="Machine *" value={form.machine_id} onChange={e => setForm({ ...form, machine_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Machine --</MenuItem>
            {machines.map(m => <MenuItem key={m.id} value={m.id}>{m.machine_no} - {m.name}</MenuItem>)}
          </TextField>
          <TextField select label="Type *" value={form.type} onChange={e => setForm({ ...form, type: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Type --</MenuItem>
            {types.map(t => <MenuItem key={t.id} value={t.name.toLowerCase()}>{t.name}</MenuItem>)}
          </TextField>
          <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline minRows={3} placeholder="Describe the issue or scope of work" />
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField label="Scheduled Date" type="date" value={form.scheduled_date} onChange={e => setForm({ ...form, scheduled_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
            </Grid>
            <Grid item xs={6}>
              <TextField select label="Assign To" value={form.assigned_to} onChange={e => setForm({ ...form, assigned_to: e.target.value })} fullWidth>
                <MenuItem value="">-- Unassigned --</MenuItem>
                {users.map(u => <MenuItem key={u.id} value={u.id}>{u.name}</MenuItem>)}
              </TextField>
            </Grid>
          </Grid>
          {editing && <Alert severity="info">Status changes happen from the list (Start / Complete) so every step is audited.</Alert>}
          {!editing && <Alert severity="info">New requests start as <strong>scheduled</strong>; assignees are notified when work starts, completes or runs overdue.</Alert>}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={saving || !form.machine_id || !form.type}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button>
        </DialogActions>
      </Dialog>

      {/* Complete with cost */}
      <Dialog open={!!completeFor} onClose={() => !busy && setCompleteFor(null)} maxWidth="xs" fullWidth>
        <DialogTitle>Complete maintenance — {completeFor?.machines?.machine_no}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField
            label="Actual cost (UGX)"
            type="number"
            value={completeCost}
            onChange={e => { setCompleteCost(e.target.value); setCostError(null); }}
            fullWidth autoFocus inputProps={{ min: 0, step: "any" }}
            helperText="Leave empty if un-costed. A given amount posts Dr expense / Cr AP to the GL."
            error={!!costError && !!completeFor}
          />
          <TextField label="Completion note" value={completeNote} onChange={e => setCompleteNote(e.target.value)} fullWidth multiline minRows={2} placeholder="What was done / parts used" />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setCompleteFor(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" color="success" onClick={confirmComplete} disabled={busy}>{busy ? "Saving…" : "Mark completed"}</Button>
        </DialogActions>
      </Dialog>

      {/* History */}
      <Dialog open={!!historyFor} onClose={() => setHistoryFor(null)} maxWidth="sm" fullWidth>
        <DialogTitle>History — {historyFor?.machines?.machine_no} {historyFor?.type ? `(${historyFor.type})` : ""}</DialogTitle>
        <DialogContent dividers>
          {eventsLoading ? (
            <Box sx={{ display: "flex", justifyContent: "center", py: 3 }}><CircularProgress size={28} /></Box>
          ) : events.length === 0 ? (
            <Typography variant="body2" color="text.secondary">No workflow events recorded yet.</Typography>
          ) : events.map((e, i) => (
            <Box key={e.id}>
              {i > 0 && <Divider sx={{ my: 1.5 }} />}
              <Box sx={{ display: "flex", alignItems: "center", gap: 1, flexWrap: "wrap" }}>
                <Chip label={e.status} size="small" color={eventColor(e.status) as any} sx={{ textTransform: "capitalize", minWidth: 90 }} />
                <Typography variant="body2" fontWeight={600}>{e.app_users?.name ?? "Unknown user"}</Typography>
                <Typography variant="body2" color="text.secondary">{new Date(e.created_at).toLocaleString()}</Typography>
                {e.actual_cost != null && <Chip label={`UGX ${Number(e.actual_cost).toLocaleString()}`} size="small" variant="outlined" />}
              </Box>
              {e.note && <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5, ml: 1 }}>{e.note}</Typography>}
            </Box>
          ))}
        </DialogContent>
      </Dialog>
    </Box>
  );
}
