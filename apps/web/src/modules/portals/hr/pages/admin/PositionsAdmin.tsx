import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, Chip, CircularProgress, Alert, Stack } from "@mui/material";
import { Add, Edit, Delete, UploadFile } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { resolveTenantId } from "../../../../../lib/ResolveTenantId";
import { useAuth } from "../../../../../lib/authContext";

interface Position {
  id: string;
  tenant_id: string;
  title: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
}

interface ParsedRow {
  title: string;
  description: string | null;
  is_active: boolean;
}

// Splits a CSV line respecting quoted commas, e.g. "Site Engineer, Civil",...
function splitCsvLine(line: string): string[] {
  const cells: string[] = [];
  let current = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') { current += '"'; i++; }
      else inQuotes = !inQuotes;
    } else if (char === "," && !inQuotes) {
      cells.push(current); current = "";
    } else current += char;
  }
  cells.push(current);
  return cells.map((c) => c.trim());
}

function parsePositionsCsv(text: string): ParsedRow[] {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
  if (lines.length === 0) return [];
  const looksLikeHeader = /^title$/i.test(splitCsvLine(lines[0])[0] || "");
  const dataLines = looksLikeHeader ? lines.slice(1) : lines;
  return dataLines
    .map((line) => splitCsvLine(line))
    .filter((cells) => (cells[0] || "").trim().length > 0)
    .map((cells) => ({
      title: cells[0].trim(),
      description: (cells[1] || "").trim() || null,
      is_active: (cells[2] || "").trim() === "" ? true : /^(true|1|yes|active)$/i.test(cells[2].trim()),
    }));
}

export default function PositionsAdmin() {
  const { session } = useAuth();
  const [positions, setPositions] = useState<Position[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Position | null>(null);
  const [form, setForm] = useState({ title: "", description: "", is_active: true });

  const [importOpen, setImportOpen] = useState(false);
  const [importText, setImportText] = useState("");
  const [importing, setImporting] = useState(false);
  const [importResult, setImportResult] = useState<{ created: number; skipped: string[] } | null>(null);
  const [importError, setImportError] = useState<string | null>(null);

  const fetchPositions = async () => {
    setLoading(true);
    const { data } = await supabase.from("hr_positions").select("*").order("title");
    if (data) setPositions(data as Position[]);
    setLoading(false);
  };

  useEffect(() => { fetchPositions(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ title: "", description: "", is_active: true }); setOpen(true); };
  const handleOpenEdit = (p: Position) => { setEditing(p); setForm({ title: p.title, description: p.description || "", is_active: p.is_active }); setOpen(true); };

  const handleSave = async () => {
    if (!form.title.trim()) return;
    const payload = { title: form.title.trim(), description: form.description.trim() || null, is_active: form.is_active };
    if (editing) {
      const { error } = await supabase.from("hr_positions").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) { alert(tenantResult.error); return; }
      const insertPayload: any = { ...payload, tenant_id: tenantResult.tenantId };
      const { error } = await supabase.from("hr_positions").insert(insertPayload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetchPositions();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete position? Employees using it will block deletion.")) return;
    const { error } = await supabase.from("hr_positions").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`); else fetchPositions();
  };

  const handleOpenImport = () => { setImportText(""); setImportResult(null); setImportError(null); setImportOpen(true); };

  const handleFilePick = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => setImportText(String(reader.result || ""));
    reader.readAsText(file);
  };

  const handleImport = async () => {
    setImportError(null);
    const rows = parsePositionsCsv(importText);
    if (rows.length === 0) { setImportError("No rows found. Expected columns: title, description, is_active."); return; }

    setImporting(true);
    const existingTitles = new Set(positions.map((p) => p.title.trim().toLowerCase()));
    const skipped: string[] = [];
    const toInsert: { title: string; description: string | null; is_active: boolean; tenant_id: string }[] = [];
    const tenantResult = await resolveTenantId(session);
    const tenant_id = tenantResult.ok ? tenantResult.tenantId : null;

    if (!tenant_id) {
      setImporting(false);
      setImportError(tenantResult.ok ? "Could not determine your organization. Please refresh and try again." : tenantResult.error);
      return;
    }

    for (const row of rows) {
      const key = row.title.toLowerCase();
      if (existingTitles.has(key)) { skipped.push(`${row.title} (already exists)`); continue; }
      existingTitles.add(key); // dedupe within the file itself too
      toInsert.push({ ...row, tenant_id });
    }

    if (toInsert.length > 0) {
      const { error } = await supabase.from("hr_positions").insert(toInsert);
      if (error) { setImporting(false); setImportError(error.message); return; }
    }

    setImporting(false);
    setImportResult({ created: toInsert.length, skipped });
    fetchPositions();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Positions</Typography>
          <Typography variant="body2" color="text.secondary">Job titles / positions lookup. Backs Position dropdown on New Employee.</Typography>
        </Box>
        <Stack direction="row" spacing={1}>
          <Button variant="outlined" startIcon={<UploadFile />} onClick={handleOpenImport}>Bulk Import</Button>
          <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Position</Button>
        </Stack>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Description</TableCell><TableCell>Active</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{positions.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No positions yet. Create CEO, Project Manager, Engineer, Accountant, etc.</Typography></TableCell></TableRow> : positions.map(p => <TableRow key={p.id} hover><TableCell><Typography fontWeight={600}>{p.title}</Typography></TableCell><TableCell><Typography variant="body2" color="text.secondary">{p.description || "-"}</Typography></TableCell><TableCell><Chip label={p.is_active ? "Active" : "Inactive"} size="small" color={p.is_active ? "success" : "default"} /></TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(p)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(p.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Position" : "New Position"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus placeholder="e.g. Project Manager, Site Engineer" /><TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={2} /><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} /><Typography variant="body2">Active</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.title.trim()}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>

      <Dialog open={importOpen} onClose={() => setImportOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Bulk Import Positions</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <Typography variant="body2" color="text.secondary">
            CSV with columns <code>title, description, is_active</code> (header row optional; description and is_active are optional, is_active defaults to true).
          </Typography>
          <Button component="label" variant="outlined" startIcon={<UploadFile />} sx={{ alignSelf: "flex-start" }}>
            Choose CSV file
            <input type="file" accept=".csv,text/csv" hidden onChange={handleFilePick} />
          </Button>
          <TextField
            label="Or paste CSV here"
            value={importText}
            onChange={(e) => setImportText(e.target.value)}
            fullWidth
            multiline
            rows={8}
            placeholder={"title,description,is_active\nProject Manager,Oversees site delivery,true\nSite Engineer,,true\nAccountant,,true"}
          />
          {importError && <Alert severity="error">{importError}</Alert>}
          {importResult && (
            <Alert severity={importResult.skipped.length > 0 ? "warning" : "success"}>
              Created {importResult.created} position{importResult.created === 1 ? "" : "s"}.
              {importResult.skipped.length > 0 && (
                <> Skipped {importResult.skipped.length}: {importResult.skipped.join(", ")}</>
              )}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setImportOpen(false)}>Close</Button>
          <Button variant="contained" onClick={handleImport} disabled={importing || !importText.trim()}>
            {importing ? "Importing…" : "Import"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}