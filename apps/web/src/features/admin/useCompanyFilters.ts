import { useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import {
  applyCompanyFilters,
  filtersFromSearch,
  filtersToSearch,
  sortCompanies,
  type CompanyFilters,
  type SortKey,
  type Tenant,
} from "./companiesList";

export function useCompanyFilters(rows: Tenant[]) {
  const [searchParams, setSearchParams] = useSearchParams();
  const filters = useMemo(() => filtersFromSearch(searchParams), [searchParams]);

  const setFilters = useCallback(
    (next: CompanyFilters | ((f: CompanyFilters) => CompanyFilters)) => {
      const value = typeof next === "function" ? next(filtersFromSearch(searchParams)) : next;
      setSearchParams(filtersToSearch(value), { replace: true });
    },
    [searchParams, setSearchParams],
  );

  const [sortKey, setSortKey] = useState<SortKey>("created_at");
  const [sortDir, setSortDir] = useState<"asc" | "desc">("desc");
  const [page, setPage] = useState(0);
  const [rowsPerPage, setRowsPerPage] = useState(25);

  const filteredRows = useMemo(() => sortCompanies(applyCompanyFilters(rows, filters), sortKey, sortDir), [rows, filters, sortKey, sortDir]);
  const pagedRows = useMemo(() => filteredRows.slice(page * rowsPerPage, page * rowsPerPage + rowsPerPage), [filteredRows, page, rowsPerPage]);

  useEffect(() => setPage(0), [filters, sortKey, sortDir, rowsPerPage]);

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    else {
      setSortKey(key);
      setSortDir(key === "name" || key === "status" || key === "plan" ? "asc" : "desc");
    }
  };

  return {
    filters,
    setFilters,
    sortKey,
    sortDir,
    page,
    setPage,
    rowsPerPage,
    setRowsPerPage,
    filteredRows,
    pagedRows,
    toggleSort,
  };
}
