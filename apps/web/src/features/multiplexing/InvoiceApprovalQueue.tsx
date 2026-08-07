import { useCallback, useEffect, useState } from "react";
import {
  Alert, Box, Button, CircularProgress, Paper, Stack,
  Table, TableBody, TableCell, TableContainer, TableHead, TableRow,
  Typography, Chip,
} from "@mui/material";
import { supabase } from "../../lib/supabaseClient";

interface InvoiceQueueRow {
  id: string;
  vendor_name: string | null;
  description: string | null;
  amount: number;
  status: string;
  created_at: string;
  current_stage: { id: string; name: string; approver_role: string; threshold_amount: number | null; is_finance_terminal_stage: boolean } | null;
  acting_on_behalf_of: { id: string; name: string } | null;
}

export default function InvoiceApprovalQueue() {
  const [items, setItems] = useState<InvoiceQueueRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actingId, setActingId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase.rpc("get_my_invoice_approval_queue");
    setLoadError(error ? error.message : null);
    setItems((data ?? []) as InvoiceQueueRow[]);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const handleDecision = async (id: string, decision: "approved" | "rejected") => {
    setActingId(id);
    const { error } = await supabase.rpc("record_invoice_approval_decision", {
      p_invoice_request_id: id,
      p_decision: decision,
    });
    setActingId(null);
    if (error) alert(error.message);
    else load();
  };

  if (loading) return <Box display="flex" justifyContent="center" py={6}><CircularProgress /></Box>;
  if (loadError) return <Alert severity="error">{loadError}</Alert>;

  return (
    <Box sx={{ maxWidth: 1200, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>Pending Invoice Approvals</Typography>
      {items.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: "center" }}>
          <Typography color="text.secondary">No pending invoice approvals.</Typography>
        </Paper>
      ) : (
        <Paper variant="outlined">
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Vendor</TableCell>
                  <TableCell>Description</TableCell>
                  <TableCell align="right">Amount</TableCell>
                  <TableCell>Stage</TableCell>
                  <TableCell>Created</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {items.map((item) => (
                  <TableRow key={item.id} hover>
                    <TableCell>{item.vendor_name || "—"}</TableCell>
                    <TableCell>{item.description || "—"}</TableCell>
                    <TableCell align="right">{Number(item.amount).toLocaleString()} UGX</TableCell>
                    <TableCell>
                      <Stack direction="row" spacing={1} alignItems="center">
                        <Chip size="small" label={item.current_stage?.name ?? "—"} />
                        {item.acting_on_behalf_of && (
                          <Typography variant="caption" color="text.secondary">
                            on behalf of {item.acting_on_behalf_of.name}
                          </Typography>
                        )}
                      </Stack>
                    </TableCell>
                    <TableCell>{new Date(item.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end">
                        <Button
                          size="small"
                          variant="contained"
                          color="success"
                          disabled={actingId === item.id}
                          onClick={() => handleDecision(item.id, "approved")}
                        >
                          Approve
                        </Button>
                        <Button
                          size="small"
                          color="error"
                          disabled={actingId === item.id}
                          onClick={() => handleDecision(item.id, "rejected")}
                        >
                          Reject
                        </Button>
                      </Stack>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
        </Paper>
      )}
    </Box>
  );
}