import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Switch } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Client { id: string; name: string; }
interface Contact { id: string; tenant_id: string; client_id: string; first_name: string; last_name: string; email: string | null; phone: string | null; position: string | null; is_primary: boolean; created_at: string; bd_clients?: { name: string } | null; }

export default function ContactsList() {
  const { session } = useAuth();
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [clients, setClients] = useState<Client[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Contact | null>(null);
  const [form, setForm] = useState({ client_id: "", first_name: "", last_name: "", email: "", phone: "", position: "", is_primary: false });

  const fetchData = async () => {
    setLoading(true);
    const [contactsRes, clientsRes] = await Promise.all([
      supabase.from("bd_contacts").select("*, bd_clients(name)").order("created_at", { ascending: false }),
      supabase.from("bd_clients").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (contactsRes.data) setContacts(contactsRes.data as Contact[]);
    if (clientsRes.data) setClients(clientsRes.data as Client[]);
    setLoading(false);
  };
  useEffect(() => { fetchData(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ client_id: "", first_name: "", last_name: "", email: "", phone: "", position: "", is_primary: false }); setOpen(true); };
  const handleOpenEdit = (c: Contact) => { setEditing(c); setForm({ client_id: c.client_id, first_name: c.first_name, last_name: c.last_name, email: c.email || "", phone: c.phone || "", position: c.position || "", is_primary: c.is_primary }); setOpen(true); };

  const handleSave = async () => {
    if (!form.client_id || !form.first_name.trim() || !form.last_name.trim()) return;
    const payload: any = { client_id: form.client_id, first_name: form.first_name.trim(), last_name: form.last_name.trim(), email: form.email.trim() || null, phone: form.phone.trim() || null, position: form.position.trim() || null, is_primary: form.is_primary };
    if (editing) {
      const { error } = await supabase.from("bd_contacts").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || contacts[0]?.tenant_id;
      if (tenant_id) payload.tenant_id = tenant_id;
      const { error } = await supabase.from("bd_contacts").insert(payload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete contact?")) return;
    const { error } = await supabase.from("bd_contacts").delete().eq("id", id);
    if (!error) fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Contacts</Typography><Typography variant="body2" color="text.secondary">{contacts.length} contacts linked to clients. Primary contact flagged.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Contact</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Name</TableCell><TableCell>Client</TableCell><TableCell>Position</TableCell><TableCell>Contact</TableCell><TableCell>Primary</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{contacts.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No contacts yet. Create contacts linked to clients.</Typography></TableCell></TableRow> : contacts.map(c => <TableRow key={c.id} hover><TableCell><Typography fontWeight={600}>{c.first_name} {c.last_name}</Typography></TableCell><TableCell>{c.bd_clients?.name || "-"}</TableCell><TableCell>{c.position || "-"}</TableCell><TableCell><Typography variant="body2">{c.email || "-"}</Typography><Typography variant="caption" color="text.secondary">{c.phone || ""}</Typography></TableCell><TableCell>{c.is_primary ? <Chip label="Primary" size="small" color="primary" /> : "-"}</TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(c)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(c.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Contact" : "New Contact"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Client *" value={form.client_id} onChange={e => setForm({ ...form, client_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Client --</MenuItem>{clients.map(cl => <MenuItem key={cl.id} value={cl.id}>{cl.name}</MenuItem>)}</TextField><Box sx={{ display: "flex", gap: 2 }}><TextField label="First Name *" value={form.first_name} onChange={e => setForm({ ...form, first_name: e.target.value })} fullWidth required /><TextField label="Last Name *" value={form.last_name} onChange={e => setForm({ ...form, last_name: e.target.value })} fullWidth required /></Box><TextField label="Position" value={form.position} onChange={e => setForm({ ...form, position: e.target.value })} fullWidth placeholder="CEO, Procurement Manager" /><TextField label="Email" value={form.email} onChange={e => setForm({ ...form, email: e.target.value })} fullWidth /><TextField label="Phone" value={form.phone} onChange={e => setForm({ ...form, phone: e.target.value })} fullWidth /><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_primary} onChange={e => setForm({ ...form, is_primary: e.target.checked })} /><Typography variant="body2">Primary contact for this client</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.client_id || !form.first_name.trim() || !form.last_name.trim()}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
