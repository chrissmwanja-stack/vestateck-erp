import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, IconButton, Tooltip } from "@mui/material";
import { TrendingUp, Download } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

interface Lead {
  id: string;
  lead_no: string;
  company_name: string;
  contact_name: string;
  estimated_value: number | null;
  currency: string;
  created_at: string;
  bd_lead_sources?: { name: string } | null;
}

export default function QualifiedLeads() {
  const navigate = useNavigate();
  const [leads, setLeads] = useState<Lead[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("bd_leads").select("*, bd_lead_sources(name)").eq("status", "qualified").order("created_at", { ascending: false });
      if (data) {
        const normalized = (data as any[]).map((l: any) => ({
          ...l,
          bd_lead_sources: Array.isArray(l.bd_lead_sources) ? l.bd_lead_sources[0] ?? null : l.bd_lead_sources ?? null,
        }));
        setLeads(normalized as Lead[]);
      }
      setLoading(false);
    };
    fetch();
  }, []);

  const handleExportExcel = () => {
    const rows = leads.map(l => ({ lead_no: l.lead_no, company: l.company_name, contact: l.contact_name, source: l.bd_lead_sources?.name || "-", value: l.estimated_value ? Number(l.estimated_value) : 0, currency: l.currency, created: new Date(l.created_at).toLocaleDateString() }));
    const cols = [
      { header: "Lead No", accessor: (r:any) => r.lead_no },
      { header: "Company", accessor: (r:any) => r.company },
      { header: "Contact", accessor: (r:any) => r.contact },
      { header: "Source", accessor: (r:any) => r.source },
      { header: "Value", accessor: (r:any) => r.value },
      { header: "Created", accessor: (r:any) => r.created },
    ];
    exportReportToExcel("qualified_leads", "Qualified Leads", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = leads.map(l => ({ lead_no: l.lead_no, company: l.company_name.slice(0, 20), source: l.bd_lead_sources?.name || "-" }));
    const cols = [
      { header: "Lead No", accessor: (r:any) => r.lead_no },
      { header: "Company", accessor: (r:any) => r.company },
      { header: "Source", accessor: (r:any) => r.source },
    ];
    exportReportToPdf("qualified_leads.pdf", "Qualified Leads", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2, flexWrap: "wrap", gap: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Qualified Leads</Typography><Typography variant="body2" color="text.secondary">Leads with status=qualified. Ready to convert to opportunity. {leads.length} leads.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Lead No</TableCell><TableCell>Company</TableCell><TableCell>Contact</TableCell><TableCell>Source</TableCell><TableCell>Value</TableCell><TableCell align="right">Convert</TableCell></TableRow></TableHead><TableBody>{leads.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No qualified leads yet. Go to Leads list and change status to Qualified.</Typography></TableCell></TableRow> : leads.map(l => <TableRow key={l.id} hover><TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{l.lead_no}</Typography></TableCell><TableCell><Typography fontWeight={600}>{l.company_name}</Typography></TableCell><TableCell>{l.contact_name}</TableCell><TableCell><Chip label={l.bd_lead_sources?.name || "-"} size="small" variant="outlined" /></TableCell><TableCell>{l.estimated_value ? `${l.currency} ${Number(l.estimated_value).toLocaleString()}` : "-"}</TableCell><TableCell align="right"><Tooltip title="Convert to Opportunity"><IconButton size="small" color="primary" aria-label="Convert to opportunity" onClick={() => navigate(`/business-development/opportunities/new?lead_id=${l.id}`)}><TrendingUp fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
