import { useState } from "react";
import { Box, Collapse, List, ListItemButton, ListItemIcon, ListItemText, Typography } from "@mui/material";
import { Folder, ChevronRight, ExpandMore } from "@mui/icons-material";
import { Link as RouterLink } from "react-router-dom";
import type { TreeNode } from "./types";

export function TreeItem({ node, depth = 0, pathname }: { node: TreeNode; depth?: number; pathname: string }) {
  const [open, setOpen] = useState(depth === 0);
  const hasChildren = !!node.children && node.children.length > 0;

  const isActive = node.to ? pathname === node.to.split("?")[0] : false;
  const isParentActive = hasChildren && node.children!.some((c) => c.to && pathname.startsWith(c.to.split("?")[0]));

  if (hasChildren) {
    return (
      <Box>
        <ListItemButton
          sx={{
            pl: 2 + depth * 2,
            py: 0.6,
            borderRadius: 1,
            bgcolor: isParentActive ? "action.selected" : "transparent",
            mb: 0.2,
          }}
          onClick={() => setOpen((o) => !o)}
          disabled={node.disabled}
        >
          <ListItemIcon sx={{ minWidth: 32, color: isParentActive ? "primary.main" : "text.secondary" }}>
            {node.icon || <Folder fontSize="small" />}
          </ListItemIcon>
          <ListItemText
            primary={
              <Typography variant="body2" fontWeight={isParentActive ? 600 : 500}>
                {node.label}
              </Typography>
            }
            secondary={node.disabled ? "Coming soon" : undefined}
          />
          {open ? <ExpandMore fontSize="small" /> : <ChevronRight fontSize="small" />}
        </ListItemButton>
        <Collapse in={open} timeout="auto" unmountOnExit>
          <List dense disablePadding sx={{ pl: 0.5 }}>
            {node.children!.map((child) => (
              <TreeItem key={child.id} node={child} depth={depth + 1} pathname={pathname} />
            ))}
          </List>
        </Collapse>
      </Box>
    );
  }

  return (
    <ListItemButton
      sx={{
        pl: 2 + depth * 2,
        py: 0.5,
        ml: 1,
        borderRadius: 1,
        borderLeft: isActive ? 2 : 0,
        borderColor: "primary.main",
        bgcolor: isActive ? "primary.main" : "transparent",
        color: isActive ? "primary.contrastText" : "inherit",
        "&:hover": { bgcolor: isActive ? "primary.dark" : "action.hover" },
        opacity: node.disabled ? 0.6 : 1,
      }}
      disabled={node.disabled}
      component={node.to && !node.disabled ? RouterLink : "div"}
      to={node.to}
    >
      <ListItemIcon sx={{ minWidth: 28, color: isActive ? "inherit" : "text.secondary" }}>
        {node.icon || <ChevronRight fontSize="small" />}
      </ListItemIcon>
      <ListItemText
        primary={
          <Typography variant="body2" fontWeight={isActive ? 600 : 400} noWrap>
            {node.label}
          </Typography>
        }
        secondary={node.disabled ? "Coming soon" : undefined}
        secondaryTypographyProps={{ variant: "caption" }}
      />
    </ListItemButton>
  );
}
