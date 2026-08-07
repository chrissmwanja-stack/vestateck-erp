import { useCallback, useEffect, useState, FormEvent } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  IconButton,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import {
  Search as SearchIcon,
  Clear as ClearIcon,
  ExpandMore as ExpandMoreIcon,
  ExpandLess as ExpandLessIcon,
  Inventory as InventoryIcon,
} from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface RequestRow {
  id: string;
  item_description: string;
  quantity: number;
  delivery_date: string | null;
  subcontractor: string | null;
}

interface LineItemStatus {
  line_item_id: string;
  request_id: string;
  material_service: string;
  ordered_qty: number;
  received_qty: number;
  receipt_status: 'none' | 'partial' | 'full' | 'over';
  last_received_at: string | null;
}

const statusColor: Record<LineItemStatus['receipt_status'], 'default' | 'warning' | 'success' | 'error'> = {
  none: 'default',
  partial: 'warning',
  full: 'success',
  over: 'error',
};

function ReceiveRow({ line, onRecorded }: { line: LineItemStatus; onRecorded: () => void }) {
  const [qty, setQty] = useState('');
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [rowError, setRowError] = useState<string | null>(null);

  async function handleRecord() {
    const parsed = parseFloat(qty);
    if (!parsed || parsed <= 0) {
      setRowError('Enter a quantity greater than 0.');
      return;
    }
    setRowError(null);
    setSaving(true);
    const { error } = await supabase.rpc('record_line_item_receipt', {
      p_line_item_id: line.line_item_id,
      p_received_qty: parsed,
      p_note: note.trim() || null,
    });
    setSaving(false);

    if (error) {
      setRowError(error.message ?? 'Could not record receipt.');
      return;
    }
    setQty('');
    setNote('');
    onRecorded();
  }

  return (
    <TableRow hover>
      <TableCell>{line.material_service}</TableCell>
      <TableCell align="right">{line.ordered_qty}</TableCell>
      <TableCell align="right">{line.received_qty}</TableCell>
      <TableCell>
        <Chip size="small" label={line.receipt_status} color={statusColor[line.receipt_status]} />
      </TableCell>
      <TableCell sx={{ minWidth: 110 }}>
        <TextField
          size="small"
          variant="standard"
          type="number"
          placeholder="Qty"
          inputProps={{ min: 0 }}
          value={qty}
          onChange={(e) => setQty(e.target.value)}
        />
      </TableCell>
      <TableCell sx={{ minWidth: 160 }}>
        <TextField
          size="small"
          variant="standard"
          placeholder="Note (optional)"
          fullWidth
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      </TableCell>
      <TableCell align="right">
        <Button size="small" variant="outlined" disabled={saving} onClick={handleRecord}>
          {saving ? 'Saving…' : 'Record'}
        </Button>
        {rowError && (
          <Typography variant="caption" color="error" display="block" sx={{ mt: 0.5 }}>
            {rowError}
          </Typography>
        )}
      </TableCell>
    </TableRow>
  );
}

function RequestPanel({ request }: { request: RequestRow }) {
  const [open, setOpen] = useState(false);
  const [lines, setLines] = useState<LineItemStatus[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadLines = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: queryError } = await supabase
      .from('line_item_receipt_status')
      .select('line_item_id, request_id, material_service, ordered_qty, received_qty, receipt_status, last_received_at')
      .eq('request_id', request.id);
    setLoading(false);

    if (queryError) {
      setError(queryError.message ?? 'Failed to load line items');
      return;
    }
    setLines((data ?? []) as LineItemStatus[]);
  }, [request.id]);

  function handleToggle() {
    const next = !open;
    setOpen(next);
    if (next && lines.length === 0) loadLines();
  }

  return (
    <Paper variant="outlined" sx={{ mb: 2 }}>
      <Box
        sx={{ p: 2, display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={handleToggle}
      >
        <Box>
          <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
            {request.item_description}
          </Typography>
          <Typography variant="caption" color="text.secondary">
            Total qty {request.quantity}
            {request.subcontractor ? ` • ${request.subcontractor}` : ''}
            {request.delivery_date ? ` • Delivery ${request.delivery_date}` : ''}
          </Typography>
        </Box>
        <IconButton size="small">{open ? <ExpandLessIcon /> : <ExpandMoreIcon />}</IconButton>
      </Box>
      <Collapse in={open} timeout="auto" unmountOnExit>
        <Box sx={{ px: 2, pb: 2 }}>
          {error && <Alert severity="error" sx={{ mb: 1 }}>{error}</Alert>}
          {loading ? (
            <Box sx={{ display: 'flex', justifyContent: 'center', py: 2 }}>
              <CircularProgress size={20} />
            </Box>
          ) : (
            <TableContainer>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Material / Service</TableCell>
                    <TableCell align="right">Ordered</TableCell>
                    <TableCell align="right">Received</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell>Record qty</TableCell>
                    <TableCell>Note</TableCell>
                    <TableCell />
                  </TableRow>
                </TableHead>
                <TableBody>
                  {lines.map((line) => (
                    <ReceiveRow key={line.line_item_id} line={line} onRecorded={loadLines} />
                  ))}
                  {lines.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 2 }}>
                        No line items on this request.
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </TableContainer>
          )}
        </Box>
      </Collapse>
    </Paper>
  );
}

export default function MaterialQuantity() {
  const [query, setQuery] = useState('');
  const [requests, setRequests] = useState<RequestRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const runSearch = useCallback(async (q: string) => {
    setLoading(true);
    setError(null);
    try {
      let dbQuery = supabase
        .from('requests')
        .select('id, item_description, quantity, delivery_date, subcontractor')
        .eq('status', 'closed')
        .order('updated_at', { ascending: false })
        .limit(50);

      if (q.trim()) {
        dbQuery = dbQuery.ilike('item_description', `%${q.trim()}%`);
      }

      const { data, error: queryError } = await dbQuery;
      if (queryError) throw queryError;
      setRequests((data ?? []) as RequestRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load requests');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    runSearch('');
  }, [runSearch]);

  function handleSearchSubmit(e: FormEvent) {
    e.preventDefault();
    runSearch(query);
  }

  function handleClear() {
    setQuery('');
    runSearch('');
  }

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <InventoryIcon /> Material Quantity
        </Typography>
      </Stack>

      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Search closed requests and record what was actually delivered against each line item. Partial and
        over-deliveries are both fine — they're flagged, not blocked.
      </Typography>

      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Box component="form" onSubmit={handleSearchSubmit}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
            <TextField
              label="Search by description"
              size="small"
              sx={{ flex: 1 }}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
            <Button type="submit" variant="contained" startIcon={<SearchIcon />}>
              Search
            </Button>
            <Button variant="outlined" startIcon={<ClearIcon />} onClick={handleClear}>
              Clear
            </Button>
          </Stack>
        </Box>
      </Paper>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
          <CircularProgress size={24} />
        </Box>
      ) : requests.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: 'center', color: 'text.secondary' }}>
          No closed requests found.
        </Paper>
      ) : (
        requests.map((r) => <RequestPanel key={r.id} request={r} />)
      )}
    </Box>
  );
}