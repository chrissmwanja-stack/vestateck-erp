import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
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
} from '@mui/material';
import { Add as AddIcon, Delete as DeleteIcon, LocalShipping as LocalShippingIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

// Digitized YMI.GNL.AMB.FRM.002 (Ambar Çıkış Formu / Goods Issue Form):
// project, warehouse, voucher no, itemized lines (SAP material no, cost
// center, description, unit, request/delivery quantities, remarks), and
// the three-signature block (Warehouse Officer / Received By /
// Approved). Written in one call via record_goods_issue() so a partially
// filled-in form can't be left half-saved -- see
// 20260808140100_stock_ledger_and_goods_movements.sql.
//
// This is the *outbound* side of stock (goods leaving the warehouse to a
// project/cost center) -- the mirror of the Material Quantity screen,
// which records *inbound* receipts. Recording an issue here reduces
// stock_balances the same way a receipt increases it.

interface WarehouseOption {
  id: string;
  name: string;
  code: string | null;
  project_label: string | null;
}

interface CostCenterOption {
  id: string;
  name: string;
  project_code: string | null;
}

interface MaterialOption {
  id: string;
  code: string | null;
  name: string;
  unit: string | null;
}

interface ItemRow {
  key: number;
  material_catalog_id: string | null;
  sap_code: string;
  material_description: string;
  cost_center_id: string;
  unit: string;
  requested_qty: string;
  delivered_qty: string;
  remarks: string;
}

let keySeq = 1;
const emptyItem = (): ItemRow => ({
  key: keySeq++,
  material_catalog_id: null,
  sap_code: '',
  material_description: '',
  cost_center_id: '',
  unit: '',
  requested_qty: '',
  delivered_qty: '',
  remarks: '',
});

interface RecentIssue {
  id: string;
  voucher_no: string | null;
  project_label: string | null;
  issue_date: string;
  warehouse_name: string | null;
  item_count: number;
}

export default function GoodsIssue() {
  const [warehouses, setWarehouses] = useState<WarehouseOption[]>([]);
  const [costCenters, setCostCenters] = useState<CostCenterOption[]>([]);
  const [materials, setMaterials] = useState<MaterialOption[]>([]);

  const [warehouseId, setWarehouseId] = useState('');
  const [projectLabel, setProjectLabel] = useState('');
  const [voucherNo, setVoucherNo] = useState('');
  const [receivedByName, setReceivedByName] = useState('');
  const [approvedByName, setApprovedByName] = useState('');
  const [items, setItems] = useState<ItemRow[]>([emptyItem()]);

  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);

  const [recent, setRecent] = useState<RecentIssue[]>([]);
  const [recentLoading, setRecentLoading] = useState(true);

  const loadRecent = useCallback(async () => {
    setRecentLoading(true);
    const { data } = await supabase
      .from('goods_issues')
      .select('id, voucher_no, project_label, issue_date, warehouse:warehouse_id(name), goods_issue_items(id)')
      .order('created_at', { ascending: false })
      .limit(10);
    setRecent(
      ((data ?? []) as any[]).map((r) => ({
        id: r.id,
        voucher_no: r.voucher_no,
        project_label: r.project_label,
        issue_date: r.issue_date,
        warehouse_name: r.warehouse?.name ?? null,
        item_count: r.goods_issue_items?.length ?? 0,
      }))
    );
    setRecentLoading(false);
  }, []);

  useEffect(() => {
    supabase.from('warehouses').select('id, name, code, project_label').eq('is_active', true).order('name')
      .then(({ data }) => setWarehouses((data ?? []) as WarehouseOption[]));
    supabase.from('cost_centers').select('id, name, project_code').order('name')
      .then(({ data }) => setCostCenters((data ?? []) as CostCenterOption[]));
    supabase.from('material_catalog').select('id, code, name, unit').order('name')
      .then(({ data }) => setMaterials((data ?? []) as MaterialOption[]));
    loadRecent();
  }, [loadRecent]);

  function updateItem(key: number, patch: Partial<ItemRow>) {
    setItems((rows) => rows.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  }

  function addItem() {
    setItems((rows) => [...rows, emptyItem()]);
  }

  function removeItem(key: number) {
    setItems((rows) => (rows.length > 1 ? rows.filter((r) => r.key !== key) : rows));
  }

  // Typing a known SAP code autofills description/unit and links the
  // catalog id; typing a description that isn't in the catalog is still
  // fine -- material_catalog_id just stays null (see goods_issue_items).
  function handleSapCodeChange(key: number, value: string) {
    const match = materials.find((m) => m.code && m.code.toLowerCase() === value.trim().toLowerCase());
    updateItem(key, {
      sap_code: value,
      material_catalog_id: match?.id ?? null,
      material_description: match ? match.name : items.find((r) => r.key === key)?.material_description ?? '',
      unit: match?.unit ?? items.find((r) => r.key === key)?.unit ?? '',
    });
  }

  function resetForm() {
    setWarehouseId('');
    setProjectLabel('');
    setVoucherNo('');
    setReceivedByName('');
    setApprovedByName('');
    setItems([emptyItem()]);
  }

  async function handleSubmit() {
    setSubmitError(null);
    setSubmitted(false);

    if (!warehouseId) {
      setSubmitError('Pick a warehouse.');
      return;
    }
    const validItems = items.filter((i) => i.material_description.trim() && i.unit.trim() && parseFloat(i.delivered_qty) > 0);
    if (validItems.length === 0) {
      setSubmitError('Add at least one line item with a description, unit, and delivered quantity.');
      return;
    }

    setSubmitting(true);
    const { error } = await supabase.rpc('record_goods_issue', {
      p_warehouse_id: warehouseId,
      p_project_label: projectLabel.trim(),
      p_voucher_no: voucherNo.trim(),
      p_received_by_name: receivedByName.trim(),
      p_approved_by_name: approvedByName.trim(),
      p_items: validItems.map((i) => ({
        material_catalog_id: i.material_catalog_id,
        material_description: i.material_description.trim(),
        cost_center_id: i.cost_center_id || null,
        unit: i.unit.trim(),
        requested_qty: i.requested_qty ? parseFloat(i.requested_qty) : null,
        delivered_qty: parseFloat(i.delivered_qty),
        remarks: i.remarks.trim() || null,
      })),
    });
    setSubmitting(false);

    if (error) {
      setSubmitError(error.message ?? 'Could not record the goods issue.');
      return;
    }
    setSubmitted(true);
    resetForm();
    loadRecent();
  }

  return (
    <Box sx={{ maxWidth: 1100 }}>
      <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
        <LocalShippingIcon /> GOODS ISSUE
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Record stock leaving the warehouse to a project or cost center . This reduces stock on hand; goods coming in are recorded on Material Quantity
        instead.
      </Typography>

      {submitError && <Alert severity="error" sx={{ mb: 2 }}>{submitError}</Alert>}
      {submitted && <Alert severity="success" sx={{ mb: 2 }}>Goods issue recorded.</Alert>}

      <Paper variant="outlined" sx={{ p: 3, mb: 3 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} sx={{ mb: 3 }}>
          <TextField
            select
            label="Warehouse"
            required
            sx={{ flex: 1 }}
            size="small"
            value={warehouseId}
            onChange={(e) => setWarehouseId(e.target.value)}
            SelectProps={{ native: true }}
          >
            <option value="" />
            {warehouses.map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
                {w.code ? ` (${w.code})` : ''}
              </option>
            ))}
          </TextField>
          <TextField
            label="Project name & code"
            sx={{ flex: 1 }}
            size="small"
            value={projectLabel}
            onChange={(e) => setProjectLabel(e.target.value)}
          />
          <TextField
            label="Voucher no"
            sx={{ flex: 1 }}
            size="small"
            value={voucherNo}
            onChange={(e) => setVoucherNo(e.target.value)}
          />
        </Stack>

        <TableContainer sx={{ mb: 2 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>SAP No</TableCell>
                <TableCell>Material Description</TableCell>
                <TableCell>Cost Center</TableCell>
                <TableCell>Unit</TableCell>
                <TableCell align="right">Requested</TableCell>
                <TableCell align="right">Delivered</TableCell>
                <TableCell>Remarks</TableCell>
                <TableCell />
              </TableRow>
            </TableHead>
            <TableBody>
              {items.map((item) => (
                <TableRow key={item.key}>
                  <TableCell sx={{ minWidth: 110 }}>
                    <TextField
                      size="small"
                      variant="standard"
                      value={item.sap_code}
                      onChange={(e) => handleSapCodeChange(item.key, e.target.value)}
                    />
                  </TableCell>
                  <TableCell sx={{ minWidth: 180 }}>
                    <TextField
                      size="small"
                      variant="standard"
                      fullWidth
                      value={item.material_description}
                      onChange={(e) => updateItem(item.key, { material_description: e.target.value })}
                    />
                  </TableCell>
                  <TableCell sx={{ minWidth: 150 }}>
                    <TextField
                      select
                      size="small"
                      variant="standard"
                      fullWidth
                      value={item.cost_center_id}
                      onChange={(e) => updateItem(item.key, { cost_center_id: e.target.value })}
                      SelectProps={{ native: true }}
                    >
                      <option value="" />
                      {costCenters.map((c) => (
                        <option key={c.id} value={c.id}>
                          {c.name}
                        </option>
                      ))}
                    </TextField>
                  </TableCell>
                  <TableCell sx={{ minWidth: 90 }}>
                    <TextField
                      size="small"
                      variant="standard"
                      value={item.unit}
                      onChange={(e) => updateItem(item.key, { unit: e.target.value })}
                    />
                  </TableCell>
                  <TableCell sx={{ minWidth: 90 }} align="right">
                    <TextField
                      size="small"
                      variant="standard"
                      type="number"
                      value={item.requested_qty}
                      onChange={(e) => updateItem(item.key, { requested_qty: e.target.value })}
                    />
                  </TableCell>
                  <TableCell sx={{ minWidth: 90 }} align="right">
                    <TextField
                      size="small"
                      variant="standard"
                      type="number"
                      value={item.delivered_qty}
                      onChange={(e) => updateItem(item.key, { delivered_qty: e.target.value })}
                    />
                  </TableCell>
                  <TableCell sx={{ minWidth: 140 }}>
                    <TextField
                      size="small"
                      variant="standard"
                      fullWidth
                      value={item.remarks}
                      onChange={(e) => updateItem(item.key, { remarks: e.target.value })}
                    />
                  </TableCell>
                  <TableCell>
                    <IconButton size="small" onClick={() => removeItem(item.key)} disabled={items.length === 1}>
                      <DeleteIcon fontSize="small" />
                    </IconButton>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>

        <Button size="small" startIcon={<AddIcon />} onClick={addItem} sx={{ mb: 3 }}>
          Add line
        </Button>

        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} sx={{ mb: 3 }}>
          <TextField
            label="Received by (name)"
            sx={{ flex: 1 }}
            size="small"
            value={receivedByName}
            onChange={(e) => setReceivedByName(e.target.value)}
            helperText="Person taking delivery — often site personnel, not a system user"
          />
          <TextField
            label="Approved by (name)"
            sx={{ flex: 1 }}
            size="small"
            value={approvedByName}
            onChange={(e) => setApprovedByName(e.target.value)}
          />
        </Stack>

        <Button variant="contained" disabled={submitting} onClick={handleSubmit}>
          {submitting ? 'Recording…' : 'Record goods issue'}
        </Button>
      </Paper>

      <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
        RECENT ISSUES
      </Typography>
      <Paper variant="outlined">
        {recentLoading ? (
          <Box display="flex" justifyContent="center" py={3}>
            <CircularProgress size={20} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Date</TableCell>
                  <TableCell>Warehouse</TableCell>
                  <TableCell>Project</TableCell>
                  <TableCell>Voucher no</TableCell>
                  <TableCell align="right">Lines</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {recent.map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell>{new Date(r.issue_date).toLocaleDateString()}</TableCell>
                    <TableCell>{r.warehouse_name ?? '—'}</TableCell>
                    <TableCell>{r.project_label ?? '—'}</TableCell>
                    <TableCell>{r.voucher_no ?? '—'}</TableCell>
                    <TableCell align="right">{r.item_count}</TableCell>
                  </TableRow>
                ))}
                {recent.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No goods issues recorded yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>
    </Box>
  );
}