import { useEffect, useMemo, useState, useCallback } from "react";
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Card,
  CardContent,
  CircularProgress,
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
} from "@mui/material";
import OpenInNew from "@mui/icons-material/OpenInNew";
import DeleteOutline from "@mui/icons-material/DeleteOutline";
import AddCircleOutline from "@mui/icons-material/AddCircleOutline";
import { useForm, Controller } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { supabase } from "../../lib/supabaseClient";
import type { CostCenter } from "@erp-platform/shared";

// Note: install with npm install xlsx

const headerSchema = z.object({
  item_description: z.string().min(10, "Describe what's needed"),
  cost_center_id: z.string().min(1, "Pick a cost center"),
  delivery_date: z.string().optional(),
  subcontractor: z.string().optional(),
});

type HeaderFormValues = z.infer<typeof headerSchema>;

// Minimal structural type for the two xlsx APIs actually used below.
// xlsx doesn't export clean ESM types for this dynamic-import pattern,
// but typing just this surface (rather than `any`) still catches
// misuse at the call sites in handleFileUpload.
interface XlsxLike {
  read: (data: ArrayBuffer, opts: { type: "array" }) => {
    Sheets: Record<string, unknown>;
    SheetNames: string[];
  };
  utils: {
    sheet_to_json: (sheet: unknown, opts: { header: 1 }) => unknown[][];
  };
}

interface LineItem {
  key: string; // client-side only, for React keys / row identity before save
  materialService: string;
  costCode: string;
  groupCode: string;
  placeOfUse: string;
  quantity: string; // kept as string while editing, parsed on submit
  unitPrice: string;
  currency: string;
}

