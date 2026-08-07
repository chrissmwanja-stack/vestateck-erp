import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Alert, Box, CircularProgress, InputAdornment, Paper, Stack,
  Table, TableBody, TableCell, TableContainer, TableHead, TableRow,
  TableSortLabel, TextField, Typography,
} from "@mui/material";
import SearchIcon from "@mui/icons-material/Search";
import { supabase } from "../../lib/supabaseClient";
import type { CostCenter } from "@erp-platform/shared";

type SortKey = "name" | "project_code" | "budget_amount";
type SortDirection = "asc" | "desc";

export default function CostCodeList() {
  const [items, setItems] = useState<CostCenter[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [sortKey, setSortKey] = useState<SortKey>("name");
  const [sortDirection, setSortDirection] = useState<SortDirection>("asc");

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase.from("cost_centers").select("*").order("name");
    if (error) setLoadError(error.message);
    else setItems((data ?? []) as CostCenter[]);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) {
      setSortDirection((dir) => (dir === "asc" ? "desc" : "asc"));
    } else {
      setSortKey(key);
      setSortDirection("asc");
    }
  };

  const filteredSorted = useMemo(() => {
    const term = search.trim().toLowerCase();
    const filtered = term
      ? items.filter(
          (item) =>
            item.name?.toLowerCase().includes(term) ||
            item.project_code?.toLowerCase().includes(term)
        )
      : items;

    const sorted = [...filtered].sort((a, b) => {
      let cmp = 0;
      if (sortKey === "budget_amount") {
        cmp = (Number(a.budget_amount) || 0) - (Number(b.budget_amount) || 0);
      } else {
        cmp = String(a[sortKey] ?? "").localeCompare(String(b[sortKey] ?? ""));
      }
      return sortDirection === "asc" ? cmp : -cmp;
    });

    return sorted;
  }, [items, search, sortKey, sortDirection]);

  const totalBudget = useMemo(
    () => filteredSorted.reduce((sum, item) => sum + (Number(item.budget_amount) || 0), 0),
    [filteredSorted]
  );

  if (loading) return <Box display="flex" justifyContent="center" py={6}><CircularProgress /></Box>;
  if (loadError) return <Alert severity="error" sx={{ maxWidth: 700, mx: "auto" }}>{loadError}</Alert>;

  return (
    <Box sx={{ maxWidth: 1000, mx: "auto" }}>
      <Typography variant="h6" gutterBottom>Cost Code List</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Read-only view of all cost centers. To create or edit a cost code, use Cost Code List New.
      </Typography>

      <TextField
        size="small"
        placeholder="Search by name or project code"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        sx={{ mb: 2, width: 320 }}
        InputProps={{
          startAdornment: (
            <InputAdornment position="start">
              <SearchIcon fontSize="small" />
            </InputAdornment>
          ),
        }}
      />

      <Paper variant="outlined">
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>
                  <TableSortLabel
                    active={sortKey === "name"}
                    direction={sortKey === "name" ? sortDirection : "asc"}
                    onClick={() => toggleSort("name")}
                  >
                    Name
                  </TableSortLabel>
                </TableCell>
                <TableCell>
                  <TableSortLabel
                    active={sortKey === "project_code"}
                    direction={sortKey === "project_code" ? sortDirection : "asc"}
                    onClick={() => toggleSort("project_code")}
                  >
                    Project Code
                  </TableSortLabel>
                </TableCell>
                <TableCell align="right">
                  <TableSortLabel
                    active={sortKey === "budget_amount"}
                    direction={sortKey === "budget_amount" ? sortDirection : "asc"}
                    onClick={() => toggleSort("budget_amount")}
                  >
                    Budget (UGX)
                  </TableSortLabel>
                </TableCell>
                <TableCell>Tenant</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filteredSorted.map((item) => (
                <TableRow key={item.id} hover>
                  <TableCell>{item.name}</TableCell>
                  <TableCell>{item.project_code || "—"}</TableCell>
                  <TableCell align="right">
                    {item.budget_amount != null ? Number(item.budget_amount).toLocaleString() : "—"}
                  </TableCell>
                  <TableCell>{item.tenant_id ? item.tenant_id.slice(0, 8) : "—"}</TableCell>
                </TableRow>
              ))}
              {filteredSorted.length === 0 && (
                <TableRow>
                  <TableCell colSpan={4}>
                    <Typography variant="body2" color="text.secondary" sx={{ py: 2, textAlign: "center" }}>
                      No cost codes match your search.
                    </Typography>
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      <Stack direction="row" justifyContent="flex-end" sx={{ mt: 1.5 }}>
        <Typography variant="body2" color="text.secondary">
          {filteredSorted.length} cost code{filteredSorted.length === 1 ? "" : "s"} · Total budget: {totalBudget.toLocaleString()} UGX
        </Typography>
      </Stack>
    </Box>
  );
}