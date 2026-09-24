import { FormEvent } from "react";
import { Autocomplete, Box, Button, CircularProgress, MenuItem, Paper, Stack, TextField, Typography } from "@mui/material";
import { Search as SearchIcon, Clear as ClearIcon } from "@mui/icons-material";

export interface SearchFilters {
  source: "" | "supplier" | "receivable";
  invoiceNo: string;
  dateFrom: string;
  dateTo: string;
  organizationId: string;
  categoryId: string;
  accountId: string;
  prfOifNo: string;
}

export const emptyFilters: SearchFilters = {
  source: "",
  invoiceNo: "",
  dateFrom: "",
  dateTo: "",
  organizationId: "",
  categoryId: "",
  accountId: "",
  prfOifNo: "",
};

export function InvoiceSearchFilters({
  filters,
  setFilters,
  organizationOptions,
  accountCategoryOptions,
  searchAccountOptions,
  loadingOrganizations,
  loadingSearchAccounts,
  onSearch,
  onClear,
}: {
  filters: SearchFilters;
  setFilters: (updater: (f: SearchFilters) => SearchFilters) => void;
  organizationOptions: { id: string; label: string }[];
  accountCategoryOptions: { id: string; label: string }[];
  searchAccountOptions: { id: string; label: string }[];
  loadingOrganizations: boolean;
  loadingSearchAccounts: boolean;
  onSearch: (f: SearchFilters) => void;
  onClear: () => void;
}) {
  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    onSearch(filters);
  };

  return (
    <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
      <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
        Search
      </Typography>
      <Box component="form" onSubmit={handleSubmit}>
        <Stack direction={{ xs: "column", sm: "row" }} spacing={2} flexWrap="wrap" sx={{ mb: 2 }}>
          <Autocomplete
            options={organizationOptions}
            loading={loadingOrganizations}
            sx={{ flex: 1, minWidth: 220 }}
            onChange={(_, option) => setFilters((f) => ({ ...f, organizationId: option?.id ?? "" }))}
            value={organizationOptions.find((o) => o.id === filters.organizationId) ?? null}
            isOptionEqualToValue={(option, value) => option.id === value.id}
            renderInput={(params) => (
              <TextField
                {...params}
                label="Organization"
                size="small"
                InputProps={{
                  ...params.InputProps,
                  endAdornment: (
                    <>
                      {loadingOrganizations ? <CircularProgress color="inherit" size={16} /> : null}
                      {params.InputProps.endAdornment}
                    </>
                  ),
                }}
              />
            )}
          />
          <TextField
            select
            label="Account Type"
            size="small"
            sx={{ flex: 1, minWidth: 160 }}
            value={filters.categoryId}
            onChange={(e) => setFilters((f) => ({ ...f, categoryId: e.target.value, accountId: "" }))}
          >
            <MenuItem value="">All</MenuItem>
            {accountCategoryOptions.map((c) => (
              <MenuItem key={c.id} value={c.id}>
                {c.label}
              </MenuItem>
            ))}
          </TextField>
          <Autocomplete
            options={searchAccountOptions}
            loading={loadingSearchAccounts}
            sx={{ flex: 1, minWidth: 220 }}
            onChange={(_, option) => setFilters((f) => ({ ...f, accountId: option?.id ?? "" }))}
            value={searchAccountOptions.find((o) => o.id === filters.accountId) ?? null}
            isOptionEqualToValue={(option, value) => option.id === value.id}
            renderInput={(params) => (
              <TextField
                {...params}
                label="Account List"
                size="small"
                InputProps={{
                  ...params.InputProps,
                  endAdornment: (
                    <>
                      {loadingSearchAccounts ? <CircularProgress color="inherit" size={16} /> : null}
                      {params.InputProps.endAdornment}
                    </>
                  ),
                }}
              />
            )}
          />
        </Stack>
        <Stack direction={{ xs: "column", sm: "row" }} spacing={2} flexWrap="wrap">
          <TextField
            select
            label="Source"
            size="small"
            sx={{ flex: 1, minWidth: 160 }}
            value={filters.source}
            onChange={(e) => setFilters((f) => ({ ...f, source: e.target.value as SearchFilters["source"] }))}
          >
            <MenuItem value="">Both</MenuItem>
            <MenuItem value="supplier">Supplier Invoice</MenuItem>
            <MenuItem value="receivable">Receivable Invoice</MenuItem>
          </TextField>
          <TextField
            label="PRF / OIF No"
            size="small"
            sx={{ flex: 1, minWidth: 160 }}
            value={filters.prfOifNo}
            onChange={(e) => setFilters((f) => ({ ...f, prfOifNo: e.target.value }))}
          />
          <TextField
            label="Invoice No"
            size="small"
            sx={{ flex: 1, minWidth: 160 }}
            value={filters.invoiceNo}
            onChange={(e) => setFilters((f) => ({ ...f, invoiceNo: e.target.value }))}
          />
          <TextField
            label="Date From"
            type="date"
            size="small"
            sx={{ flex: 1, minWidth: 160 }}
            InputLabelProps={{ shrink: true }}
            value={filters.dateFrom}
            onChange={(e) => setFilters((f) => ({ ...f, dateFrom: e.target.value }))}
          />
          <TextField
            label="Date To"
            type="date"
            size="small"
            sx={{ flex: 1, minWidth: 160 }}
            InputLabelProps={{ shrink: true }}
            value={filters.dateTo}
            onChange={(e) => setFilters((f) => ({ ...f, dateTo: e.target.value }))}
          />
        </Stack>
        <Stack direction="row" spacing={1} sx={{ mt: 2 }}>
          <Button type="submit" variant="contained" startIcon={<SearchIcon />}>
            Search
          </Button>
          <Button variant="outlined" startIcon={<ClearIcon />} onClick={onClear}>
            Clear
          </Button>
        </Stack>
      </Box>
    </Paper>
  );
}
