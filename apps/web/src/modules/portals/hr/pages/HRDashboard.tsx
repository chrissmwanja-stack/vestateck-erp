import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography, Button } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";
import { useNavigate } from "react-router-dom";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, PieChart, Pie, Cell, Legend, LineChart, Line } from "recharts";



export default function HRDashboard() {
  const navigate = useNavigate();
  const [stats, setStats] = useState({ employees: 0, active: 0, departments: 0, leavesPending: 0, jobsOpen: 0, attendanceToday: 0 });
  const [byDept, setByDept] = useState<{ name: string; value: number }[]>([]);
  const [attendanceTrend, setAttendanceTrend] = useState<{ date: string; present: number; absent: number; late: number }[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchStats = async () => {
    setLoading(true);
    const [empRes, deptRes, leaveRes, jobsRes, attTodayRes, allEmpsRes, attWeekRes] = await Promise.all([
      supabase.from("hr_employees").select("id, is_active", { count: "exact" }),
      supabase.from("departments").select("id", { count: "exact", head: true }).eq("is_active", true),
      supabase.from("hr_leave_requests").select("id", { count: "exact", head: true }).eq("status", "pending"),
      supabase.from("hr_job_postings").select("id", { count: "exact", head: true }).eq("status", "open"),
      supabase.from("hr_attendance").select("id", { count: "exact", head: true }).eq("attendance_date", new Date().toISOString().slice(0, 10)),
      supabase.from("hr_employees").select("departments(name)"),
      supabase.from("hr_attendance").select("attendance_date, status").gte("attendance_date", new Date(Date.now() - 6*24*60*60*1000).toISOString().slice(0,10)).order("attendance_date"),
    ]);

    setStats({
      employees: empRes.count || empRes.data?.length || 0,
      active: empRes.data?.filter((e: any) => e.is_active).length || 0,
      departments: deptRes.count || 0,
      leavesPending: leaveRes.count || 0,
      jobsOpen: jobsRes.count || 0,
      attendanceToday: attTodayRes.count || 0,
    });

    // byDept aggregation
    const emps = (allEmpsRes.data as any[]) || [];
    const map: Record<string, number> = {};
    emps.forEach((e: any) => {
      const dept = Array.isArray(e.departments) ? e.departments[0] : e.departments;
      const name = dept?.name || "Unassigned";
      map[name] = (map[name] || 0) + 1;
    });
    setByDept(Object.entries(map).map(([name, value]) => ({ name, value })).sort((a,b)=>b.value-a.value).slice(0,8));

    // attendance trend last 7 days
    const week = (attWeekRes.data as any[]) || [];
    const byDate: Record<string, { present:number; absent:number; late:number }> = {};
    for (let i=6; i>=0; i--) {
      const d = new Date(Date.now() - i*24*60*60*1000).toISOString().slice(0,10);
      byDate[d] = { present:0, absent:0, late:0 };
    }
    week.forEach((r: any) => {
      if (!byDate[r.attendance_date]) byDate[r.attendance_date] = { present:0, absent:0, late:0 };
      if (r.status === "present") byDate[r.attendance_date].present++;
      else if (r.status === "absent") byDate[r.attendance_date].absent++;
      else if (r.status === "late") byDate[r.attendance_date].late++;
    });
    setAttendanceTrend(Object.entries(byDate).map(([date, v]) => ({ date: date.slice(5), present: v.present, absent: v.absent, late: v.late })));

    setLoading(false);
  };

  useEffect(() => { fetchStats(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>HR Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Headcount, attendance, leaves, recruitment overview. Click cards to drill into modules.</Typography>

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ cursor: "pointer" }} onClick={() => navigate("/hr/employees")}><CardContent><Typography variant="caption" color="text.secondary">Total Employees</Typography><Typography variant="h4" fontWeight={700}>{stats.employees}</Typography><Typography variant="caption" color="success.main">{stats.active} active</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ cursor: "pointer" }} onClick={() => navigate("/hr/org-chart")}><CardContent><Typography variant="caption" color="text.secondary">Departments</Typography><Typography variant="h4" fontWeight={700}>{stats.departments}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: stats.leavesPending ? "warning.light" : "white", cursor: "pointer" }} onClick={() => navigate("/hr/leaves")}><CardContent><Typography variant="caption">Leaves Pending Approval</Typography><Typography variant="h4" fontWeight={700}>{stats.leavesPending}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ cursor: "pointer" }} onClick={() => navigate("/hr/recruitment/jobs")}><CardContent><Typography variant="caption" color="text.secondary">Open Jobs</Typography><Typography variant="h4" fontWeight={700}>{stats.jobsOpen}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: "info.light", cursor: "pointer" }} onClick={() => navigate("/hr/attendance")}><CardContent><Typography variant="caption">Attendance Today</Typography><Typography variant="h4" fontWeight={700}>{stats.attendanceToday}</Typography><Typography variant="caption">{new Date().toLocaleDateString()}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card variant="outlined"><CardContent><Typography variant="caption" color="text.secondary">Active Rate</Typography><Typography variant="h4" fontWeight={700}>{stats.employees ? ((stats.active/stats.employees)*100).toFixed(0) : 0}%</Typography><Typography variant="caption">{stats.employees - stats.active} inactive / on leave</Typography></CardContent></Card></Grid>
      </Grid>

      <Grid container spacing={2}>
        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Headcount by Department</Typography>
            {byDept.length === 0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No employees yet.</Typography> : (
              <ResponsiveContainer width="100%" height={260}>
                <BarChart data={byDept} layout="vertical" margin={{ left: 90 }}>
                  <XAxis type="number" allowDecimals={false} fontSize={12} />
                  <YAxis type="category" dataKey="name" width={90} fontSize={12} />
                  <ReTooltip />
                  <Bar dataKey="value" fill="#1976d2" radius={[0,8,8,0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
            <Button size="small" sx={{ mt: 1 }} onClick={() => navigate("/hr/reports/headcount")}>View Headcount Report →</Button>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Attendance Trend (Last 7 Days)</Typography>
            {attendanceTrend.every(d => d.present===0 && d.absent===0 && d.late===0) ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No attendance in last 7 days.</Typography> : (
              <ResponsiveContainer width="100%" height={260}>
                <LineChart data={attendanceTrend}>
                  <XAxis dataKey="date" fontSize={12} />
                  <YAxis allowDecimals={false} fontSize={12} />
                  <ReTooltip />
                  <Legend />
                  <Line type="monotone" dataKey="present" stroke="#2e7d32" strokeWidth={2} dot={false} name="Present" />
                  <Line type="monotone" dataKey="late" stroke="#ed6c02" strokeWidth={2} dot={false} name="Late" />
                  <Line type="monotone" dataKey="absent" stroke="#d32f2f" strokeWidth={2} dot={false} name="Absent" />
                </LineChart>
              </ResponsiveContainer>
            )}
            <Button size="small" sx={{ mt: 1 }} onClick={() => navigate("/hr/reports/attendance")}>View Attendance Report →</Button>
          </CardContent></Card>
        </Grid>

        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Employees by Status</Typography>
            <ResponsiveContainer width="100%" height={200}>
              <PieChart>
                <Pie data={[{name:"Active", value:stats.active},{name:"Inactive", value:Math.max(0, stats.employees-stats.active)}].filter(d=>d.value>0)} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={80} label={({name, value})=>`${name} ${value}`}>
                  <Cell fill="#2e7d32" /><Cell fill="#9e9e9e" />
                </Pie>
                <ReTooltip /><Legend />
              </PieChart>
            </ResponsiveContainer>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Quick Links</Typography>
            <Box sx={{ display: "flex", flexWrap: "wrap", gap: 1, mt: 1 }}>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/employees")}>Employees</Button>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/attendance")}>Attendance</Button>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/leaves")}>Leaves</Button>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/performance/appraisals")}>Appraisals</Button>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/training")}>Training</Button>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/recruitment/jobs")}>Recruitment</Button>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/org-chart")}>Org Chart</Button>
              <Button variant="outlined" size="small" onClick={() => navigate("/hr/payroll/compensation-history")}>Compensation</Button>
            </Box>
          </CardContent></Card>
        </Grid>
      </Grid>
    </Box>
  );
}
