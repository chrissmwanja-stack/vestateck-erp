import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Typography, Table, TableHead, TableRow, TableCell, TableBody, Chip, CircularProgress, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

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
        .limit(300);
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

  const handleExportExcel = () => {
    const rows = submissions.map(s => ({ tender_no: s.tender_no || "-", title: s.title, client: s.bd_clients?.name || "-", deadline: s.submission_deadline ? new Date(s.submission_deadline).toLocaleDateString() : "-", status: s.status, value: s.estimated_value ? Number(s.estimated_value) : 0, updated: new Date(s.updated_at).toLocaleDateString() }));
    const cols = [
      { header: "Tender No", accessor: (r:any) => r.tender_no },
      { header: "Title", accessor: (r:any) => r.title },
      { header: "Client", accessor: (r:any) => r.client },
      { header: "Deadline", accessor: (r:any) => r.deadline },
      { header: "Status", accessor: (r:any) => r.status },
      { header: "Value", accessor: (r:any) => r.value },
      { header: "Updated", accessor: (r:any) => r.updated },
    ];
    exportReportToExcel("tender_submissions", "Tender Submissions", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = submissions.map(s => ({ tender_no: s.tender_no || "-", title: s.title.slice(0,25), status: s.status }));
    const cols = [
      { header: "Tender No", accessor: (r:any) => r.tender_no },
      { header: "Title", accessor: (r:any) => r.title },
      { header: "Status", accessor: (r:any) => r.status },
    ];
    exportReportToPdf("tender_submissions.pdf", "Tender Submissions", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3, flexWrap: "wrap", gap: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Tender Submissions</Typography><Typography variant="body2" color="text.secondary">Submitted tenders and outcomes — live from Tenders register ({submissions.length} submitted).</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      {error && <Typography color="error" sx={{ mb: 2 }}>Failed to load submissions: {error}</Typography>}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Tender No</TableCell><TableCell>Title</TableCell><TableCell>Client</TableCell><TableCell>Submission Deadline</TableCell><TableCell>Status</TableCell><TableCell>Value</TableCell><TableCell>Last Activity</TableCell></TableRow></TableHead>
        <TableBody>{submissions.length === 0 ? <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No submissions yet. Mark a tender as Submitted in the Tenders list to see it here.</Typography></TableCell></TableRow> : submissions.map(s => <TableRow key={s.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{s.tender_no || "-"}</Typography></TableCell><TableCell>{s.title}</TableCell><TableCell>{s.bd_clients?.name || "-"}</TableCell><TableCell>{s.submission_deadline ? new Date(s.submission_deadline).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={s.status.replace("_", " ")} size="small" color={getStatusColor(s.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{s.estimated_value ? `${s.currency} ${Number(s.estimated_value).toLocaleString()}` : "-"}</TableCell><TableCell><Typography variant="caption">{new Date(s.updated_at).toLocaleDateString()}</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
