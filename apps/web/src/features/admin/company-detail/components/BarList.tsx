import { Box, Stack, Typography } from '@mui/material';
import type { CountRow } from './Types';

export function BarList({ rows, labelKey, emptyLabel }: { rows: CountRow[]; labelKey: string; emptyLabel: string }) {
  if (rows.length === 0) {
    return (
      <Typography variant="body2" color="text.secondary">
        {emptyLabel}
      </Typography>
    );
  }
  const max = Math.max(...rows.map((r) => r.count), 1);
  return (
    <Stack spacing={1}>
      {rows.map((r) => (
        <Box key={String(r[labelKey])}>
          <Stack direction="row" justifyContent="space-between">
            <Typography variant="body2">{String(r[labelKey])}</Typography>
            <Typography variant="body2" color="text.secondary">
              {r.count}
            </Typography>
          </Stack>
          <Box sx={{ bgcolor: 'action.hover', borderRadius: 1, height: 6, mt: 0.5 }}>
            <Box sx={{ bgcolor: 'primary.main', borderRadius: 1, height: 6, width: `${(r.count / max) * 100}%` }} />
          </Box>
        </Box>
      ))}
    </Stack>
  );
}