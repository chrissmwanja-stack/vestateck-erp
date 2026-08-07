import { useEffect, useState } from "react";
import {
  Alert,
  Box,
  CircularProgress,
  Dialog,
  DialogContent,
  DialogTitle,
  Grid,
  IconButton,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
} from "@mui/material";
import { Close } from "@mui/icons-material";
import { supabase } from "../../lib/supabaseClient";

// Read-only popup for the "Initial PO #" column on Request Tracking --
// same in-place-dialog pattern as RequestLineItemsDialog (no navigation,
// no new window), just showing the winning offer instead of the raw MR.
// Backed by get_offer_detail(), a SECURITY DEFINER RPC that's tenant-
// scoped only (like get_request_tracking itself) rather than routed
// through request_offers' normal RLS policy, which restricts SELECT to
// the requester or a current-stage actor -- too narrow for someone just
// paging through the tracking report on a request they didn't submit or
// aren't currently assigned to act on.

interface OfferDetailItem {
  id: string;
  material_service: string;
  cost_code: string | null;
  group_code: string | null;
  place_of_use: string | null;
  quantity: number;
  unit_price: number | null;
  total: number | null;
  currency: string;
}

interface OfferDetail {
  request: {
    mr_number: string;
    item_description: string;
    requester_name: string;
    created_at: string;
  } | null;
  offer: {
    id: string;
    vendor_name: string;
    quotation_amount: number;
    quantity: number;
    submitted_at: string;
    submitted_by_name: string | null;
  } | null;
  items: OfferDetailItem[];
}

interface Props {
  open: boolean;
  onClose: () => void;
  requestId: string | null;
  // Passed straight from the tracking row so the header has something to
  // show immediately, before the RPC round-trip resolves.
  initialPoNumber?: string | null;
}

export default function OfferDetailDialog({ open, onClose, requestId, initialPoNumber }: Props) {
  const [detail, setDetail] = useState<OfferDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open || !requestId) {
      setDetail(null);
      setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    supabase
      .rpc("get_offer_detail", { p_request_id: requestId })
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) {
          setError(error.message);
        } else {
          setDetail(data as OfferDetail);
        }
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [open, requestId]);

  return (
    <Dialog open={open} onClose={onClose} fullWidth maxWidth="md">
      <DialogTitle sx={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <span>Offer detail{initialPoNumber ? ` — ${initialPoNumber}` : ""}</span>
        <IconButton size="small" onClick={onClose}>
          <Close fontSize="small" />
        </IconButton>
      </DialogTitle>
      <DialogContent dividers>
        {loading && (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={28} />
          </Box>
        )}

        {error && <Alert severity="error">{error}</Alert>}

        {!loading && !error && detail && !detail.offer && (
          <Alert severity="info">No offer has been recorded for this request yet.</Alert>
        )}

        {!loading && !error && detail?.offer && (
          <>
            <Grid container spacing={2} sx={{ mb: 2 }}>
              <Grid item xs={6} sm={3}>
                <Typography variant="caption" color="text.secondary">MR #</Typography>
                <Typography variant="body2">{detail.request?.mr_number}</Typography>
              </Grid>
              <Grid item xs={6} sm={3}>
                <Typography variant="caption" color="text.secondary">Requester</Typography>
                <Typography variant="body2">{detail.request?.requester_name}</Typography>
              </Grid>
              <Grid item xs={6} sm={3}>
                <Typography variant="caption" color="text.secondary">Firm</Typography>
                <Typography variant="body2">{detail.offer.vendor_name}</Typography>
              </Grid>
              <Grid item xs={6} sm={3}>
                <Typography variant="caption" color="text.secondary">Offer date</Typography>
                <Typography variant="body2">
                  {new Date(detail.offer.submitted_at).toLocaleString()}
                </Typography>
              </Grid>
              <Grid item xs={12}>
                <Typography variant="caption" color="text.secondary">Description</Typography>
                <Typography variant="body2">{detail.request?.item_description}</Typography>
              </Grid>
              <Grid item xs={6} sm={3}>
                <Typography variant="caption" color="text.secondary">Total bid</Typography>
                <Typography variant="body2" fontWeight={600}>
                  {detail.offer.quotation_amount?.toLocaleString()}
                </Typography>
              </Grid>
              {detail.offer.submitted_by_name && (
                <Grid item xs={6} sm={3}>
                  <Typography variant="caption" color="text.secondary">Buyer</Typography>
                  <Typography variant="body2">{detail.offer.submitted_by_name}</Typography>
                </Grid>
              )}
            </Grid>

            <Typography variant="subtitle2" gutterBottom>MR items</Typography>
            <TableContainer>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Material / Service</TableCell>
                    <TableCell align="right">Qty</TableCell>
                    <TableCell align="right">Unit price</TableCell>
                    <TableCell align="right">Total</TableCell>
                    <TableCell>Currency</TableCell>
                    <TableCell>Cost code</TableCell>
                    <TableCell>Place of use</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {detail.items.map((item) => (
                    <TableRow key={item.id}>
                      <TableCell>{item.material_service}</TableCell>
                      <TableCell align="right">{item.quantity}</TableCell>
                      <TableCell align="right">{item.unit_price?.toLocaleString()}</TableCell>
                      <TableCell align="right">{item.total?.toLocaleString()}</TableCell>
                      <TableCell>{item.currency}</TableCell>
                      <TableCell>{item.cost_code}</TableCell>
                      <TableCell>{item.place_of_use}</TableCell>
                    </TableRow>
                  ))}
                  {detail.items.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={7} align="center">
                        <Typography color="text.secondary" sx={{ py: 2 }}>No line items.</Typography>
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </TableContainer>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}