import { Box, Card, CardContent, Typography, Chip, Button, Breadcrumbs, Link } from "@mui/material";
import { useLocation } from "react-router-dom";
import { Handshake } from "@mui/icons-material";

interface Props {
  title?: string;
  description?: string;
  module?: string;
}

export default function BDPlaceholder({ title, description, module = "Business Development" }: Props) {
  const location = useLocation();
  const derivedTitle = title || location.pathname.split("/").pop()?.replace(/-/g, " ").replace(/\b\w/g, l => l.toUpperCase()) || "Page";

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        {location.pathname.split("/").filter(Boolean).map((part, i, arr) => (
          <Link key={i} underline="hover" color={i === arr.length-1 ? "text.primary" : "inherit"} sx={{ textTransform: "capitalize" }}>
            {part.replace(/-/g, " ")}
          </Link>
        ))}
      </Breadcrumbs>

      <Box sx={{ display: "flex", alignItems: "center", gap: 2, mb: 3 }}>
        <Typography variant="h5" fontWeight={700}>{derivedTitle}</Typography>
        <Chip label={module} size="small" color="primary" variant="outlined" />
        <Chip label="Shell" size="small" color="warning" icon={<Handshake />} />
      </Box>

      <Card variant="outlined" sx={{ borderStyle: "dashed" }}>
        <CardContent>
          <Typography variant="subtitle2" gutterBottom>Route</Typography>
          <Typography variant="body2" sx={{ fontFamily: "monospace", bgcolor: "grey.100", p: 1, borderRadius: 1, mb: 2 }}>
            {location.pathname}
          </Typography>

          <Typography variant="subtitle2" gutterBottom>What this screen will do</Typography>
          <Typography variant="body2" color="text.secondary" paragraph>
            {description || `Placeholder for ${derivedTitle}. Part of Business Development shell.`}
          </Typography>

          <Box sx={{ display: "flex", gap: 1, mt: 2 }}>
            <Button variant="contained" size="small" disabled>Build Table</Button>
            <Button variant="outlined" size="small" disabled>Build Form</Button>
            <Button variant="outlined" size="small" disabled>Add RLS</Button>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
}
