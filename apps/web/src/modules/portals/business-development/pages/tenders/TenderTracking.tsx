import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

interface Tender { id: string; tender_no: string; title: string; status: string; submission_deadline: string | null; bd_clients?: { name: string } | null; }

export default function TenderTracking() {
  const [tenders, setTenders] = useState<Tender[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("bd_tenders").select("*, bd_clients(name)").order("submission_deadline", { ascending: true }).limit(200);
      if (data) {
        const normalized = (data as any[]).map((t: any) => ({
          ...t,
          bd_clients: Array.isArray(t.bd_clients) ? t.bd_clients[0] ?? null : t.bd_clients ?? null,
        }));
        setTenders(normalized as Tender[]);
      }
      setLoading(false);
    };
    fetch();
  }, []);

  const getDaysLeft = (deadline: string | null) => {
    if (!deadline) return null;
    const diff = new Date(deadline).getTime() - new Date().getTime();
    return Math.ceil(diff / (1000 * 60 * 60 * 24));
  };

  const handleExportExcel = () => {
    const rows = tenders.map(t => ({ tender_no: t.tender_no || "-", title: t.title, client: t.bd_clients?.name || "-", deadline: t.submission_deadline ? new Date(t.submission_deadline).toLocaleDateString() : "-", days_left: getDaysLeft(t.submission_deadline) ?? "-", status: t.status }));
    const cols = [
      { header: "Tender No", accessor: (r:any) => r.tender_no },
      { header: "Title", accessor: (r:any) => r.title },
      { header: "Client", accessor: (r:any) => r.client },
      { header: "Deadline", accessor: (r:any) => r.deadline },
      { header: "Days Left", accessor: (r:any) => r.days_left },
      { header: "Status", accessor: (r:any) => r.status },
    ];
    exportReportToExcel("tender_tracking", "Tender Tracking", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = tenders.map(t => ({ tender_no: t.tender_no || "-", title: t.title.slice(0, 25), deadline: t.submission_deadline ? new Date(t.submission_deadline).toLocaleDateString() : "-", status: t.status }));
    const cols = [
      { header: "Tender No", accessor: (r:any) => r.tender_no },
      { header: "Title", accessor: (r:any) => r.title },
      { header: "Deadline", accessor: (r:any) => r.deadline },
      { header: "Status", accessor: (r:any) => r.status },
    ];
    exportReportToPdf("tender_tracking.pdf", "Tender Tracking", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3, flexWrap: "wrap", gap: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Tender Tracking</Typography><Typography variant="body2" color="text.secondary">Calendar view of submission deadlines — highlights overdue (&lt;0) and due soon (&lt;3 days).</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>
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
