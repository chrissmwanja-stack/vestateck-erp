import { useEffect, useState } from "react";
import { Box, Card, CardContent, Typography, Table, TableHead, TableRow, TableCell, TableBody, Chip, CircularProgress } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Submission {
  id: string;
  tender_no: string | null;
  title: string;
  status: string;
  submission_deadline: string | null;
  estimated_value: number | null;
  currency: string;
  updated_at: string;
  bd_clients?: { name: string } | null;
}

// "Submissions" are tenders that have moved past the draft stage -- there is
// no separate bd_tender_submissions table yet, so this tracks bd_tenders
// whose status is submitted or later, newest activity first.
const SUBMITTED_STATUSES = ["submitted", "under_evaluation", "awarded", "lost"];

export default function SubmissionsList() {
  const [submissions, setSubmissions] = useState<Submission[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchSubmissions = async () => {
      setLoading(true);
      const { data, error } = await supabase
        .from("bd_tenders")
        .select("id, tender_no, title, status, submission_deadline, estimated_value, currency, updated_at, bd_clients(name)")
        .in("status", SUBMITTED_STATUSES)
        .order("updated_at", { ascending: false })
        .limit(200);
      if (error) setError(error.message);
      else setSubmissions((data as any[] || []).map(s => ({ ...s, bd_clients: Array.isArray(s.bd_clients) ? s.bd_clients[0] ?? null : s.bd_clients ?? null })) as Submission[]);
      setLoading(false);
    };
    fetchSubmissions();
  }, []);

  const getStatusColor = (s: string) => {
    if (s === 'awarded') return 'success';
    if (s === 'lost') return 'error';
    if (s === 'submitted' || s === 'under_evaluation') return 'primary';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Tender Submissions</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Tenders that have been submitted and their outcome. Live from the Tenders register ({submissions.length} submitted).
      </Typography>

      {error && <Typography color="error" sx={{ mb: 2 }}>Failed to load submissions: {error}</Typography>}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Tender No</TableCell><TableCell>Title</TableCell><TableCell>Client</TableCell><TableCell>Submission Deadline</TableCell><TableCell>Status</TableCell><TableCell>Value</TableCell><TableCell>Last Activity</TableCell></TableRow></TableHead>
        <TableBody>{submissions.length === 0 ? <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No submissions yet. Mark a tender as Submitted in the Tenders list to see it here.</Typography></TableCell></TableRow> : submissions.map(s => <TableRow key={s.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{s.tender_no || "-"}</Typography></TableCell><TableCell>{s.title}</TableCell><TableCell>{s.bd_clients?.name || "-"}</TableCell><TableCell>{s.submission_deadline ? new Date(s.submission_deadline).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={s.status.replace("_", " ")} size="small" color={getStatusColor(s.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{s.estimated_value ? `${s.currency} ${Number(s.estimated_value).toLocaleString()}` : "-"}</TableCell><TableCell><Typography variant="caption">{new Date(s.updated_at).toLocaleDateString()}</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
