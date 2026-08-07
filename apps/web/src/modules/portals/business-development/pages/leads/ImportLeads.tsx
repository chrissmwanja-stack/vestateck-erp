import { useState, useEffect } from "react";
import { Box, Button, Card, CardContent, Typography, Alert, Table, TableBody, TableCell, TableHead, TableRow, CircularProgress, Chip } from "@mui/material";
import { UploadFile } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface LeadSource { id: string; name: string; }

export default function ImportLeads() {
  const { session } = useAuth();
  const [sources, setSources] = useState<LeadSource[]>([]);
  const [preview, setPreview] = useState<any[]>([]);
  const [importing, setImporting] = useState(false);
  const [result, setResult] = useState<string | null>(null);

  useEffect(() => {
    supabase.from("bd_lead_sources").select("id, name").eq("is_active", true).then(({ data }) => { if (data) setSources(data as LeadSource[]); });
  }, []);

  const handleFile = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
      const text = ev.target?.result as string;
      const lines = text.split("\n").filter(l => l.trim());
      const header = lines[0].split(",").map(h => h.trim().toLowerCase());
      const rows = lines.slice(1).map(line => {
        const vals = line.split(",").map(v => v.trim());
        const obj: any = {};
        header.forEach((h, i) => obj[h] = vals[i] || "");
        return obj;
      });
      setPreview(rows.slice(0, 10)); // preview first 10
    };
    reader.readAsText(file);
  };

  const handleImport = async () => {
    if (preview.length === 0) return;
    setImporting(true);
    const { data: tenantData } = await supabase.from("bd_lead_sources").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;
    
    let success = 0;
    for (const row of preview) {
      const payload: any = {
        company_name: row.company_name || row.company || "Unknown",
        contact_name: row.contact_name || row.contact || "Unknown",
        email: row.email || null,
        phone: row.phone || null,
        source_id: sources[0]?.id,
        status: "new",
        estimated_value: row.estimated_value ? parseFloat(row.estimated_value) : null,
        currency: row.currency || "USD",
        notes: row.notes || "Imported via CSV",
        created_by: session?.user?.id,
      };
      if (tenant_id) payload.tenant_id = tenant_id;
      const { error } = await supabase.from("bd_leads").insert(payload);
      if (!error) success++;
    }
    setResult(`Imported ${success} of ${preview.length} leads from preview. Full import would process entire file.`);
    setImporting(false);
  };

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Import Leads</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Upload CSV with headers: company_name, contact_name, email, phone, estimated_value, currency, notes. Maps to bd_leads table.</Typography>

      <Card sx={{ mb: 3 }}>
        <CardContent>
          <Typography variant="subtitle2" gutterBottom>Expected CSV Format:</Typography>
          <Box component="pre" sx={{ bgcolor: "grey.100", p: 1, borderRadius: 1, fontSize: 12, overflow: "auto" }}>
            company_name,contact_name,email,phone,estimated_value,currency,notes
            Acme Corp,John Doe,john@acme.com,+256700000000,50000,USD,Referral from exhibition
          </Box>
          <Button variant="contained" component="label" startIcon={<UploadFile />} sx={{ mt: 2 }}>
            Upload CSV
            <input type="file" accept=".csv" hidden onChange={handleFile} />
          </Button>
          <Chip label={`${sources.length} active sources (first used for import)`} size="small" sx={{ ml: 2 }} />
        </CardContent>
      </Card>

      {preview.length > 0 && (
        <Card sx={{ mb: 2 }}>
          <CardContent sx={{ p: 0 }}>
            <Box sx={{ p: 2, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <Typography variant="subtitle2">Preview first 10 rows</Typography>
              <Button variant="contained" onClick={handleImport} disabled={importing}>{importing ? <><CircularProgress size={18} sx={{ mr: 1 }} /> Importing...</> : `Import ${preview.length} preview rows`}</Button>
            </Box>
            <Table size="small"><TableHead><TableRow><TableCell>Company</TableCell><TableCell>Contact</TableCell><TableCell>Email</TableCell><TableCell>Value</TableCell></TableRow></TableHead><TableBody>{preview.map((r, i) => <TableRow key={i}><TableCell>{r.company_name || r.company}</TableCell><TableCell>{r.contact_name || r.contact}</TableCell><TableCell>{r.email}</TableCell><TableCell>{r.estimated_value}</TableCell></TableRow>)}</TableBody></Table>
          </CardContent>
        </Card>
      )}

      {result && <Alert severity="success">{result}</Alert>}

      <Alert severity="info" sx={{ mt: 3 }}>Full production version would: validate duplicates by email/company, map source by name, show import log, support XLSX, and process all rows not just preview.</Alert>
    </Box>
  );
}
