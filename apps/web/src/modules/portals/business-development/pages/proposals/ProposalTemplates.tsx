import { useEffect, useState } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  Chip,
  Tooltip,
  CircularProgress,
} from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface ProposalTemplate {
  id: string;
  tenant_id: string;
  name: string;
  description: string | null;
  content: string | null;
  is_active: boolean;
  created_at: string;
}

// Placeholders are whatever {{token}} strings appear in the content --
// no separate column, matches how bd_proposals.content is free-form too.
const extractPlaceholders = (content: string | null): string[] => {
  if (!content) return [];
  const matches = content.match(/\{\{\s*[\w.]+\s*\}\}/g) || [];
  return Array.from(new Set(matches));
};

export default function ProposalTemplates() {
  const { session } = useAuth();
  const [templates, setTemplates] = useState<ProposalTemplate[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<ProposalTemplate | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", description: "", content: "", is_active: true });

  const fetchTemplates = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("bd_proposal_templates")
      .select("*")
      .order("name", { ascending: true });
    if (error) {
      console.error("Error fetching proposal templates:", error);
    } else {
      setTemplates(data as ProposalTemplate[]);
    }
    setLoading(false);
  };

  useEffect(() => { fetchTemplates(); }, []);

  const handleOpenNew = () => {
    setEditing(null);
    setError(null);
    setForm({ name: "", description: "", content: "", is_active: true });
    setOpen(true);
  };

  const handleOpenEdit = (t: ProposalTemplate) => {
    setEditing(t);
    setError(null);
    setForm({ name: t.name, description: t.description || "", content: t.content || "", is_active: t.is_active });
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.name.trim()) { setError("Template name is required."); return; }

    if (editing) {
      const { error: updateError } = await supabase
        .from("bd_proposal_templates")
        .update({
          name: form.name.trim(),
          description: form.description.trim() || null,
          content: form.content.trim() || null,
          is_active: form.is_active,
        })
        .eq("id", editing.id);
      if (updateError) { setError(updateError.message); return; }
    } else {
      // tenant_id is read from the signed-in user's own app_users row,
      // same pattern used in NewTicket.tsx and MaintenanceRequests.tsx.
      const { data: { user } } = await supabase.auth.getUser();
      let tenant_id = (session?.user?.user_metadata as any)?.tenant_id;
      if (user && !tenant_id) {
        const { data: profile } = await supabase.from("app_users").select("tenant_id").eq("id", user.id).single();
        tenant_id = profile?.tenant_id;
      }
      const payload: any = {
        name: form.name.trim(),
        description: form.description.trim() || null,
        content: form.content.trim() || null,
        is_active: form.is_active,
      };
      if (tenant_id) payload.tenant_id = tenant_id;

      const { error: insertError } = await supabase.from("bd_proposal_templates").insert(payload);
      if (insertError) { setError(insertError.message); return; }
    }

    setOpen(false);
    fetchTemplates();
  };

  const handleToggleActive = async (t: ProposalTemplate) => {
    const { error } = await supabase.from("bd_proposal_templates").update({ is_active: !t.is_active }).eq("id", t.id);
    if (!error) fetchTemplates();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete this template?")) return;
    const { error } = await supabase.from("bd_proposal_templates").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`);
    else fetchTemplates();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Proposal Templates</Typography>
          <Typography variant="body2" color="text.secondary">
            Reusable templates with {"{{placeholder}}"} tokens. When creating a proposal, content can be filled in from a template plus opportunity/client data.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Template</Button>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Description</TableCell>
                <TableCell>Placeholders</TableCell>
                <TableCell>Active</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {templates.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}>
                    <Typography color="text.secondary">No templates yet. Create Standard Technical, Financial, or Combined proposal templates.</Typography>
                  </TableCell>
                </TableRow>
              ) : (
                templates.map((t) => (
                  <TableRow key={t.id} hover>
                    <TableCell><Typography variant="body2" fontWeight={600}>{t.name}</Typography></TableCell>
                    <TableCell><Typography variant="body2" color="text.secondary">{t.description || "-"}</Typography></TableCell>
                    <TableCell>
                      <Box sx={{ display: "flex", gap: 0.5, flexWrap: "wrap" }}>
                        {extractPlaceholders(t.content).map((ph) => (
                          <Chip key={ph} label={ph} size="small" variant="outlined" sx={{ fontFamily: "monospace", fontSize: 11 }} />
                        ))}
                        {extractPlaceholders(t.content).length === 0 && <Typography variant="caption" color="text.secondary">-</Typography>}
                      </Box>
                    </TableCell>
                    <TableCell>
                      <Tooltip title="Toggle active">
                        <Switch size="small" checked={t.is_active} onChange={() => handleToggleActive(t)} />
                      </Tooltip>
                    </TableCell>
                    <TableCell align="right">
                      <IconButton size="small" onClick={() => handleOpenEdit(t)}><Edit fontSize="small" /></IconButton>
                      <IconButton size="small" onClick={() => handleDelete(t.id)}><Delete fontSize="small" /></IconButton>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Template" : "New Template"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Typography color="error" variant="body2">{error}</Typography>}
          <TextField
            label="Name *"
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="e.g. Standard Technical Proposal"
            fullWidth
            autoFocus
          />
          <TextField
            label="Description"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
            placeholder="e.g. Scope, methodology, deliverables, timeline"
            fullWidth
          />
          <TextField
            label="Content"
            value={form.content}
            onChange={(e) => setForm({ ...form, content: e.target.value })}
            placeholder={"Use {{client_name}}, {{project_title}}, {{scope}}, {{timeline}} as placeholders..."}
            fullWidth
            multiline
            minRows={6}
          />
          <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
            <Switch checked={form.is_active} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
            <Typography variant="body2">Active (available when creating a proposal)</Typography>
          </Box>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>
            {editing ? "Update" : "Create"}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}