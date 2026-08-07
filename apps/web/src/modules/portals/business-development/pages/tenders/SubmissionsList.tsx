import { Box, Card, CardContent, Typography, Table, TableHead, TableRow, TableCell, TableBody, Chip } from "@mui/material";

const MOCK_SUBMISSIONS = [
  { id: "1", tender_no: "T-2025-001", title: "Classroom Construction", client: "Ministry of Education", submission_date: "2026-01-15", status: "submitted", value: "USD 120,000" },
  { id: "2", tender_no: "T-2025-002", title: "IT Equipment Supply", client: "URA", submission_date: "2026-02-01", status: "under_evaluation", value: "USD 85,000" },
  { id: "3", tender_no: "T-2025-003", title: "Office Furniture", client: "NSSF", submission_date: "2025-12-20", status: "awarded", value: "USD 45,000" },
];

export default function SubmissionsList() {
  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Tender Submissions</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Track submitted tenders, evaluation status, awarded/lost outcome. Link to proposal.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Tender No</TableCell><TableCell>Title</TableCell><TableCell>Client</TableCell><TableCell>Submission Date</TableCell><TableCell>Status</TableCell><TableCell>Value</TableCell></TableRow></TableHead><TableBody>{MOCK_SUBMISSIONS.map(s => <TableRow key={s.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{s.tender_no}</Typography></TableCell><TableCell>{s.title}</TableCell><TableCell>{s.client}</TableCell><TableCell>{s.submission_date}</TableCell><TableCell><Chip label={s.status} size="small" color={s.status === "awarded" ? "success" : s.status === "under_evaluation" ? "primary" : "default"} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{s.value}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}><Typography variant="caption">Real implementation needs bd_tender_submissions table (id, tender_id, proposal_id, submission_date, status, documents). For now static mock. Next: create table + link to bd_proposals + file upload.</Typography></Box>
    </Box>
  );
}
