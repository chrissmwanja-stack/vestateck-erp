import { useState } from "react";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  LinearProgress,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from "@mui/material";
import { UploadFile, CheckCircle, ErrorOutline } from "@mui/icons-material";
import { supabase } from "../../lib/supabaseClient";
import { useAuth } from "../../lib/authContext";
import { parseCsv } from "../../lib/csvParser";

/**
 * Resolves a CSV column's text value (e.g. "Engineering") to a foreign key
 * id (e.g. departments.id) by name-matching against a tenant-scoped lookup
 * table. Built once per import from a single query, then reused per row.
 */
export interface BulkImportLookup {
  /** CSV column this lookup reads from, e.g. "department" */
  csvColumn: string;
  /** Supabase table to resolve against, e.g. "departments" */
  table: string;
  /** Column on that table to match the CSV value against, e.g. "name" */
  matchColumn: string;
  /** Key to write the resolved id under in the insert payload, e.g. "department_id" */
  payloadKey: string;
  /** Human label for error messages, e.g. "Department" */
  label: string;
  required?: boolean;
}

export interface BulkImportColumn {
  /** CSV column name (lowercased header) */
  key: string;
  label: string;
  required?: boolean;
  /** If set, the raw string must be one of these values (case-insensitive) */
  enumValues?: string[];
}

export interface BulkImportRowResult {
  line: number;
  status: "success" | "error";
  message?: string;
}

export interface BulkImportConfig {
  /** Supabase table rows are inserted into */
  table: string;
  /** Display name, e.g. "Employees" */
  entityLabel: string;
  /** Plain CSV columns validated for presence/format before insert */
  columns: BulkImportColumn[];
  /** FK name -> id resolutions performed before insert */
  lookups?: BulkImportLookup[];
  /** Example CSV row(s) shown as a format hint, header auto-derived from columns+lookups */
  sampleRowValues: string[];
  /**
   * Builds the final insert payload for one validated row.
   * `resolved` contains resolved FK ids keyed by payloadKey.
   * `tenant_id` is resolved once per import via app_users.
   */
  buildPayload: (
    row: Record<string, string>,
    resolved: Record<string, string>,
    tenant_id: string
  ) => Record<string, any>;
  /** Optional: flag duplicate rows within the same file by this CSV column (e.g. "email") */
  dedupeColumn?: string;
}

interface ValidatedRow {
  line: number;
  raw: Record<string, string>;
  resolved: Record<string, string>;
  errors: string[];
}

