import type { ReactNode } from 'react';
import { Box, Button, Card, CardContent, IconButton, InputAdornment, Stack, TextField, Typography } from '@mui/material';
import { Clear, Search } from '@mui/icons-material';

interface Props {
  search: string;
  onSearch: (value: string) => void;
  placeholder: string;
  /** Rows showing after the search and filters, and rows before them. */
  shown: number;
  total: number;
  /** Plural noun for the count, for example "policies". */
  noun: string;
  /** Search and filters doing something, so "Clear filters" is offered. */
  activeCount: number;
  onClear: () => void;
  children?: ReactNode;
}

// Search box, the filters of a list, a count and a way back to the full list.
export default function ListToolbar({ search, onSearch, placeholder, shown, total, noun, activeCount, onClear, children }: Props) {
  return (
    <Card sx={{ mb: 2 }}>
      <CardContent>
        <Stack direction="row" spacing={2} alignItems="center" flexWrap="wrap" useFlexGap>
          <TextField
            size="small"
            value={search}
            onChange={(e) => onSearch(e.target.value)}
            placeholder={placeholder}
            inputProps={{ 'aria-label': 'Search' }}
            sx={{ minWidth: 280, flexGrow: 1, maxWidth: 420 }}
            InputProps={{
              startAdornment: <InputAdornment position="start"><Search fontSize="small" /></InputAdornment>,
              endAdornment: search ? (
                <InputAdornment position="end">
                  <IconButton size="small" aria-label="Clear search" onClick={() => onSearch('')}><Clear fontSize="small" /></IconButton>
                </InputAdornment>
              ) : undefined,
            }}
          />
          {children}
          <Box sx={{ flexGrow: 1 }} />
          <Typography variant="body2" color="text.secondary" role="status">
            {shown === total ? `${total} ${noun}` : `Showing ${shown} of ${total} ${noun}`}
          </Typography>
          {activeCount > 0 && <Button size="small" onClick={onClear}>Clear filters</Button>}
        </Stack>
      </CardContent>
    </Card>
  );
}
