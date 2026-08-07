import { useCallback, useEffect, useState } from "react";
import {
  Badge,
  Box,
  IconButton,
  List,
  ListItemButton,
  ListItemText,
  Menu,
  Typography,
  Button,
} from "@mui/material";
import NotificationsIcon from "@mui/icons-material/Notifications";
import { supabase } from "../../lib/supabaseClient";

interface Notification {
  id: string;
  type: string;
  title: string;
  body: string;
  request_id: string | null;
  purchase_order_id: string | null;
  recipient_id: string;
  read_at: string | null;
  created_at: string;
}

export default function NotificationBell({ userId }: { userId: string }) {
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const [anchorEl, setAnchorEl] = useState<HTMLElement | null>(null);

  const unreadCount = notifications.filter((n) => !n.read_at).length;

  const loadNotifications = useCallback(async () => {
    // IMPROVEMENT: explicit filter for defense in depth (RLS should also enforce)
    const { data, error } = await supabase
      .from("notifications")
      .select("id, type, title, body, request_id, purchase_order_id, recipient_id, read_at, created_at")
      .eq("recipient_id", userId)
      .order("created_at", { ascending: false })
      .limit(20);

    if (!error) setNotifications((data ?? []) as Notification[]);
  }, [userId]);

  useEffect(() => {
    loadNotifications();
  }, [loadNotifications]);

  // Live delivery — new notifications land in the dropdown without a
  // refresh. Filtered server-side to this user's own rows, on top of RLS
  // already scoping SELECT the same way.
  useEffect(() => {
    const channel = supabase
      .channel(`notifications:${userId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "notifications",
          filter: `recipient_id=eq.${userId}`,
        },
        (payload) => {
          setNotifications((prev) => [
            payload.new as Notification,
            ...prev,
          ]);
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [userId]);

  const openMenu = (e: React.MouseEvent<HTMLElement>) => setAnchorEl(e.currentTarget);
  const closeMenu = () => setAnchorEl(null);

  const markAsRead = async (notification: Notification) => {
    if (notification.read_at) return;
    setNotifications((prev) =>
      prev.map((n) =>
        n.id === notification.id ? { ...n, read_at: new Date().toISOString() } : n
      )
    );
    await supabase
      .from("notifications")
      .update({ read_at: new Date().toISOString() })
      .eq("id", notification.id)
      .eq("recipient_id", userId);
  };

  // IMPROVEMENT: mark all read
  const markAllAsRead = async () => {
    await supabase
      .from("notifications")
      .update({ read_at: new Date().toISOString() })
      .eq("recipient_id", userId)
      .is("read_at", null);
    setNotifications((prev) => prev.map((n) => (n.read_at ? n : { ...n, read_at: new Date().toISOString() })));
  };

  return (
    <>
      <IconButton color="inherit" onClick={openMenu} aria-label="notifications">
        <Badge badgeContent={unreadCount} color="error">
          <NotificationsIcon />
        </Badge>
      </IconButton>
      <Menu
        anchorEl={anchorEl}
        open={!!anchorEl}
        onClose={closeMenu}
        anchorOrigin={{ vertical: "bottom", horizontal: "right" }}
        transformOrigin={{ vertical: "top", horizontal: "right" }}
        PaperProps={{ sx: { width: 380, maxHeight: 480 } }}
      >
        <Box sx={{ p: 1, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <Typography variant="subtitle2">Notifications</Typography>
          {unreadCount > 0 && (
            <Button size="small" onClick={markAllAsRead}>
              Mark all read
            </Button>
          )}
        </Box>
        {notifications.length === 0 ? (
          <Box sx={{ p: 3, textAlign: "center" }}>
            <Typography color="text.secondary" variant="body2">
              No notifications yet.
            </Typography>
          </Box>
        ) : (
          <List dense disablePadding>
            {notifications.map((n) => (
              <ListItemButton
                key={n.id}
                onClick={() => markAsRead(n)}
                sx={{
                  alignItems: "flex-start",
                  bgcolor: n.read_at ? "transparent" : "action.hover",
                }}
              >
                <ListItemText
                  primary={n.title}
                  secondary={
                    <>
                      <Typography component="span" variant="body2" color="text.secondary">
                        {n.body}
                      </Typography>
                      <br />
                      <Typography component="span" variant="caption" color="text.disabled">
                        {new Date(n.created_at).toLocaleString()}
                      </Typography>
                      {n.type === "po_ready" && (
                        <Typography component="span" variant="caption" color="primary" sx={{ ml: 1 }}>
                          · PO ready
                        </Typography>
                      )}
                    </>
                  }
                />
              </ListItemButton>
            ))}
          </List>
        )}
      </Menu>
    </>
  );
}