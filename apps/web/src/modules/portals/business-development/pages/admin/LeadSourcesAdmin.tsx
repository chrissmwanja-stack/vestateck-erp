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

interface LeadSource {
  id: string;
  tenant_id: string;
  name: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
}

export default function LeadSourcesAdmin() {
  const { session } = useAuth();
  const [sources, setSources] = useState<LeadSource[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<LeadSource | null>(null);
  const [form, setForm] = useState({ name: "", description: "", is_active: true });

  const fetchSources = async () => {
    setLoading(true);
    // RLS should auto-filter by tenant_id from JWT, but we also select all for admin
    const { data, error } = await supabase
      .from("bd_lead_sources")
      .select("*")
      .order("name", { ascending: true });
    
    if (error) {
      console.error("Error fetching lead sources:", error);
    } else {
      setSources(data as LeadSource[]);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchSources();
  }, []);

  const handleOpenNew = () => {
    setEditing(null);
    setForm({ name: "", description: "", is_active: true });
    setOpen(true);
  };

  const handleOpenEdit = (source: LeadSource) => {
    setEditing(source);
    setForm({ name: source.name, description: source.description || "", is_active: source.is_active });
    setOpen(true);
  };

  const handleSave = async () => {
    if (!form.name.trim()) return;

    // Get tenant_id from session user metadata or from existing profile
    // For now, try to get from auth user - adjust to your actual tenant logic
    // If RLS inserts tenant_id via trigger, you can omit it
    const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || sources[0]?.tenant_id;

    if (editing) {
      const { error } = await supabase
        .from("bd_lead_sources")
        .update({
          name: form.name.trim(),
          description: form.description.trim() || null,
          is_active: form.is_active,
        })
        .eq("id", editing.id);
      
      if (error) {
        alert(`Error updating: ${error.message}`);
        return;
      }
    } else {
      // Insert - if your DB sets tenant_id via default or trigger, this might work without tenant_id
      // If not, you need to provide tenant_id from your appUser table
      const payload: any = {
        name: form.name.trim(),
        description: form.description.trim() || null,
        is_active: form.is_active,
      };
      if (tenant_id) payload.tenant_id = tenant_id;

      const { error } = await supabase.from("bd_lead_sources").insert(payload);
      if (error) {
        alert(`Error creating: ${error.message}\n\nIf tenant_id required, add logic to fetch appUser.tenant_id from your AppUser table like MaterialLookupsAdmin does.`);
        return;
      }
    }

    setOpen(false);
    fetchSources();
  };

  const handleToggleActive = async (source: LeadSource) => {
    const { error } = await supabase
      .from("bd_lead_sources")
      .update({ is_active: !source.is_active })
      .eq("id", source.id);
    if (!error) fetchSources();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete this lead source? If it's used by leads, deletion will fail due to FK.")) return;
    const { error } = await supabase.from("bd_lead_sources").delete().eq("id", id);
    if (error) {
      alert(`Cannot delete: ${error.message}. Consider deactivating instead.`);
    } else {
      fetchSources();
    }
  };

  if (loading) {
    return (
      <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Lead Sources</Typography>
          <Typography variant="body2" color="text.secondary">
            Admin lookup that backs the Source dropdown on New Lead. Same pattern as Material Classification and IT Ticket Categories.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>
          New Source
        </Button>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Description</TableCell>
                <TableCell>Active</TableCell>
                <TableCell>Created</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {sources.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}>
                    <Typography color="text.secondary">No lead sources yet. Create Referral, Website, Tender Portal, Cold Call, etc.</Typography>
                  </TableCell>
                </TableRow>
              ) : (
                sources.map((s) => (
                  <TableRow key={s.id} hover>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600}>{s.name}</Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2" color="text.secondary">{s.description || "-"}</Typography>
                    </TableCell>
                    <TableCell>
                      <Chip label={s.is_active ? "Active" : "Inactive"} size="small" color={s.is_active ? "success" : "default"} />
                    </TableCell>
                    <TableCell>
                      <Typography variant="caption">{new Date(s.created_at).toLocaleDateString()}</Typography>
                    </TableCell>
                    <TableCell align="right">
                      <Tooltip title="Toggle active">
                        <Switch size="small" checked={s.is_active} onChange={() => handleToggleActive(s)} />
                      </Tooltip>
                      <IconButton size="small" onClick={() => handleOpenEdit(s)}><Edit fontSize="small" /></IconButton>
                      <IconButton size="small" onClick={() => handleDelete(s.id)}><Delete fontSize="small" /></IconButton>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Lead Source" : "New Lead Source"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField
            label="Name *"
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="e.g. Referral, Website, Tender Portal"
            fullWidth
            autoFocus
          />
          <TextField
            label="Description"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
            placeholder="Optional description"
            fullWidth
            multiline
            rows={2}
          />
          <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
            <Switch checked={form.is_active} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
            <Typography variant="body2">Active (shows in dropdown)</Typography>
          </Box>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>
            {editing ? "Update" : "Create"}
          </Button>
        </DialogActions>
      </Dialog>

      <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}>
        <Typography variant="caption" fontWeight={600}>Next steps:</Typography>
        <Typography variant="caption" component="div" color="text.secondary">
          <ol style={{ margin: "4px 0", paddingLeft: "18px" }}>
            <li>Run `supabase/migrations/0004_business_development_schema.sql` in Supabase (creates bd_lead_sources table + RLS)</li>
            <li>Create a few sources: Referral, Website, Cold Call, Tender Portal, Exhibition</li>
            <li>Next we build New Lead form — Source dropdown will now have values (currently empty like your Material Classification was)</li>
            <li>Then Opportunity Stages Admin — drives Pipeline Board weighted forecast</li>
          </ol>
        </Typography>
      </Box>
    </Box>
  );
}
