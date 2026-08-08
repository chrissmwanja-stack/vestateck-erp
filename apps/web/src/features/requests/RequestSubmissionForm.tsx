import { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Card,
  CardContent,
  CircularProgress,
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
  IconButton,
} from '@mui/material';
import DeleteOutline from '@mui/icons-material/DeleteOutline';
import AddCircleOutline from '@mui/icons-material/AddCircleOutline';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { supabase } from '../../lib/supabaseClient';
import type { CostCenter } from '@erp-platform/shared';

// Simplified version without Excel, with UGX main currency
const headerSchema = z.object({
  item_description: z.string().min(10, "Describe what's needed"),
  cost_center_id: z.string().min(1, "Pick a cost center"),
  delivery_date: z.string().optional(),
  subcontractor: z.string().optional(),
});

type HeaderFormValues = z.infer<typeof headerSchema>;

interface LineItem {
  key: string;
  materialService: string;
  costCode: string;
  groupCode: string;
  placeOfUse: string;
  quantity: string;
  unitPrice: string;
  currency: string;
}

function emptyLineItem(): LineItem {
  return {
    key: crypto.randomUUID(),
    materialService: "",
    costCode: "",
    groupCode: "",
    placeOfUse: "",
    quantity: "",
    unitPrice: "",
    currency: "UGX",
  };
}

function lineTotal(item: LineItem): number {
  const qty = parseFloat(item.quantity) || 0;
  const price = parseFloat(item.unitPrice) || 0;
  return qty * price;
}

