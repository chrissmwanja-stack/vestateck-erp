import { Box, Typography, Button } from "@mui/material";
import { UploadFile } from "@mui/icons-material";
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import BulkImportDialog, { BulkImportConfig } from "../../../../../components/bulk-import/BulkImportDialog";

// lead_no is trigger-generated (generate_bd_lead_no) -- never set it from CSV.
// source_id is resolved from bd_lead_sources.name, matching how the source
// selector works elsewhere in BD (source is a lookup, not a free string).
const bulkImportConfig: BulkImportConfig = {
  table: "bd_leads",
  entityLabel: "Leads",
  dedupeColumn: "email",
  columns: [
    { key: "company_name", label: "Company", required: true },
    { key: "contact_name", label: "Contact", required: true },
    { key: "email", label: "Email" },
    { key: "phone", label: "Phone" },
    { key: "estimated_value", label: "Value" },
    { key: "currency", label: "Currency" },
    { key: "notes", label: "Notes" },
    { key: "status", label: "Status", enumValues: ["new", "contacted", "qualified", "unqualified", "converted", "lost"] },
  ],
  lookups: [
    { csvColumn: "source", table: "bd_lead_sources", matchColumn: "name", payloadKey: "source_id", label: "Source" },
  ],
  sampleRowValues: ["Acme Corp", "John Doe", "john@acme.com", "+256700000000", "50000", "UGX", "Referral from exhibition", "new", "Referral"],
  buildPayload: (row, resolved, tenant_id) => ({
    tenant_id,
    company_name: row.company_name,
    contact_name: row.contact_name,
    email: row.email || null,
    phone: row.phone || null,
    source_id: resolved.source_id || null,
    status: row.status ? row.status.toLowerCase() : "new",
    estimated_value: row.estimated_value ? Number(row.estimated_value) : null,
    currency: row.currency || "UGX",
    notes: row.notes || null,
  }),
};

export default function ImportLeads() {
  const navigate = useNavigate();
  const [open, setOpen] = useState(true);

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Import Leads</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Bulk import leads from a CSV into bd_leads. The full file is validated and imported row by row -- not just a preview.
      </Typography>

      <Button variant="contained" startIcon={<UploadFile />} onClick={() => setOpen(true)}>
        Open Bulk Import
      </Button>

      <BulkImportDialog
        open={open}
        onClose={() => { setOpen(false); navigate("/business-development/leads"); }}
        onImported={() => {}}
        config={bulkImportConfig}
      />
    </Box>
  );
}
