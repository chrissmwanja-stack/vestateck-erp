import { useState } from "react";
import {
  Alert, Button, Dialog, DialogActions, DialogContent, DialogTitle, TextField,
} from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

// Shared "log time" dialog for TasksList (per-task) and ProjectBudgetPanel
// (project-level). Inserts into pmo_time_entries directly -- RLS lets a
// user insert only their OWN rows (user_id = auth.uid()), and the
// BEFORE-INSERT trigger snapshots hourly_rate from their active resource
// allocation (20260921113000_pmo_time_and_cost_tracking.sql).
export default function LogTimeDialog({
  open,
  onClose,
  projectId,
  taskId,
  taskTitle,
  projectName,
  onSaved,
}: {
  open: boolean;
  onClose: () => void;
  projectId: string;
  taskId?: string | null;
  taskTitle?: string;
  projectName?: string;
  onSaved: () => void;
}) {
  const { session } = useAuth();
  const [hours, setHours] = useState("");
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const handleSave = async () => {
    const h = parseFloat(hours);
    if (!h || h <= 0 || h > 24) {
      setError("Hours must be between 0 and 24.");
      return;
    }
    const userId = session?.user?.id;
    if (!userId) {
      setError("You must be signed in to log time.");
      return;
    }
    const tenantId = (session.user.user_metadata as { tenant_id?: string })?.tenant_id;
    if (!tenantId) {
      setError("Your account is not associated with a tenant.");
      return;
    }
    setSaving(true);
    setError(null);
    const { error } = await supabase.from("pmo_time_entries").insert({
      project_id: projectId,
      task_id: taskId ?? null,
      tenant_id: tenantId,
      user_id: userId,
      entry_date: date,
      hours: h,
      note: note.trim() || null,
    });
    setSaving(false);
    if (error) { setError(error.message); return; }
    setHours("");
    setNote("");
    onSaved();
    onClose();
  };

  return (
    <Dialog open={open} onClose={() => !saving && onClose()} maxWidth="xs" fullWidth>
      <DialogTitle>Log time{taskTitle ? ` — ${taskTitle}` : projectName ? ` — ${projectName}` : ""}</DialogTitle>
      <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField
          label="Hours *"
          type="number"
          value={hours}
          onChange={(e) => { setHours(e.target.value); setError(null); }}
          fullWidth autoFocus inputProps={{ min: 0.25, max: 24, step: 0.25 }}
          helperText="Costed automatically from your active project allocation rate, if you have one."
        />
        <TextField
          label="Date"
          type="date"
          value={date}
          onChange={(e) => setDate(e.target.value)}
          fullWidth InputLabelProps={{ shrink: true }}
        />
        <TextField label="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} fullWidth multiline minRows={2} placeholder="What did you work on?" />
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={saving}>Cancel</Button>
        <Button variant="contained" onClick={handleSave} disabled={saving || !hours.trim()}>
          {saving ? "Saving…" : "Log time"}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
