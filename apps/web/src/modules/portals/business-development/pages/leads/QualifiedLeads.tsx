import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, IconButton, Tooltip } from "@mui/material";
import { TrendingUp } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";

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
      if (data) setLeads(data as Lead[]);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Qualified Leads</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Leads with status=qualified. Ready to convert to opportunity. {leads.length} leads.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Lead No</TableCell><TableCell>Company</TableCell><TableCell>Contact</TableCell><TableCell>Source</TableCell><TableCell>Value</TableCell><TableCell align="right">Convert</TableCell></TableRow></TableHead><TableBody>{leads.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No qualified leads yet. Go to Leads list and change status to Qualified.</Typography></TableCell></TableRow> : leads.map(l => <TableRow key={l.id} hover><TableCell><Typography fontFamily="monospace" variant="body2" fontWeight={600}>{l.lead_no}</Typography></TableCell><TableCell><Typography fontWeight={600}>{l.company_name}</Typography></TableCell><TableCell>{l.contact_name}</TableCell><TableCell><Chip label={l.bd_lead_sources?.name || "-"} size="small" variant="outlined" /></TableCell><TableCell>{l.estimated_value ? `${l.currency} ${Number(l.estimated_value).toLocaleString()}` : "-"}</TableCell><TableCell align="right"><Tooltip title="Convert to Opportunity"><IconButton size="small" color="primary" onClick={() => navigate(`/business-development/opportunities/new?lead_id=${l.id}`)}><TrendingUp fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
