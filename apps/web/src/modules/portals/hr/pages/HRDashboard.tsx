import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";

export default function HRDashboard() {
  const [stats, setStats] = useState({ employees: 0, active: 0, departments: 0, leavesPending: 0, jobsOpen: 0, attendanceToday: 0 });
  const [loading, setLoading] = useState(true);

  const fetchStats = async () => {
    setLoading(true);
    const [empRes, deptRes, leaveRes, jobsRes, attRes] = await Promise.all([
      supabase.from("hr_employees").select("id, is_active", { count: "exact" }),
      supabase.from("departments").select("id", { count: "exact", head: true }).eq("is_active", true),
      supabase.from("hr_leave_requests").select("id", { count: "exact", head: true }).eq("status", "pending"),
      supabase.from("hr_job_postings").select("id", { count: "exact", head: true }).eq("status", "open"),
      supabase.from("hr_attendance").select("id", { count: "exact", head: true }).eq("attendance_date", new Date().toISOString().slice(0, 10)),
    ]);
    
    setStats({
      employees: empRes.count || empRes.data?.length || 0,
      active: empRes.data?.filter((e: any) => e.is_active).length || 0,
      departments: deptRes.count || 0,
      leavesPending: leaveRes.count || 0,
      jobsOpen: jobsRes.count || 0,
      attendanceToday: attRes.count || 0,
    });
    setLoading(false);
  };

  useEffect(() => { fetchStats(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>HR Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Headcount, attendance, leaves, recruitment overview.</Typography>
      
      <Grid container spacing={2}>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption" color="text.secondary">Total Employees</Typography><Typography variant="h4" fontWeight={700}>{stats.employees}</Typography><Typography variant="caption" color="success.main">{stats.active} active</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption" color="text.secondary">Departments</Typography><Typography variant="h4" fontWeight={700}>{stats.departments}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: "warning.light" }}><CardContent><Typography variant="caption">Leaves Pending Approval</Typography><Typography variant="h4" fontWeight={700}>{stats.leavesPending}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption" color="text.secondary">Open Jobs</Typography><Typography variant="h4" fontWeight={700}>{stats.jobsOpen}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: "info.light" }}><CardContent><Typography variant="caption">Attendance Today</Typography><Typography variant="h4" fontWeight={700}>{stats.attendanceToday}</Typography></CardContent></Card></Grid>
      </Grid>

      <Box sx={{ mt: 3, p: 2, bgcolor: "grey.50", borderRadius: 1 }}>
        <Typography variant="caption">Next: Build charts for headcount by department, attendance trend, leave balance.</Typography>
      </Box>
    </Box>
  );
}