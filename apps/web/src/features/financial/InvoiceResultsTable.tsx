import { Box, Button, Chip, CircularProgress, Paper, Table, TableBody, TableCell, TableContainer, TableHead, TableRow, Typography, Alert } from "@mui/material";
import { Edit as EditIcon } from "@mui/icons-material";

export interface UnifiedInvoiceRow {
  id: string;
  source: "supplier" | "receivable";
  invoice_number: string;
  invoice_date: string;
  account_id: string | null;
  account_label: string;
  amount_incl_vat: number;
  vat_amount: number;
  currency: string;
  description: string | null;
  status: string | null;
  invoice_type: string | null;
  cost_center_id: string | null;
  organization_id: string | null;
  organization_label: string;
  prf_oif_number: string;
}

export function InvoiceResultsTable({
  rows,
  loading,
  error,
  onEdit,
}: {
  rows: UnifiedInvoiceRow[];
  loading: boolean;
  error: string | null;
  onEdit: (row: UnifiedInvoiceRow) => void;
}) {
  return (
    <Paper sx={{ p: 2 }} variant="outlined">
      <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
        Items
      </Typography>
      {error && <Alert severity="error">{error}</Alert>}
      {loading ? (
        <Box sx={{ display: "flex", justifyContent: "center", py: 4 }}>
          <CircularProgress size={24} />
        </Box>
      ) : (
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Source</TableCell>
                <TableCell>Organization</TableCell>
                <TableCell>PRF / OIF No</TableCell>
                <TableCell>Invoice No</TableCell>
                <TableCell>Account</TableCell>
                <TableCell>Date</TableCell>
                <TableCell align="right">Amount (incl. VAT)</TableCell>
                <TableCell>Currency</TableCell>
                <TableCell>Status / Type</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={`${row.source}-${row.id}`} hover>
                  <TableCell>
                    <Chip size="small" label={row.source === "supplier" ? "Supplier" : "Receivable"} color={row.source === "supplier" ? "default" : "info"} />
                  </TableCell>
                  <TableCell>{row.organization_label}</TableCell>
                  <TableCell>{row.prf_oif_number}</TableCell>
                  <TableCell>{row.invoice_number}</TableCell>
                  <TableCell>{row.account_label}</TableCell>
                  <TableCell>{row.invoice_date}</TableCell>
                  <TableCell align="right">{row.amount_incl_vat.toLocaleString()}</TableCell>
                  <TableCell>{row.currency}</TableCell>
                  <TableCell>
                    {row.source === "receivable" ? (
                      <Chip size="small" label={row.status} color={row.status === "paid" ? "success" : "default"} />
                    ) : (
                      <Chip size="small" label={row.invoice_type === "po_related" ? "PO Related" : "Non-PO"} />
                    )}
                  </TableCell>
                  <TableCell align="right">
                    <Button size="small" startIcon={<EditIcon />} onClick={() => onEdit(row)}>
                      Edit
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              {rows.length === 0 && (
                <TableRow>
                  <TableCell colSpan={10} align="center" sx={{ color: "text.secondary", py: 3 }}>
                    No invoices found.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Paper>
  );
}
