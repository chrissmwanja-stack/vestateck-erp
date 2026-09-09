import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Badge,
  Box,
  Button,
  Card,
  CardActionArea,
  CardContent,
  CircularProgress,
  Stack,
  Typography,
} from "@mui/material";
import { AssignmentTurnedIn as AssignmentTurnedInIcon, ChevronRight } from "@mui/icons-material";
import { Link as RouterLink } from "react-router-dom";
import { supabase } from "../../lib/supabaseClient";

// Each row here is a link out to a real approval screen elsewhere in the
// app (Payroll Approvals, Leave Approvals, Proposal Approvals, ...) --
// this page never duplicates their data or actions, it just answers "which
// of these can I act on right now" in one place, independent of which
// module's nav tree a screen normally lives under. See
// list_my_approval_surfaces() (20260909080000_my_approval_surfaces.sql)
// for why this exists: most approval screens are only discoverable via
// their own module's nav section, but some approval rights (payroll,
// today) are deliberately granted to people outside that module.
interface ApprovalSurface {
  surface_key: string;
  label: string;
  route: string;
  pending_count: number | null;
}

export default function MyApprovals() {
  const [surfaces, setSurfaces] = useState<ApprovalSurface[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    const { data, error } = await supabase.rpc("list_my_approval_surfaces");
    if (error) setLoadError(error.message);
    else setSurfaces((data ?? []) as ApprovalSurface[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <Box>
      <Typography variant="h5" fontWeight={600} gutterBottom>
        My Approvals
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Every approval screen you currently have rights to act on, in one place -- wherever it
        normally lives in the module nav.
      </Typography>

      {loading && (
        <Box display="flex" justifyContent="center" py={6}>
          <CircularProgress />
        </Box>
      )}

      {!loading && loadError && <Alert severity="error">{loadError}</Alert>}

      {!loading && !loadError && surfaces.length === 0 && (
        <Alert severity="info">
          Nothing waiting on you right now. Screens you're an approver for will show up here as
          soon as something needs your decision.
        </Alert>
      )}

      {!loading && !loadError && surfaces.length > 0 && (
        <Stack spacing={1.5}>
          {surfaces.map((s) => (
            <Card key={s.surface_key} variant="outlined">
              <CardActionArea component={RouterLink} to={s.route}>
                <CardContent
                  sx={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}
                >
                  <Stack direction="row" spacing={2} alignItems="center">
                    <AssignmentTurnedInIcon color="action" />
                    <Typography variant="subtitle1" fontWeight={500}>
                      {s.label}
                    </Typography>
                    {typeof s.pending_count === "number" && s.pending_count > 0 && (
                      <Badge
                        badgeContent={s.pending_count}
                        color="warning"
                        sx={{ "& .MuiBadge-badge": { position: "static", transform: "none" } }}
                      />
                    )}
                  </Stack>
                  <Button size="small" endIcon={<ChevronRight />} tabIndex={-1}>
                    Open
                  </Button>
                </CardContent>
              </CardActionArea>
            </Card>
          ))}
        </Stack>
      )}
    </Box>
  );
}
