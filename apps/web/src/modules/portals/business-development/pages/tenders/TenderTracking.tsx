import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Tender { id: string; tender_no: string; title: string; status: string; submission_deadline: string | null; bd_clients?: { name: string } | null; }

export default function TenderTracking() {
  const [tenders, setTenders] = useState<Tender[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("bd_tenders").select("*, bd_clients(name)").order("submission_deadline", { ascending: true }).limit(100);
      if (data) setTenders(data as Tender[]);
      setLoading(false);
    };
    fetch();
  }, []);

  const getDaysLeft = (deadline: string | null) => {
    if (!deadline) return null;
    const diff = new Date(deadline).getTime() - new Date().getTime();
    return Math.ceil(diff / (1000 * 60 * 60 * 24));
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Tender Tracking</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Calendar view of submission deadlines, tracking days left, status. Highlights overdue and due soon (&lt;3 days).</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Tender No</TableCell><TableCell>Title</TableCell><TableCell>Client</TableCell><TableCell>Deadline</TableCell><TableCell>Days Left</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{tenders.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No tenders to track. Create via New Tender.</Typography></TableCell></TableRow> : tenders.map(t => {
        const daysLeft = getDaysLeft(t.submission_deadline);
        return (
          <TableRow key={t.id} hover sx={{ bgcolor: daysLeft !== null && daysLeft < 0 ? "error.light" : daysLeft !== null && daysLeft <= 3 ? "warning.light" : "inherit" }}>
            <TableCell><Typography fontFamily="monospace" fontWeight={600}>{t.tender_no || "-"}</Typography></TableCell>
            <TableCell>{t.title}</TableCell>
            <TableCell>{t.bd_clients?.name || "-"}</TableCell>
            <TableCell>{t.submission_deadline ? new Date(t.submission_deadline).toLocaleDateString() : "-"}</TableCell>
            <TableCell>{daysLeft === null ? "-" : daysLeft < 0 ? <Chip label={`${Math.abs(daysLeft)} days overdue`} size="small" color="error" /> : daysLeft === 0 ? <Chip label="Due today" size="small" color="warning" /> : <Chip label={`${daysLeft} days left`} size="small" color={daysLeft <= 3 ? "warning" : "default"} />}</TableCell>
            <TableCell><Chip label={t.status} size="small" sx={{ textTransform: "capitalize" }} /></TableCell>
          </TableRow>
        );
      })}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