export default function BulkImportDialog({
  open,
  onClose,
  onImported,
  config,
}: {
  open: boolean;
  onClose: () => void;
  onImported: () => void;
  config: BulkImportConfig;
}) {
  const { session } = useAuth();
  const [fileName, setFileName] = useState<string | null>(null);
  const [validating, setValidating] = useState(false);
  const [validated, setValidated] = useState<ValidatedRow[]>([]);
  const [importing, setImporting] = useState(false);
  const [results, setResults] = useState<BulkImportRowResult[] | null>(null);
  const [fatalError, setFatalError] = useState<string | null>(null);

  const reset = () => {
    setFileName(null);
    setValidating(false);
    setValidated([]);
    setImporting(false);
    setResults(null);
    setFatalError(null);
  };

  const handleClose = () => {
    reset();
    onClose();
  };

  const csvHeader = [
    ...config.columns.map((c) => c.key),
    ...(config.lookups || []).map((l) => l.csvColumn),
  ];

  const handleFile = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setFileName(file.name);
    setResults(null);
    setFatalError(null);
    setValidating(true);

    try {
      const text = await file.text();
      const { rows, rowLineNumbers } = parseCsv(text);

      if (rows.length === 0) {
        setFatalError("No data rows found in the CSV file.");
        setValidating(false);
        return;
      }

      // Pre-load every lookup table once, tenant-scoped, so per-row
      // validation is a local map lookup rather than N queries.
      const lookupMaps: Record<string, Map<string, string>> = {};
      for (const lookup of config.lookups || []) {
        const { data, error } = await supabase
          .from(lookup.table)
          .select(`id, ${lookup.matchColumn}`);
        if (error) {
          setFatalError(`Could not load ${lookup.label} list: ${error.message}`);
          setValidating(false);
          return;
        }
        const map = new Map<string, string>();
        (data || []).forEach((r: any) => {
          const key = String(r[lookup.matchColumn] ?? "").trim().toLowerCase();
          if (key) map.set(key, r.id);
        });
        lookupMaps[lookup.csvColumn] = map;
      }

      const seenDedupe = new Set<string>();
      const out: ValidatedRow[] = rows.map((row, idx) => {
        const errors: string[] = [];
        const resolved: Record<string, string> = {};

        for (const col of config.columns) {
          const val = row[col.key] ?? "";
          if (col.required && !val) {
            errors.push(`${col.label} is required`);
          }
          if (col.enumValues && val && !col.enumValues.some((v) => v.toLowerCase() === val.toLowerCase())) {
            errors.push(`${col.label} must be one of: ${col.enumValues.join(", ")}`);
          }
        }

        for (const lookup of config.lookups || []) {
          const raw = (row[lookup.csvColumn] ?? "").trim();
          if (!raw) {
            if (lookup.required) errors.push(`${lookup.label} is required`);
            continue;
          }
          const id = lookupMaps[lookup.csvColumn]?.get(raw.toLowerCase());
          if (!id) {
            errors.push(`${lookup.label} "${raw}" not found — check spelling against the admin list`);
          } else {
            resolved[lookup.payloadKey] = id;
          }
        }

        if (config.dedupeColumn) {
          const dedupeVal = (row[config.dedupeColumn] ?? "").trim().toLowerCase();
          if (dedupeVal) {
            if (seenDedupe.has(dedupeVal)) {
              errors.push(`Duplicate ${config.dedupeColumn} within this file`);
            }
            seenDedupe.add(dedupeVal);
          }
        }

        return { line: rowLineNumbers[idx], raw: row, resolved, errors };
      });

      setValidated(out);
    } catch (err: any) {
      setFatalError(err?.message || "Failed to read file.");
    } finally {
      setValidating(false);
    }
  };

  const validRows = validated.filter((r) => r.errors.length === 0);
  const invalidRows = validated.filter((r) => r.errors.length > 0);

  const handleImport = async () => {
    if (validRows.length === 0) return;
    setImporting(true);
    setFatalError(null);

    const { data: appUser, error: appUserErr } = await supabase
      .from("app_users")
      .select("tenant_id")
      .eq("id", session?.user?.id)
      .single();

    if (appUserErr || !appUser?.tenant_id) {
      setFatalError("Could not determine your organization. Please refresh and try again.");
      setImporting(false);
      return;
    }
    const tenant_id = appUser.tenant_id as string;

    const rowResults: BulkImportRowResult[] = [];
    // Sequential inserts (not Promise.all) so per-row errors stay attributable
    // to a specific line and one bad row can't abort the whole batch.
    for (const row of validRows) {
      const payload = config.buildPayload(row.raw, row.resolved, tenant_id);
      const { error } = await supabase.from(config.table).insert(payload);
      if (error) {
        rowResults.push({ line: row.line, status: "error", message: error.message });
      } else {
        rowResults.push({ line: row.line, status: "success" });
      }
    }
    // Rows that failed pre-import validation are reported too, so the
    // final tally always adds up to the full file's row count.
    for (const row of invalidRows) {
      rowResults.push({ line: row.line, status: "error", message: row.errors.join("; ") });
    }
    rowResults.sort((a, b) => a.line - b.line);

    setResults(rowResults);
    setImporting(false);
    onImported();
  };

  const successCount = results?.filter((r) => r.status === "success").length ?? 0;
  const errorCount = results?.filter((r) => r.status === "error").length ?? 0;

  return (
    <Dialog open={open} onClose={handleClose} maxWidth="md" fullWidth>
      <DialogTitle>Bulk Import {config.entityLabel}</DialogTitle>
      <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {!results && (
          <>
            <Typography variant="body2" color="text.secondary">
              Upload a CSV with headers: <b>{csvHeader.join(", ")}</b>
            </Typography>
            <Box component="pre" sx={{ bgcolor: "grey.100", p: 1, borderRadius: 1, fontSize: 12, overflow: "auto" }}>
              {csvHeader.join(",")}
              {"\n"}
              {config.sampleRowValues.join(",")}
            </Box>
            <Button variant="contained" component="label" startIcon={<UploadFile />} sx={{ alignSelf: "flex-start" }}>
              Choose CSV File
              <input type="file" accept=".csv" hidden onChange={handleFile} />
            </Button>
            {fileName && <Typography variant="caption" color="text.secondary">{fileName}</Typography>}

            {validating && <LinearProgress />}
            {fatalError && <Alert severity="error">{fatalError}</Alert>}

            {validated.length > 0 && !validating && (
              <>
                <Box sx={{ display: "flex", gap: 1 }}>
                  <Chip icon={<CheckCircle />} color="success" label={`${validRows.length} ready to import`} size="small" />
                  {invalidRows.length > 0 && (
                    <Chip icon={<ErrorOutline />} color="error" label={`${invalidRows.length} with errors`} size="small" />
                  )}
                </Box>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>Line</TableCell>
                      {config.columns.map((c) => (
                        <TableCell key={c.key}>{c.label}</TableCell>
                      ))}
                      <TableCell>Issues</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {validated.slice(0, 50).map((r) => (
                      <TableRow key={r.line} sx={r.errors.length > 0 ? { bgcolor: "error.lighter" } : undefined}>
                        <TableCell>{r.line}</TableCell>
                        {config.columns.map((c) => (
                          <TableCell key={c.key}>{r.raw[c.key]}</TableCell>
                        ))}
                        <TableCell>
                          {r.errors.length > 0 ? (
                            <Typography variant="caption" color="error">{r.errors.join("; ")}</Typography>
                          ) : (
                            <Typography variant="caption" color="success.main">OK</Typography>
                          )}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                {validated.length > 50 && (
                  <Typography variant="caption" color="text.secondary">
                    Showing first 50 of {validated.length} rows. All {validRows.length} valid rows will be imported.
                  </Typography>
                )}
              </>
            )}
          </>
        )}

        {results && (
          <>
            <Alert severity={errorCount === 0 ? "success" : "warning"}>
              Imported {successCount} of {results.length} rows.{errorCount > 0 ? ` ${errorCount} failed.` : ""}
            </Alert>
            <Table size="small">
              <TableHead>
                <TableRow><TableCell>Line</TableCell><TableCell>Status</TableCell><TableCell>Detail</TableCell></TableRow>
              </TableHead>
              <TableBody>
                {results.map((r) => (
                  <TableRow key={r.line}>
                    <TableCell>{r.line}</TableCell>
                    <TableCell>
                      <Chip
                        size="small"
                        label={r.status}
                        color={r.status === "success" ? "success" : "error"}
                      />
                    </TableCell>
                    <TableCell><Typography variant="caption">{r.message || "-"}</Typography></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </>
        )}
      </DialogContent>
      <DialogActions>
        <Button onClick={handleClose}>{results ? "Close" : "Cancel"}</Button>
        {!results && (
          <Button
            variant="contained"
            onClick={handleImport}
            disabled={validRows.length === 0 || importing || validating}
          >
            {importing ? <><CircularProgress size={18} sx={{ mr: 1 }} /> Importing...</> : `Import ${validRows.length} rows`}
          </Button>
        )}
      </DialogActions>
    </Dialog>
  );
}
