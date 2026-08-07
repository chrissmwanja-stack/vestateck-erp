import { useState } from "react";
import {
  Button, Card, CardContent, Typography, Stack, TextField, Alert,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";

interface SubmittedInvoice {
  vendorName: string;
  amount: number;
  stageName: string | null;
}

export default function InvoiceSubmissionForm() {
  const [vendor, setVendor] = useState("");
  const [amount, setAmount] = useState("");
  const [description, setDescription] = useState("");
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState<SubmittedInvoice | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitError(null);

    const parsedAmount = Number(amount);
    if (!vendor.trim() || !amount || Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSubmitError("Vendor and valid amount are required.");
      return;
    }

    setSubmitting(true);
    const { data, error } = await supabase
      .from("invoice_requests")
      .insert({
        vendor_name: vendor.trim(),
        amount: parsedAmount,
        description: description.trim() || null,
      })
      .select("id, vendor_name, amount, current_stage_id, workflow_stages(name)")
      .single();
    setSubmitting(false);

    if (error) {
      setSubmitError(error.message ?? "Could not submit invoice.");
      return;
    }

    setSubmitted({
      vendorName: data.vendor_name,
      amount: Number(data.amount),
      // `workflow_stages` comes back as an array from the embedded select
      // even for a to-one relationship -- take the first row's name.
      stageName: (data as any).workflow_stages?.[0]?.name ?? null,
    });
    setVendor("");
    setAmount("");
    setDescription("");
  };

  if (submitted) {
    return (
      <Card sx={{ maxWidth: 640, mx: "auto", mt: 4 }} variant="outlined">
        <CardContent>
          <Alert severity="success" sx={{ mb: 2 }}>
            Invoice for {submitted.vendorName} ({submitted.amount.toLocaleString()} UGX) submitted.
            {submitted.stageName
              ? ` It's now awaiting approval at the ${submitted.stageName} stage.`
              : " It's now in the approval queue."}
          </Alert>
          <Button variant="outlined" onClick={() => setSubmitted(null)}>
            Submit another invoice
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card sx={{ maxWidth: 640, mx: "auto", mt: 4 }} variant="outlined">
      <CardContent>
        <Typography variant="h6" gutterBottom>Send Invoice for Approval</Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
          Submit an invoice for approval through the Multiplexing workflow.
        </Typography>
        <form onSubmit={handleSubmit}>
          <Stack spacing={2.5}>
            <TextField label="Vendor / Supplier" fullWidth value={vendor} onChange={(e) => setVendor(e.target.value)} />
            <TextField label="Amount (UGX)" type="number" fullWidth value={amount} onChange={(e) => setAmount(e.target.value)} />
            <TextField label="Description" fullWidth multiline minRows={2} value={description} onChange={(e) => setDescription(e.target.value)} />
            {submitError && <Alert severity="error">{submitError}</Alert>}
            <Button type="submit" variant="contained" size="large" disabled={submitting}>
              {submitting ? "Submitting…" : "Submit for Approval"}
            </Button>
          </Stack>
        </form>
      </CardContent>
    </Card>
  );
}