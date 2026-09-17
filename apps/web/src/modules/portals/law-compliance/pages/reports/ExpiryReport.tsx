import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

interface Contract {
  id: string;
  contract_no: string;
  title: string;
  party_name: string;
  end_date: string | null;
  status: string;
  law_contract_types?: { name: string } | null;
}

export default function ExpiryReport() {
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase
      .from("law_contracts")
      .select("*, law_contract_types(name)")
      .eq("status", "active")
      .not("end_date", "is", null)
      .order("end_date", { ascending: true });

    if (data) setContracts(data as Contract[]);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  const getDaysLeft = (end: string | null) => {
    if (!end) return null;
    const diff = new Date(end).getTime() - new Date().getTime();
    return Math.ceil(diff / (1000 * 60 * 60 * 24));
  };

  const handleExportExcel = () => {
    const rows = contracts.map(c => ({ contract_no: c.contract_no, title: c.title, party: c.party_name, end_date: c.end_date ? new Date(c.end_date).toLocaleDateString() : "-", days_left: getDaysLeft(c.end_date) ?? "-", status: c.status }));
    const cols = [
      { header: "Contract No", accessor: (r: any) => r.contract_no },
      { header: "Title", accessor: (r: any) => r.title },
      { header: "Party", accessor: (r: any) => r.party },
      { header: "End Date", accessor: (r: any) => r.end_date },
      { header: "Days Left", accessor: (r: any) => r.days_left },
    ];
    exportReportToExcel("expiry_report", "Contract Expiry Report", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = contracts.map(c => ({ contract_no: c.contract_no, title: c.title.slice(0, 30), end_date: c.end_date ? new Date(c.end_date).toLocaleDateString() : "-", days_left: String(getDaysLeft(c.end_date) ?? "-") }));
    const cols = [
      { header: "Contract No", accessor: (r: any) => r.contract_no },
      { header: "Title", accessor: (r: any) => r.title },
      { header: "End Date", accessor: (r: any) => r.end_date },
      { header: "Days Left", accessor: (r: any) => r.days_left },
    ];
    exportReportToPdf("expiry_report.pdf", "Contract Expiry Report", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const expiringSoon = contracts.filter(c => {
    const days = getDaysLeft(c.end_date);
    return days !== null && days >= 0 && days <= 30;
  });
  const expired = contracts.filter(c => {
    const days = getDaysLeft(c.end_date);
    return days !== null && days < 0;
  });

  const chartData = [
    { name: "Active OK (>30d)", value: contracts.length - expiringSoon.length - expired.length },
    { name: "Expiring Soon (<30d)", value: expiringSoon.length },
    { name: "Expired", value: expired.length },
  ];

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Contract Expiry Report</Typography><Typography variant="body2" color="text.secondary">Active contracts sorted by expiry. {contracts.length} active • {expiringSoon.length} expiring soon • {expired.length} expired but still active status.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Chip label={`Total Active: ${contracts.length}`} color="primary" />
        <Chip label={`Expiring Soon (<30d): ${expiringSoon.length}`} color="warning" />
        <Chip label={`Expired: ${expired.length}`} color="error" />
      </Box>

      <Card sx={{ mb: 3 }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Expiry Buckets</Typography><Box sx={{ height: 200 }}><ResponsiveContainer width="100%" height="100%"><BarChart data={chartData}><XAxis dataKey="name" tick={{ fontSize: 11 }} /><YAxis /><ReTooltip /><Legend /><Bar dataKey="value" fill="#ed6c02" name="Contracts" /></BarChart></ResponsiveContainer></Box></CardContent></Card>

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Contract No</TableCell><TableCell>Title</TableCell><TableCell>Party</TableCell><TableCell>End Date</TableCell><TableCell>Days Left</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{contracts.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No active contracts with end dates.</Typography></TableCell></TableRow> : contracts.map(c => {
        const days = getDaysLeft(c.end_date);
        const rowColor = days !== null && days < 0 ? "rgba(211,47,47,0.08)" : days !== null && days <= 30 ? "rgba(237,108,2,0.08)" : "transparent";
        return <TableRow key={c.id} hover sx={{ bgcolor: rowColor }}><TableCell><Typography fontFamily="monospace" fontWeight={600}>{c.contract_no}</Typography></TableCell><TableCell>{c.title}</TableCell><TableCell>{c.party_name}</TableCell><TableCell>{c.end_date ? new Date(c.end_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={days !== null ? `${days} days` : "-"} size="small" color={days !== null && days < 0 ? "error" : days !== null && days <= 30 ? "warning" : "success"} /></TableCell><TableCell><Chip label={c.status} size="small" /></TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
