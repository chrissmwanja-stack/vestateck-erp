import { useEffect, useState } from "react";
import {
  Dialog, DialogTitle, DialogContent, IconButton, Table, TableBody, TableCell,
  TableHead, TableRow, Box, Typography, CircularProgress,
} from "@mui/material";
import CloseIcon from "@mui/icons-material/Close";
import { supabase } from "../../lib/supabaseClient";

interface LineItem {
  material_service: string;
  cost_code: string | null;
  place_of_use: string | null;
  quantity: number;
  unit_price: number | null;
  total: number | null;
  currency: string;
}

interface RequestDetailHeader {
  mrNumber: string;
  title: string;
  requesterName: string;
  // Full timestamp (requests.created_at). Optional so existing callers
  // that haven't been updated yet still compile; the Date cell is
  // omitted when this isn't supplied.
  mrCreatedAt?: string | null;
  // Request-level delivery date (requests.delivery_date). There is no
  // per-line delivery date in the schema, so this is shown once in the
  // header rather than repeated on every row.
  deliveryDate?: string | null;
}

interface RequestLineItemsDialogProps {
  open: boolean;
  onClose: () => void;
  requestId: string | null;
  header: RequestDetailHeader | null;
}

function formatDateTime(value?: string | null): string {
  if (!value) return "—";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "—";
  const date = d.toLocaleDateString(undefined, { year: "numeric", month: "numeric", day: "numeric" });
  const time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" });
  return `${date} ${time}`;
}

function formatDate(value?: string | null): string {
  if (!value) return "—";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleDateString(undefined, { year: "numeric", month: "numeric", day: "numeric" });
}

// Read-only detail dialog used by RequestTracking.tsx (and, once wired
// up there too, ProcurementInfo.tsx). Clicking an MR # opens this
// instead of navigating to a separate page. Fetches only the line items
// for the given request_id -- the header info is passed in directly
// from the row the caller already has via its own RPC.
//
// Header is styled as a banner-style detail table (label cell + bold
// colored value cell) rather than a plain MUI DialogTitle block, to
// give it the weight of a formal document. Fields shown are all backed
// by real columns:
//   - MR #            requests.mr_number
//   - Requester        requests.requester_id -> app_users.name
//     (labeled "Requester" rather than "MR Originator": the schema has
//     no field distinct from the requester that means "who created
//     this MR" -- see note in RequestTracking.tsx / ProcurementInfo.tsx)
//   - Date              requests.created_at (full timestamp)
//   - Delivery Date      requests.delivery_date (request-level only --
//     there is no per-line delivery date in request_line_items)
//   - Description        requests.item_description
export default function RequestLineItemsDialog({ open, onClose, requestId, header }: RequestLineItemsDialogProps) {
  const [items, setItems] = useState<LineItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open || !requestId) return;
    setLoading(true);
    setError(null);
    supabase
      .from("request_line_items")
      .select("material_service, cost_code, place_of_use, quantity, unit_price, total, currency")
      .eq("request_id", requestId)
      .then(({ data, error }) => {
        if (error) setError(error.message);
        setItems((data ?? []) as LineItem[]);
        setLoading(false);
      });
  }, [open, requestId]);

  return (
    <Dialog open={open} onClose={onClose} maxWidth="md" fullWidth>
      <DialogTitle
        sx={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          bgcolor: "primary.main",
          color: "primary.contrastText",
        }}
      >
        DETAILED REQUEST
        <IconButton size="small" onClick={onClose} sx={{ color: "inherit" }}>
          <CloseIcon fontSize="small" />
        </IconButton>
      </DialogTitle>

      <DialogContent sx={{ p: 0 }}>
        {header && (
          <Table
            size="small"
            sx={{
              "& td": { border: "1px solid", borderColor: "divider", verticalAlign: "top" },
              mb: 0,
            }}
          >
            <TableBody>
              <TableRow>
                <TableCell sx={{ bgcolor: "grey.100", fontWeight: 700, width: 140 }}>MR #</TableCell>
                <TableCell sx={{ color: "primary.dark", fontWeight: 700 }}>{header.mrNumber}</TableCell>
                <TableCell sx={{ bgcolor: "grey.100", fontWeight: 700, width: 140 }}>Requester</TableCell>
                <TableCell sx={{ color: "primary.dark", fontWeight: 700 }}>{header.requesterName}</TableCell>
              </TableRow>
              <TableRow>
                <TableCell sx={{ bgcolor: "grey.100", fontWeight: 700 }}>Date</TableCell>
                <TableCell sx={{ color: "primary.dark", fontWeight: 700 }}>
                  {formatDateTime(header.mrCreatedAt)}
                </TableCell>
                <TableCell sx={{ bgcolor: "grey.100", fontWeight: 700 }}>Delivery Date</TableCell>
                <TableCell sx={{ color: "primary.dark", fontWeight: 700 }}>
                  {formatDate(header.deliveryDate)}
                </TableCell>
              </TableRow>
              <TableRow>
                <TableCell sx={{ bgcolor: "grey.100", fontWeight: 700 }}>Description</TableCell>
                <TableCell colSpan={3} sx={{ color: "primary.dark", fontWeight: 700 }}>
                  {header.title}
                </TableCell>
              </TableRow>
            </TableBody>
          </Table>
        )}

        <Box sx={{ p: 2 }}>
          {loading && (
            <Box sx={{ display: "flex", justifyContent: "center", py: 4 }}>
              <CircularProgress />
            </Box>
          )}

          {error && <Typography color="error">{error}</Typography>}

          {!loading && !error && (
            <Table size="small">
              <TableHead>
                <TableRow sx={{ "& th": { bgcolor: "primary.main", color: "primary.contrastText", fontWeight: 700 } }}>
                  <TableCell>Material / Service</TableCell>
                  <TableCell>Cost Code</TableCell>
                  <TableCell>Place of Use</TableCell>
                  <TableCell align="right">Qty</TableCell>
                  <TableCell align="right">Unit Price</TableCell>
                  <TableCell align="right">Total</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {items.map((li, i) => (
                  <TableRow key={i} sx={{ "&:nth-of-type(odd)": { bgcolor: "grey.50" } }}>
                    <TableCell>{li.material_service}</TableCell>
                    <TableCell>{li.cost_code}</TableCell>
                    <TableCell>{li.place_of_use}</TableCell>
                    <TableCell align="right">{li.quantity}</TableCell>
                    <TableCell align="right">
                      {li.unit_price?.toLocaleString()} {li.currency}
                    </TableCell>
                    <TableCell align="right">
                      {li.total?.toLocaleString()} {li.currency}
                    </TableCell>
                  </TableRow>
                ))}
                {items.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={6} align="center">
                      <Typography color="text.secondary" sx={{ py: 2 }}>
                        No line items.
                      </Typography>
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          )}
        </Box>
      </DialogContent>
    </Dialog>
  );
}