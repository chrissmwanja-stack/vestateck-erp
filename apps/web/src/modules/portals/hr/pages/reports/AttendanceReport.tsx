import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, TextField } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Attendance { id: string; status: string; attendance_date: string; hr_employees?: { first_name: string; last_name: string; hr_departments?: { name: string } | null } | null; }

export default function AttendanceReport() {
  const [attendance, setAttendance] = useState<Attendance[]>([]);
  const [loading, setLoading] = useState(true);
  const [dateFilter, setDateFilter] = useState<string>(new Date().toISOString().slice(0, 7)); // YYYY-MM

  const fetchReport = async () => {
    setLoading(true);
    const start = `${dateFilter}-01`;
    const end = `${dateFilter}-31`;
    const { data } = await supabase
      .from("hr_attendance")
      .select("*, hr_employees(first_name, last_name, hr_departments(name))")
      .gte("attendance_date", start)
      .lte("attendance_date", end)
      .order("attendance_date", { ascending: false });

    if (data) setAttendance(data as Attendance[]);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, [dateFilter]);

  const stats = {
    total: attendance.length,
    present: attendance.filter(a => a.status === 'present').length,
    absent: attendance.filter(a => a.status === 'absent').length,
    late: attendance.filter(a => a.status === 'late').length,
    onLeave: attendance.filter(a => a.status === 'on_leave').length,
  };

  const getStatusColor = (s: string) => {
    if (s === 'present') return 'success';
    if (s === 'absent') return 'error';
    if (s === 'late') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Attendance Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Attendance % by status for selected month. Filter by YYYY-MM.</Typography>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap", alignItems: "center" }}>
        <TextField label="Month" type="month" value={dateFilter} onChange={e => setDateFilter(e.target.value)} size="small" InputLabelProps={{ shrink: true }} />
        <Chip label={`Total: ${stats.total}`} size="small" />
        <Chip label={`Present: ${stats.present}`} size="small" color="success" />
        <Chip label={`Absent: ${stats.absent}`} size="small" color="error" />
        <Chip label={`Late: ${stats.late}`} size="small" color="warning" />
        <Chip label={`On Leave: ${stats.onLeave}`} size="small" />
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead><TableRow><TableCell>Date</TableCell><TableCell>Employee</TableCell><TableCell>Department</TableCell><TableCell>Status</TableCell></TableRow></TableHead>
            <TableBody>
              {attendance.length === 0 ? (
                <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No attendance records for {dateFilter}. Create attendance in Attendance page.</Typography></TableCell></TableRow>
              ) : (
                attendance.map(a => (
                  <TableRow key={a.id} hover>
                    <TableCell>{new Date(a.attendance_date).toLocaleDateString()}</TableCell>
                    <TableCell><Typography fontWeight={600}>{a.hr_employees ? `${a.hr_employees.first_name} ${a.hr_employees.last_name}` : "-"}</Typography></TableCell>
                    <TableCell>{a.hr_employees?.hr_departments?.name || "-"}</TableCell>
                    <TableCell><Chip label={a.status} size="small" color={getStatusColor(a.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
}
