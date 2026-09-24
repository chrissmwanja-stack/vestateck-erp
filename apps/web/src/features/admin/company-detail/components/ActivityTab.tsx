import { Paper, Stack, Table, TableBody, TableCell, TableRow, Typography } from '@mui/material';
import { BarList } from './BarList';
import type { Analytics } from './Types';

export function ActivityTab({ analytics }: { analytics: Analytics }) {
  return (
    <>
      <Stack direction="row" spacing={2} flexWrap="wrap" sx={{ mb: 3 }}>
        <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 160 }}>
          <Typography variant="h6">{analytics.purchase_orders.count}</Typography>
          <Typography variant="caption" color="text.secondary">
            Purchase orders
          </Typography>
        </Paper>
        <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 200 }}>
          <Typography variant="h6">
            {analytics.purchase_orders.total_value.toLocaleString(undefined, { maximumFractionDigits: 0 })}
          </Typography>
          <Typography variant="caption" color="text.secondary">
            Total PO value (UGX)
          </Typography>
        </Paper>
      </Stack>

      <Stack direction="row" spacing={2} flexWrap="wrap" useFlexGap>
        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Requests by status
          </Typography>
          <BarList rows={analytics.requests_by_status} labelKey="status" emptyLabel="No requests yet." />
        </Paper>
        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Requests, last 6 months
          </Typography>
          <BarList rows={analytics.requests_by_month} labelKey="month" emptyLabel="No requests in this window." />
        </Paper>
        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Members by department
          </Typography>
          <BarList rows={analytics.members_by_department} labelKey="department" emptyLabel="No members yet." />
        </Paper>
        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Top requesters
          </Typography>
          {analytics.top_requesters.length === 0 ? (
            <Typography variant="body2" color="text.secondary">
              No requests yet.
            </Typography>
          ) : (
            <Table size="small">
              <TableBody>
                {analytics.top_requesters.map((r) => (
                  <TableRow key={String(r.name)}>
                    <TableCell>{String(r.name)}</TableCell>
                    <TableCell align="right">{r.count}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </Paper>
      </Stack>
    </>
  );
}