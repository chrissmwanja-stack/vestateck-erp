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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  Chip,
  CircularProgress,
  MenuItem,
  Grid,
} from "@mui/material";
import { Add, Edit, Delete, Business } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface ClientCategory {
  id: string;
  name: string;
}
interface Client {
  id: string;
  tenant_id: string;
  name: string;
  category_id: string | null;
  industry: string | null;
  email: string | null;
  phone: string | null;
  is_active: boolean;
  created_at: string;
  bd_client_categories?: { name: string } | null;
}

export default function ClientsList() {
  const { session } = useAuth();
  const [clients, setClients] = useState<Client[]>([]);
  const [categories, setCategories] = useState<ClientCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Client | null>(null);
  const [form, setForm] = useState({
    name: "",
    category_id: "",
    industry: "",
    email: "",
    phone: "",
    website: "",
    is_active: true,
  });

  const fetchData = async () => {
    setLoading(true);
    const [clientsRes, catsRes] = await Promise.all([
      supabase.from("bd_clients").select("*, bd_client_categories(name)").order("name"),
      supabase.from("bd_client_categories").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (clientsRes.data) setClients(clientsRes.data as Client[]);
    if (catsRes.data) setCategories(catsRes.data as ClientCategory[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleOpenNew = () => {
    setEditing(null);
    setForm({ name: "", category_id: "", industry: "", email: "", phone: "", website: "", is_active: true });
    setOpen(true);
  };

  const handleOpenEdit = (c: Client) => {
    setEditing(c);
    setForm({
      name: c.name,
      category_id: c.category_id || "",
      industry: c.industry || "",
      email: c.email || "",
      phone: c.phone || "",
      website: "",
      is_active: c.is_active,
    });
    setOpen(true);
  };

  const handleSave = async () => {
    if (!form.name.trim()) return;
    const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || clients[0]?.tenant_id;
    const payload: any = {
      name: form.name.trim(),
      category_id: form.category_id || null,
      industry: form.industry.trim() || null,
      email: form.email.trim() || null,
      phone: form.phone.trim() || null,
      website: form.website.trim() || null,
      is_active: form.is_active,
    };
    if (!editing && tenant_id) payload.tenant_id = tenant_id;

    if (editing) {
      const { error } = await supabase.from("bd_clients").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const { error } = await supabase.from("bd_clients").insert(payload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete client? Opportunities linked to this client will block deletion. Deactivate instead?")) return;
    const { error } = await supabase.from("bd_clients").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`);
    else fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Clients</Typography>
          <Typography variant="body2" color="text.secondary">{clients.length} clients. Categories from Admin → Client Categories.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Client</Button>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Industry</TableCell>
                <TableCell>Contact</TableCell>
                <TableCell>Active</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {clients.length === 0 ? (
                <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No clients yet. Create Government, Private, NGO clients. This unblocks New Opportunity form.</Typography></TableCell></TableRow>
              ) : (
                clients.map(c => (
                  <TableRow key={c.id} hover>
                    <TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Business fontSize="small" color="action" /><Typography fontWeight={600}>{c.name}</Typography></Box></TableCell>
                    <TableCell><Chip label={c.bd_client_categories?.name || "Uncategorized"} size="small" variant="outlined" /></TableCell>
                    <TableCell>{c.industry || "-"}</TableCell>
                    <TableCell><Typography variant="body2">{c.email || "-"}</Typography><Typography variant="caption" color="text.secondary">{c.phone || ""}</Typography></TableCell>
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
        <DialogTitle>{editing ? "Edit Client" : "New Client"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          <TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus placeholder="e.g. Ministry of Works" />
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField select label="Category" value={form.category_id} onChange={e => setForm({ ...form, category_id: e.target.value })} fullWidth>
                <MenuItem value="">-- None --</MenuItem>
                {categories.map(cat => <MenuItem key={cat.id} value={cat.id}>{cat.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={6}>
              <TextField label="Industry" value={form.industry} onChange={e => setForm({ ...form, industry: e.target.value })} fullWidth placeholder="Construction, IT, etc." />
            </Grid>
          </Grid>
          <TextField label="Email" value={form.email} onChange={e => setForm({ ...form, email: e.target.value })} fullWidth />
          <TextField label="Phone" value={form.phone} onChange={e => setForm({ ...form, phone: e.target.value })} fullWidth />
          <TextField label="Website" value={form.website} onChange={e => setForm({ ...form, website: e.target.value })} fullWidth />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>{editing ? "Update" : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
