import { Paper, Typography } from '@mui/material';

export function Stat({ label, value, hint }: { label: string; value: string | number; hint?: string }) {
  return (
    <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 150, flex: '1 1 150px' }}>
      <Typography variant="h6">{value}</Typography>
      <Typography variant="caption" color="text.secondary">
        {label}
      </Typography>
      {hint && (
        <Typography variant="caption" color="text.secondary" display="block">
          {hint}
        </Typography>
      )}
    </Paper>
  );
}