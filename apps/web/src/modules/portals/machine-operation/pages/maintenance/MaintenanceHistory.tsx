import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

export default function MaintenanceHistory() {
  const [history, setHistory] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchData = async () => {
    setLoading(true);
    const { data } = await supabase.from("maintenance_requests").select("*, machines(name, machine_no)").eq("status", "completed").order("updated_at", { ascending: false }).limit(300);
    if (data) {
      const normalized = (data as any[]).map((r: any) => ({
        ...r,
        machines: Array.isArray(r.machines) ? r.machines[0] ?? null : r.machines ?? null,
      }));
      setHistory(normalized);
    }
    setLoading(false);
  };
  useEffect(() => { fetchData(); }, []);

  const handleExportExcel = () => {
    const rows = history.map(h => ({ machine: h.machines ? `${h.machines.machine_no} - ${h.machines.name}` : h.machine_id, type: h.type, completed_date: h.updated_at ? new Date(h.updated_at).toLocaleDateString() : "-", status: h.status, description: h.description || "-" }));
    const cols = [
      { header: "Machine", accessor: (r: any) => r.machine },
      { header: "Type", accessor: (r: any) => r.type },
      { header: "Completed", accessor: (r: any) => r.completed_date },
      { header: "Status", accessor: (r: any) => r.status },
      { header: "Description", accessor: (r: any) => r.description },
    ];
    exportReportToExcel("maintenance_history", "Maintenance History", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = history.map(h => ({ machine: h.machines ? `${h.machines.machine_no} - ${h.machines.name}` : h.machine_id, type: h.type, completed_date: h.updated_at ? new Date(h.updated_at).toLocaleDateString() : "-", status: h.status }));
    const cols = [
      { header: "Machine", accessor: (r: any) => r.machine },
      { header: "Type", accessor: (r: any) => r.type },
      { header: "Completed", accessor: (r: any) => r.completed_date },
      { header: "Status", accessor: (r: any) => r.status },
    ];
    exportReportToPdf("maintenance_history.pdf", "Maintenance History", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Maintenance History</Typography><Typography variant="body2" color="text.secondary">{history.length} completed • Audit trail for preventive/corrective work.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Completed Date</TableCell><TableCell>Description</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{history.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No history yet. Completed maintenance requests appear here.</Typography></TableCell></TableRow> : history.map(h => <TableRow key={h.id} hover><TableCell>{h.machines ? `${h.machines.machine_no} - ${h.machines.name}` : "-"}</TableCell><TableCell sx={{ textTransform: "capitalize" }}>{h.type}</TableCell><TableCell>{h.updated_at ? new Date(h.updated_at).toLocaleDateString() : "-"}</TableCell><TableCell><Typography variant="body2" sx={{ maxWidth: 400, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{h.description || "-"}</Typography></TableCell><TableCell><Chip label={h.status} size="small" color="success" /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
