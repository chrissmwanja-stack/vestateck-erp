import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

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

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const expiringSoon = contracts.filter(c => {
    const days = getDaysLeft(c.end_date);
    return days !== null && days >= 0 && days <= 30;
  });
  const expired = contracts.filter(c => {
    const days = getDaysLeft(c.end_date);
    return days !== null && days < 0;
  });

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Contract Expiry Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Active contracts sorted by expiry. Expiring soon &lt;30 days highlighted, expired red. {contracts.length} active contracts.
      </Typography>

      <Box sx={{ display: "flex", gap: 2, mb: 3 }}>
        <Chip label={`Total Active: ${contracts.length}`} />
        <Chip label={`Expiring Soon (<30d): ${expiringSoon.length}`} color="warning" />
        <Chip label={`Expired: ${expired.length}`} color="error" />
      </Box>

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Contract No</TableCell><TableCell>Title</TableCell><TableCell>Party</TableCell><TableCell>Type</TableCell><TableCell>End Date</TableCell><TableCell>Days Left</TableCell></TableRow></TableHead><TableBody>{contracts.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No active contracts with end dates. Create contracts with end dates to see expiry report.</Typography></TableCell></TableRow> : contracts.map(c => {
        const daysLeft = getDaysLeft(c.end_date);
        return (
          <TableRow key={c.id} hover sx={{ bgcolor: daysLeft !== null && daysLeft < 0 ? "error.light" : daysLeft !== null && daysLeft <= 30 ? "warning.light" : "inherit" }}>
            <TableCell><Typography fontFamily="monospace" fontWeight={600}>{c.contract_no}</Typography></TableCell>
            <TableCell>{c.title}</TableCell>
            <TableCell>{c.party_name}</TableCell>
            <TableCell>{c.law_contract_types?.name || "-"}</TableCell>
            <TableCell>{c.end_date ? new Date(c.end_date).toLocaleDateString() : "-"}</TableCell>
            <TableCell>{daysLeft === null ? "-" : daysLeft < 0 ? <Chip label={`${Math.abs(daysLeft)} days overdue`} size="small" color="error" /> : daysLeft === 0 ? <Chip label="Expires today" size="small" color="warning" /> : <Chip label={`${daysLeft} days left`} size="small" color={daysLeft <= 30 ? "warning" : "default"} />}</TableCell>
          </TableRow>
        );
      })}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
