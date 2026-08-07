
import { Box, Button, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography, Chip } from "@mui/material";
import { Add } from "@mui/icons-material";

const MOCK_TEMPLATES = [
  { id: "1", name: "Standard Technical Proposal", description: "Scope, methodology, deliverables, timeline", placeholders: ["{{client_name}}", "{{project_title}}", "{{scope}}", "{{timeline}}"] },
  { id: "2", name: "Financial Proposal", description: "BOQ, rates, total, payment terms", placeholders: ["{{client_name}}", "{{total_value}}", "{{currency}}", "{{valid_until}}"] },
  { id: "3", name: "Combined Proposal", description: "Technical + Financial combined", placeholders: ["{{client_name}}", "{{scope}}", "{{total_value}}", "{{valid_until}}"] },
];

export default function ProposalTemplates() {
  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Proposal Templates</Typography><Typography variant="body2" color="text.secondary">Reusable templates with placeholders. When creating proposal, content auto-fills from template + opportunity/client data.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} disabled>New Template</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Name</TableCell><TableCell>Description</TableCell><TableCell>Placeholders</TableCell><TableCell>Usage</TableCell></TableRow></TableHead><TableBody>{MOCK_TEMPLATES.map(t => <TableRow key={t.id} hover><TableCell><Typography fontWeight={600}>{t.name}</Typography></TableCell><TableCell>{t.description}</TableCell><TableCell><Box sx={{ display: "flex", gap: 0.5, flexWrap: "wrap" }}>{t.placeholders.map(ph => <Chip key={ph} label={ph} size="small" variant="outlined" sx={{ fontFamily: "monospace", fontSize: 11 }} />)}</Box></TableCell><TableCell><Typography variant="caption">Used in {Math.floor(Math.random()*10)} proposals</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}><Typography variant="caption">Real implementation needs bd_proposal_templates table (id, tenant_id, name, content markdown with placeholders, is_active). For now static list. Next step: create table + CRUD similar to Lead Sources.</Typography></Box>
    </Box>
  );
}
