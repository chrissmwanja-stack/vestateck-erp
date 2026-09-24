import { useState, MouseEvent, useMemo } from "react";
import { Box, List, ListItemIcon, ListItemText, Typography, Divider, Menu, MenuItem, TextField, InputAdornment, Chip } from "@mui/material";
import { ExpandMore, Search } from "@mui/icons-material";
import { useLocation } from "react-router-dom";
import { useBranding } from "../../lib/brandingContext";
import { useMyModuleAccess } from "./useMyModuleAccess";
import { filterNodesByAccess } from "./filterNodesByAccess";
import { TreeItem } from "./TreeItem";
import { portals } from "./moduleTreeData";
import type { TreeNode, Portal } from "./types";

export default function ModuleTree() {
  const brand = useBranding();
  const location = useLocation();
  const [search, setSearch] = useState("");
  const access = useMyModuleAccess();
  const [activePortalId, setActivePortalId] = useState(() => {
    return localStorage.getItem("activePortalId") || portals[0].id;
  });
  const [anchorEl, setAnchorEl] = useState<null | HTMLElement>(null);

  // Portals gated at the whole-portal level (hr/legal/bd/it/pmo/
  // machine_operation/sustainability) disappear entirely from the
  // switcher if the user has no access. Mixed portals (purchasing-
  // logistics) and ungated ones (financial-management, platform-admin)
  // always show, with node-level filtering applied below.
  const visiblePortals = useMemo(() => {
    if (!access) return portals;
    if (access.isPlatformAdmin && !access.isImpersonating) {
      return portals.filter((p) => p.id === "platform-admin");
    }
    return portals.filter((p) => {
      if (access.isPlatformAdmin) return true;
      if (p.requiredModule && !access.modules.has(p.requiredModule)) return false;
      if (p.requiredAccess === "finance" && !access.canAccessFinance) return false;
      return true;
    });
  }, [access]);

  const activePortal = useMemo(
    () => visiblePortals.find((p) => p.id === activePortalId) ?? visiblePortals[0] ?? portals[0],
    [activePortalId, visiblePortals],
  );

  const handleOpenSwitcher = (e: MouseEvent<HTMLElement>) => setAnchorEl(e.currentTarget);
  const handleCloseSwitcher = () => setAnchorEl(null);
  const handleSelectPortal = (portal: Portal) => {
    if (portal.disabled) return;
    setActivePortalId(portal.id);
    localStorage.setItem("activePortalId", portal.id);
    handleCloseSwitcher();
  };

  const accessFilteredNodes = useMemo(() => {
    if (!access) return activePortal.nodes;
    return filterNodesByAccess(activePortal.nodes, access, activePortal.requiredModule);
  }, [activePortal.nodes, activePortal.requiredModule, access]);

  const filteredNodes = useMemo(() => {
    if (!search) return accessFilteredNodes;
    const lower = search.toLowerCase();
    const filter = (nodes: TreeNode[]): TreeNode[] => {
      return nodes
        .map((n) => {
          if (n.children) {
            const filteredChildren = filter(n.children);
            if (filteredChildren.length > 0 || n.label.toLowerCase().includes(lower)) {
              return { ...n, children: filteredChildren.length ? filteredChildren : n.children };
            }
            return null;
          }
          return n.label.toLowerCase().includes(lower) ? n : null;
        })
        .filter(Boolean) as TreeNode[];
    };
    return filter(accessFilteredNodes);
  }, [accessFilteredNodes, search]);

  return (
    <Box
      sx={{
        width: 300,
        minWidth: 300,
        bgcolor: "background.paper",
        borderRight: 1,
        borderColor: "divider",
        height: "100vh",
        overflow: "auto",
        display: "flex",
        flexDirection: "column",
      }}
    >
      <Box
        onClick={handleOpenSwitcher}
        sx={{
          p: 2,
          borderBottom: 1,
          borderColor: "divider",
          bgcolor: "primary.main",
          cursor: "pointer",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          position: "sticky",
          top: 0,
          zIndex: 1,
        }}
      >
        <Box sx={{ overflow: "hidden" }}>
          <Typography
            variant="subtitle2"
            sx={{ color: "primary.contrastText", fontWeight: 700, display: "flex", alignItems: "center", gap: 1, whiteSpace: "nowrap" }}
          >
            {activePortal.icon}
            {activePortal.label}
            {activePortal.isPreview && (
              <Chip
                label="Preview"
                size="small"
                sx={{
                  height: 18,
                  fontSize: "0.65rem",
                  bgcolor: "rgba(255,255,255,0.2)",
                  color: "primary.contrastText",
                }}
              />
            )}
          </Typography>
          <Typography variant="caption" sx={{ color: "primary.contrastText", opacity: 0.8 }}>
            {brand.platformName} — click to switch portal
          </Typography>
        </Box>
        <ExpandMore sx={{ color: "primary.contrastText", flexShrink: 0 }} />
      </Box>

      <Menu anchorEl={anchorEl} open={Boolean(anchorEl)} onClose={handleCloseSwitcher} PaperProps={{ sx: { width: 320 } }}>
        {visiblePortals.map((portal) => (
          <MenuItem
            key={portal.id}
            selected={portal.id === activePortalId}
            disabled={portal.disabled}
            onClick={() => handleSelectPortal(portal)}
          >
            <ListItemIcon sx={{ minWidth: 32 }}>{portal.icon}</ListItemIcon>
            <ListItemText
              primary={
                <Box sx={{ display: "flex", alignItems: "center", gap: 0.75 }}>
                  {portal.label}
                  {portal.isPreview && <Chip label="Preview" size="small" sx={{ height: 18, fontSize: "0.65rem" }} />}
                </Box>
              }
              secondary={portal.disabled ? "Coming soon" : undefined}
            />
          </MenuItem>
        ))}
      </Menu>

      <Box sx={{ p: 1, borderBottom: 1, borderColor: "divider" }}>
        <TextField
          size="small"
          fullWidth
          placeholder={`Search ${activePortal.label}...`}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          InputProps={{
            startAdornment: (
              <InputAdornment position="start">
                <Search fontSize="small" />
              </InputAdornment>
            ),
          }}
        />
      </Box>

      <Box sx={{ p: 1, flex: 1 }}>
        <List dense disablePadding>
          {filteredNodes.length > 0 ? (
            filteredNodes.map((node) => <TreeItem key={node.id} node={node} pathname={location.pathname} />)
          ) : (
            <Box sx={{ p: 2, textAlign: "center" }}>
              <Typography variant="body2" color="text.secondary">
                No results for "{search}"
              </Typography>
            </Box>
          )}
        </List>
      </Box>

      <Divider />
      <Box sx={{ p: 1.5 }}>
        <Typography variant="caption" color="text.secondary" sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
          <Box component="span" sx={{ width: 6, height: 6, borderRadius: "50%", bgcolor: "success.main", display: "inline-block" }} />
          Multi-tenant • {activePortal.nodes.length} modules • RLS-enabled
        </Typography>
      </Box>
    </Box>
  );
}

// Re-exports for backward compatibility — existing tests/imports that
// pulled portals/itSupportNodes or helpers directly from ModuleTree.tsx
// continue to work, but new code should import from the specific files.
export { portals, itSupportNodes } from "./moduleTreeData";
export type { Portal, TreeNode } from "./types";
export { filterNodesByAccess } from "./filterNodesByAccess";
