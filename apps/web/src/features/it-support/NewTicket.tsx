import { useState } from "react";
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  MenuItem,
  Stack,
  TextField,
  Typography,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";

// New Ticket -- Service Operations.
//
// Simple status pipeline (open -> in_progress -> resolved -> closed), not
// a multi-stage approval chain like procurement requests. Anyone can file
// a ticket; it_tickets_insert RLS requires requester_id = auth.uid(). The
// requester's department_id is read from their own app_users row via a
// direct select rather than asked on the form, mirroring how requests.ts
// derives department context from the signed-in user rather than a
// dropdown.

const CATEGORIES = ["Hardware", "Software", "Network", "Access", "Other"] as const;
const PRIORITIES = ["low", "medium", "high", "urgent"] as const;

interface SubmittedTicket {
  ticket_number: string;
  subject: string;
}

export default function NewTicket() {
  const [subject, setSubject] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState<(typeof CATEGORIES)[number] | "">("");
  const [priority, setPriority] = useState<(typeof PRIORITIES)[number]>("medium");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState<SubmittedTicket | null>(null);

  const reset = () => {
    setSubject("");
    setDescription("");
    setCategory("");
    setPriority("medium");
    setError(null);
  };

  const handleSubmit = async () => {
    setError(null);

    if (subject.trim().length < 5) {
      setError("Give the ticket a subject (at least 5 characters).");
      return;
    }
    if (description.trim().length < 10) {
      setError("Describe the issue in a bit more detail.");
      return;
    }
    if (!category) {
      setError("Pick a category.");
      return;
    }

    setSubmitting(true);

    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      setSubmitting(false);
      setError("You need to be signed in to submit a ticket.");
      return;
    }

    // department_id and tenant_id are pulled from the requester's own
    // app_users row -- RLS on it_tickets already requires
    // tenant_id = get_my_tenant_id(), this just fills in what the insert
    // needs rather than exposing it as a form field.
    const { data: profile, error: profileError } = await supabase
      .from("app_users")
      .select("tenant_id, department_id")
      .eq("id", user.id)
      .single();

    if (profileError || !profile?.department_id) {
      setSubmitting(false);
      setError(
        profileError?.message ??
          "Your account isn't assigned to a department, so a ticket can't be filed. Contact an admin."
      );
      return;
    }

    const { data, error: insertError } = await supabase
      .from("it_tickets")
      .insert({
        tenant_id: profile.tenant_id,
        requester_id: user.id,
        department_id: profile.department_id,
        subject: subject.trim(),
        description: description.trim(),
        category,
        priority,
      })
      .select("ticket_number, subject")
      .single();

    setSubmitting(false);

    if (insertError) {
      setError(insertError.message ?? "Could not submit the ticket. Try again.");
      return;
    }

    setSubmitted(data as SubmittedTicket);
    reset();
  };

  if (submitted) {
    return (
      <Card sx={{ maxWidth: 640, mx: "auto" }} variant="outlined">
        <CardContent>
          <Alert severity="success" sx={{ mb: 2 }}>
            Ticket {submitted.ticket_number} submitted -- "{submitted.subject}". IT Support has been
            notified.
          </Alert>
          <Button variant="outlined" onClick={() => setSubmitted(null)}>
            Submit another ticket
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card sx={{ maxWidth: 640, mx: "auto" }} variant="outlined">
      <CardContent>
        <Typography variant="h6" gutterBottom>
          New ticket
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
          Describe the issue. IT Support will pick it up and update the status as they work it.
        </Typography>

        <Box component="form" noValidate>
          <Stack spacing={2.5}>
            <TextField
              label="Subject"
              placeholder="Short summary of the issue"
              value={subject}
              onChange={(e) => setSubject(e.target.value)}
              fullWidth
            />
            <TextField
              select
              label="Category"
              value={category}
              onChange={(e) => setCategory(e.target.value as (typeof CATEGORIES)[number])}
              fullWidth
            >
              {CATEGORIES.map((c) => (
                <MenuItem key={c} value={c}>
                  {c}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              select
              label="Priority"
              value={priority}
              onChange={(e) => setPriority(e.target.value as (typeof PRIORITIES)[number])}
              fullWidth
              helperText="How urgent this is for you -- IT Support may adjust it."
            >
              {PRIORITIES.map((p) => (
                <MenuItem key={p} value={p}>
                  {p.charAt(0).toUpperCase() + p.slice(1)}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              label="Description"
              placeholder="What's happening, what you've already tried, error messages, etc."
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              multiline
              minRows={4}
              fullWidth
            />

            {error && <Alert severity="error">{error}</Alert>}

            <Button
              variant="contained"
              size="large"
              onClick={handleSubmit}
              disabled={submitting}
            >
              {submitting ? "Submitting…" : "Submit ticket"}
            </Button>
          </Stack>
        </Box>
      </CardContent>
    </Card>
  );
}