export default function RequestSubmissionForm({ onSubmitted }: { onSubmitted?: (id: string) => void }) {
  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(true);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [lineItems, setLineItems] = useState<LineItem[]>([emptyLineItem()]);

  const {
    control,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<HeaderFormValues>({
    resolver: zodResolver(headerSchema),
    defaultValues: { item_description: "", cost_center_id: "", delivery_date: "", subcontractor: "" },
  });

  useEffect(() => {
    let cancelled = false;
    async function loadCostCenters() {
      const { data, error } = await supabase.from("cost_centers").select("id, tenant_id, name, project_code, budget_amount, created_at").order("name");
      if (!cancelled) {
        if (error) setSubmitError(error.message);
        else setCostCenters(data ?? []);
        setLoadingCostCenters(false);
      }
    }
    loadCostCenters();
    return () => { cancelled = true; };
  }, []);

  const costCenterOptions = useMemo(
    () => costCenters.map((cc) => ({ id: cc.id, label: `${cc.project_code} — ${cc.name}` })),
    [costCenters]
  );

  const updateLineItem = (key: string, patch: Partial<LineItem>) => {
    setLineItems((rows) => rows.map((row) => (row.key === key ? { ...row, ...patch } : row)));
  };

  const addLineItem = () => setLineItems((rows) => [...rows, emptyLineItem()]);
  const removeLineItem = (key: string) => setLineItems((rows) => (rows.length > 1 ? rows.filter((row) => row.key !== key) : rows));

  const onSubmit = async (values: HeaderFormValues) => {
    setSubmitError(null);
    const validRows = lineItems.filter((row) => row.materialService.trim() && parseFloat(row.quantity) > 0);
    if (validRows.length === 0) {
      setSubmitError("Add at least one line item with a description and quantity greater than 0.");
      return;
    }
    const totalQuantity = validRows.reduce((sum, row) => sum + (parseFloat(row.quantity) || 0), 0);
    setSubmitting(true);
    const { data: requestId, error } = await supabase.rpc("submit_request_with_line_items", {
      p_item_description: values.item_description,
      p_quantity: totalQuantity,
      p_cost_center_id: values.cost_center_id,
      p_delivery_date: values.delivery_date || null,
      p_subcontractor: values.subcontractor?.trim() || null,
      p_line_items: validRows.map((row) => ({
        material_service: row.materialService.trim(),
        cost_code: row.costCode.trim() || null,
        group_code: row.groupCode.trim() || null,
        place_of_use: row.placeOfUse.trim() || null,
        quantity: parseFloat(row.quantity),
        unit_price: row.unitPrice ? parseFloat(row.unitPrice) : null,
        total: row.unitPrice ? lineTotal(row) : null,
        currency: row.currency || "UGX",
      })),
    });
    setSubmitting(false);
    if (error) {
      setSubmitError(error.message ?? "Could not submit the request. Try again.");
      return;
    }
    reset();
    setLineItems([emptyLineItem()]);
    if (requestId) onSubmitted?.(requestId as string);
  };

  return (
    <Card sx={{ maxWidth: 900, mx: "auto" }} variant="outlined">
      <CardContent>
        <Typography variant="h6" gutterBottom>New request (UGX main)</Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
          Add line items manually. Currency defaults to UGX per your setting.
        </Typography>
        <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
          <Stack spacing={2.5}>
            <Controller name="item_description" control={control} render={({ field }) => <TextField {...field} label="Description" placeholder="Overall description" error={!!errors.item_description} helperText={errors.item_description?.message} multiline minRows={2} fullWidth />} />
            <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
              <Controller name="cost_center_id" control={control} render={({ field }) => (
                <Autocomplete sx={{ flex: 1 }} options={costCenterOptions} loading={loadingCostCenters} onChange={(_, option) => field.onChange(option?.id ?? "")} value={costCenterOptions.find((o) => o.id === field.value) ?? null} isOptionEqualToValue={(option, value) => option.id === value.id} renderInput={(params) => <TextField {...params} label="Cost center" error={!!errors.cost_center_id} helperText={errors.cost_center_id?.message} InputProps={{ ...params.InputProps, endAdornment: (<>{loadingCostCenters ? <CircularProgress color="inherit" size={16} /> : null}{params.InputProps.endAdornment}</>) }} />} />
              )} />
              <Controller name="delivery_date" control={control} render={({ field }) => <TextField {...field} label="Delivery date" type="date" InputLabelProps={{ shrink: true }} sx={{ flex: 1 }} />} />
            </Stack>
            <Controller name="subcontractor" control={control} render={({ field }) => <TextField {...field} label="Subcontractor (optional)" fullWidth />} />

            <Box>
              <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
                <Typography variant="subtitle2">Line items</Typography>
                <Button size="small" startIcon={<AddCircleOutline fontSize="small" />} onClick={addLineItem}>Add row</Button>
              </Stack>
              <Paper variant="outlined" sx={{ overflow: "auto" }}>
                <TableContainer>
                  <Table size="small">
                    <TableHead>
                      <TableRow>
                        <TableCell sx={{ minWidth: 180 }}>Material / Services</TableCell>
                        <TableCell sx={{ minWidth: 110 }}>Cost Code</TableCell>
                        <TableCell sx={{ minWidth: 110 }}>Group Code</TableCell>
                        <TableCell sx={{ minWidth: 130 }}>Place of use</TableCell>
                        <TableCell align="right" sx={{ minWidth: 90 }}>Qty</TableCell>
                        <TableCell align="right" sx={{ minWidth: 110 }}>Unit Price</TableCell>
                        <TableCell align="right" sx={{ minWidth: 110 }}>Total</TableCell>
                        <TableCell sx={{ minWidth: 90 }}>Currency</TableCell>
                        <TableCell />
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {lineItems.map((row) => (
                        <TableRow key={row.key} hover>
                          <TableCell><TextField size="small" variant="standard" fullWidth value={row.materialService} onChange={(e) => updateLineItem(row.key, { materialService: e.target.value })} /></TableCell>
                          <TableCell><TextField size="small" variant="standard" fullWidth value={row.costCode} onChange={(e) => updateLineItem(row.key, { costCode: e.target.value })} /></TableCell>
                          <TableCell><TextField size="small" variant="standard" fullWidth value={row.groupCode} onChange={(e) => updateLineItem(row.key, { groupCode: e.target.value })} /></TableCell>
                          <TableCell><TextField size="small" variant="standard" fullWidth value={row.placeOfUse} onChange={(e) => updateLineItem(row.key, { placeOfUse: e.target.value })} /></TableCell>
                          <TableCell align="right"><TextField size="small" variant="standard" type="number" inputProps={{ min: 0, style: { textAlign: "right" } }} value={row.quantity} onChange={(e) => updateLineItem(row.key, { quantity: e.target.value })} /></TableCell>
                          <TableCell align="right"><TextField size="small" variant="standard" type="number" inputProps={{ min: 0, style: { textAlign: "right" } }} value={row.unitPrice} onChange={(e) => updateLineItem(row.key, { unitPrice: e.target.value })} /></TableCell>
                          <TableCell align="right">{lineTotal(row) > 0 ? lineTotal(row).toLocaleString() : "—"}</TableCell>
                          <TableCell><TextField size="small" variant="standard" fullWidth value={row.currency} onChange={(e) => updateLineItem(row.key, { currency: e.target.value })} /></TableCell>
                          <TableCell><IconButton size="small" onClick={() => removeLineItem(row.key)} disabled={lineItems.length === 1}><DeleteOutline fontSize="small" /></IconButton></TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </TableContainer>
              </Paper>
            </Box>

            {submitError && <Alert severity="error">{submitError}</Alert>}

            <Button type="submit" variant="contained" size="large" disabled={submitting}>
              {submitting ? "Submitting…" : "Submit request (UGX main)"}
            </Button>
          </Stack>
        </Box>
      </CardContent>
    </Card>
  );
}