interface SubmittedRequest {
  description: string;
  totalQuantity: number;
  costCenterLabel: string;
  lineItemCount: number;
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

export default function RequestSubmissionFormWithExcel({ onSubmitted }: { onSubmitted?: (id: string) => void }) {
  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(true);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [parseError, setParseError] = useState<string | null>(null);
  const [fileName, setFileName] = useState<string | null>(null);
  const [lineItems, setLineItems] = useState<LineItem[]>([emptyLineItem()]);
  const [submittedInfo, setSubmittedInfo] = useState<SubmittedRequest | null>(null);

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

  const removeLineItem = (key: string) =>
    setLineItems((rows) => (rows.length > 1 ? rows.filter((row) => row.key !== key) : rows));

  // Excel parser — browser-side with xlsx library. Every parsed row now
  // becomes an editable line item, not just the first one.
  const handleFileUpload = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
    setParseError(null);
    const file = event.target.files?.[0];
    if (!file) return;

    if (!file.name.endsWith(".xlsx") && !file.name.endsWith(".xls")) {
      setParseError("Please upload a .xlsx or .xls file.");
      return;
    }

    setFileName(file.name);

    try {
      // xlsx ships without first-class ESM types for this dynamic-import
      // pattern; typing just the two functions actually used here (rather
      // than `any`) still gives real safety on the call sites below.
      const XLSXModule = await import("xlsx");
      const XLSX = ((XLSXModule as { default?: XlsxLike }).default ?? XLSXModule) as XlsxLike;

      const data = await file.arrayBuffer();
      const workbook = XLSX.read(data, { type: "array" });
      const sheet = workbook.Sheets[workbook.SheetNames[0]];
      const json = XLSX.utils.sheet_to_json(sheet, { header: 1 }) as unknown[][];

      if (!json || json.length < 2) {
        setParseError("File appears empty or missing headers.");
        return;
      }

      // Assume first row is header; map by column index.
      // NOTE: this is position-based, not header-name-based — a reordered
      // vendor template will silently misassign columns. Flagged for a
      // follow-up (map by header text instead) but left as-is here.
      const rows: LineItem[] = [];
      for (let i = 1; i < json.length; i++) {
        const r = json[i] as (string | number)[];
        if (!r || r.every((c) => c === undefined || c === null || String(c).trim() === "")) continue;
        const qty = typeof r[4] === "number" ? r[4] : parseFloat(String(r[4] || "0"));
        const unitPrice = typeof r[5] === "number" ? r[5] : parseFloat(String(r[5] || "0"));
        rows.push({
          key: crypto.randomUUID(),
          materialService: String(r[0] ?? ""),
          costCode: String(r[1] ?? ""),
          groupCode: String(r[2] ?? ""),
          placeOfUse: String(r[3] ?? ""),
          quantity: Number.isFinite(qty) && qty > 0 ? String(qty) : "",
          unitPrice: Number.isFinite(unitPrice) && unitPrice > 0 ? String(unitPrice) : "",
          currency: String(r[7] || "UGX"),
        });
      }

      if (rows.length === 0) {
        setParseError("No data rows found.");
        return;
      }

      setLineItems(rows);
      setParseError(null);
    } catch (e) {
      setParseError("Failed to parse Excel file: " + (e instanceof Error ? e.message : "Unknown error"));
    }
  }, []);

  const onSubmit = async (values: HeaderFormValues) => {
    setSubmitError(null);

    const validRows = lineItems.filter((row) => row.materialService.trim() && parseFloat(row.quantity) > 0);
    if (validRows.length === 0) {
      setSubmitError("Add at least one line item with a description and quantity greater than 0.");
      return;
    }

    const totalQuantity = validRows.reduce((sum, row) => sum + (parseFloat(row.quantity) || 0), 0);

    setSubmitting(true);

    // Single RPC call: submit_request_with_line_items() inserts the parent
    // request and all line items inside one server-side transaction. If
    // any line item fails validation, the whole thing rolls back — no
    // orphaned request with missing detail rows. set_request_defaults()
    // still fills tenant_id, requester_id, status, department_id, and
    // starting workflow stage server-side, same as before.
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

    const costCenterLabel =
      costCenterOptions.find((o) => o.id === values.cost_center_id)?.label ?? "—";

    setSubmittedInfo({
      description: values.item_description,
      totalQuantity,
      costCenterLabel,
      lineItemCount: validRows.length,
    });

    reset();
    setLineItems([emptyLineItem()]);
    setFileName(null);
    if (requestId) onSubmitted?.(requestId as string);
    // No redirect: the submitter is blocked from acting on their own
    // request in /approvals (same requester_id <> auth.uid() rule as
    // invoices), so sending them there shows nothing meaningful.
  };

  if (submittedInfo) {
    return (
      <Card sx={{ maxWidth: 900, mx: "auto" }} variant="outlined">
        <CardContent>
          <Alert severity="success" sx={{ mb: 2 }}>
            Request submitted: {submittedInfo.lineItemCount} line item{submittedInfo.lineItemCount > 1 ? "s" : ""},
            {" "}{submittedInfo.totalQuantity} total qty, against {submittedInfo.costCenterLabel}. It's now in the approval queue.
          </Alert>
          <Button variant="outlined" onClick={() => setSubmittedInfo(null)}>
            Submit another request
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card sx={{ maxWidth: 900, mx: "auto" }} variant="outlined">
      <CardContent>
        <Typography variant="h6" gutterBottom>New request</Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
          Add line items manually below, or upload an Excel file (Material / Cost Code / Group Code / Place of Use / Qty / Price / Currency) to populate them.
        </Typography>

        <Box component="form" onSubmit={handleSubmit(onSubmit)} noValidate>
          <Stack spacing={2.5}>
            <Controller
              name="item_description"
              control={control}
              render={({ field }) => (
                <TextField
                  {...field}
                  label="Description"
                  placeholder="Overall description of what this request covers"
                  error={!!errors.item_description}
                  helperText={errors.item_description?.message}
                  multiline
                  minRows={2}
                  fullWidth
                />
              )}
            />

            <Stack direction={{ xs: "column", sm: "row" }} spacing={2}>
              <Controller
                name="cost_center_id"
                control={control}
                render={({ field }) => (
                  <Autocomplete
                    sx={{ flex: 1 }}
                    options={costCenterOptions}
                    loading={loadingCostCenters}
                    onChange={(_, option) => field.onChange(option?.id ?? "")}
                    value={costCenterOptions.find((o) => o.id === field.value) ?? null}
                    isOptionEqualToValue={(option, value) => option.id === value.id}
                    renderInput={(params) => (
                      <TextField
                        {...params}
                        label="Cost center"
                        error={!!errors.cost_center_id}
                        helperText={errors.cost_center_id?.message}
                        InputProps={{
                          ...params.InputProps,
                          endAdornment: (
                            <>
                              {loadingCostCenters ? <CircularProgress color="inherit" size={16} /> : null}
                              {params.InputProps.endAdornment}
                            </>
                          ),
                        }}
                      />
                    )}
                  />
                )}
              />

              <Controller
                name="delivery_date"
                control={control}
                render={({ field }) => (
                  <TextField
                    {...field}
                    label="Delivery date"
                    type="date"
                    InputLabelProps={{ shrink: true }}
                    sx={{ flex: 1 }}
                  />
                )}
              />
            </Stack>

            <Controller
              name="subcontractor"
              control={control}
              render={({ field }) => (
                <TextField {...field} label="Subcontractor (optional)" fullWidth />
              )}
            />

            {/* Excel Upload */}
            <Box>
              <Button component="label" variant="outlined" startIcon={<OpenInNew fontSize="small" />}>
                Upload Excel (.xlsx)
                <input type="file" hidden accept=".xlsx,.xls" onChange={handleFileUpload} />
              </Button>
              {fileName && (
                <Typography variant="caption" color="primary" sx={{ ml: 1.5 }}>{fileName}</Typography>
              )}
              {parseError && <Alert severity="error" sx={{ mt: 1 }}>{parseError}</Alert>}
            </Box>

            {/* MR Item List — editable, add/delete rows */}
            <Box>
              <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
                <Typography variant="subtitle2">Line items</Typography>
                <Button size="small" startIcon={<AddCircleOutline fontSize="small" />} onClick={addLineItem}>
                  Add row
                </Button>
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
                          <TableCell>
                            <TextField
                              size="small"
                              variant="standard"
                              fullWidth
                              value={row.materialService}
                              onChange={(e) => updateLineItem(row.key, { materialService: e.target.value })}
                            />
                          </TableCell>
                          <TableCell>
                            <TextField
                              size="small"
                              variant="standard"
                              fullWidth
                              value={row.costCode}
                              onChange={(e) => updateLineItem(row.key, { costCode: e.target.value })}
                            />
                          </TableCell>
                          <TableCell>
                            <TextField
                              size="small"
                              variant="standard"
                              fullWidth
                              value={row.groupCode}
                              onChange={(e) => updateLineItem(row.key, { groupCode: e.target.value })}
                            />
                          </TableCell>
                          <TableCell>
                            <TextField
                              size="small"
                              variant="standard"
                              fullWidth
                              value={row.placeOfUse}
                              onChange={(e) => updateLineItem(row.key, { placeOfUse: e.target.value })}
                            />
                          </TableCell>
                          <TableCell align="right">
                            <TextField
                              size="small"
                              variant="standard"
                              type="number"
                              inputProps={{ min: 0, style: { textAlign: "right" } }}
                              value={row.quantity}
                              onChange={(e) => updateLineItem(row.key, { quantity: e.target.value })}
                            />
                          </TableCell>
                          <TableCell align="right">
                            <TextField
                              size="small"
                              variant="standard"
                              type="number"
                              inputProps={{ min: 0, style: { textAlign: "right" } }}
                              value={row.unitPrice}
                              onChange={(e) => updateLineItem(row.key, { unitPrice: e.target.value })}
                            />
                          </TableCell>
                          <TableCell align="right">
                            {lineTotal(row) > 0 ? lineTotal(row).toLocaleString() : "—"}
                          </TableCell>
                          <TableCell>
                            <TextField
                              size="small"
                              variant="standard"
                              fullWidth
                              value={row.currency}
                              onChange={(e) => updateLineItem(row.key, { currency: e.target.value })}
                            />
                          </TableCell>
                          <TableCell>
                            <IconButton
                              size="small"
                              onClick={() => removeLineItem(row.key)}
                              disabled={lineItems.length === 1}
                            >
                              <DeleteOutline fontSize="small" />
                            </IconButton>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </TableContainer>
              </Paper>
            </Box>

            {submitError && <Alert severity="error">{submitError}</Alert>}

            <Button type="submit" variant="contained" size="large" disabled={submitting}>
              {submitting ? "Submitting…" : "Submit request"}
            </Button>
          </Stack>
        </Box>
      </CardContent>
    </Card>
  );
}