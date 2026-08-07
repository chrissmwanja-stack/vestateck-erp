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
  CircularProgress,
} from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface ClientCategory {
  id: string;
  tenant_id: string;
  name: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
}

export default function ClientCategoriesAdmin() {
  const { session } = useAuth();
  const [cats, setCats] = useState<ClientCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<ClientCategory | null>(null);
  const [form, setForm] = useState({ name: "", description: "", is_active: true });

  const fetchCats = async () => {
    setLoading(true);
    const { data, error } = await supabase.from("bd_client_categories").select("*").order("name");
    if (!error) setCats(data as ClientCategory[]);
    setLoading(false);
  };

  useEffect(() => { fetchCats(); }, []);

  const handleOpenNew = () => {
    setEditing(null);
    setForm({ name: "", description: "", is_active: true });
    setOpen(true);
  };

  const handleOpenEdit = (c: ClientCategory) => {
    setEditing(c);
    setForm({ name: c.name, description: c.description || "", is_active: c.is_active });
    setOpen(true);
  };

  const handleSave = async () => {
    if (!form.name.trim()) return;
    const payload = {
      name: form.name.trim(),
      description: form.description.trim() || null,
      is_active: form.is_active,
    };
    if (editing) {
      const { error } = await supabase.from("bd_client_categories").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || cats[0]?.tenant_id;
      const insertPayload: any = { ...payload };
      if (tenant_id) insertPayload.tenant_id = tenant_id;
      const { error } = await supabase.from("bd_client_categories").insert(insertPayload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false);
    fetchCats();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete? Clients using this category will have it cleared. Consider deactivating instead.")) return;
    const { error } = await supabase.from("bd_client_categories").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`);
    else fetchCats();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Client Categories</Typography>
          <Typography variant="body2" color="text.secondary">Backs Category dropdown on New Client. e.g. Government, Private, NGO, International.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Category</Button>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Description</TableCell>
                <TableCell>Active</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {cats.length === 0 ? (
                <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No categories yet. Create Government, Private Sector, NGO, Parastatal, International.</Typography></TableCell></TableRow>
              ) : (
                cats.map(c => (
                  <TableRow key={c.id} hover>
                    <TableCell><Typography variant="body2" fontWeight={600}>{c.name}</Typography></TableCell>
                    <TableCell><Typography variant="body2" color="text.secondary">{c.description || "-"}</Typography></TableCell>
                    <TableCell><Chip label={c.is_active ? "Active" : "Inactive"} size="small" color={c.is_active ? "success" : "default"} /></TableCell>
                    <TableCell align="right">
                      <IconButton size="small" onClick={() => handleOpenEdit(c)}><Edit fontSize="small" /></IconButton>
                      <IconButton size="small" onClick={() => handleDelete(c.id)}><Delete fontSize="small" /></IconButton>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Category" : "New Category"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus placeholder="e.g. Government, Private Sector, NGO" />
          <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={2} />
          <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
            <Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} />
            <Typography variant="body2">Active</Typography>
          </Box>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>{editing ? "Update" : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
