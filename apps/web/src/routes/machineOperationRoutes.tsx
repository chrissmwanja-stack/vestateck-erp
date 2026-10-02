// Machine Operation.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{machineOperationRoutes}`.

import { lazy } from 'react';
import { Route } from 'react-router-dom';
import RequireModule from '../components/RequireModule';

const DailyLogs = lazy(() => import('../modules/portals/machine-operation/pages/logs/DailyLogs'));
const DowntimeReport = lazy(() => import('../modules/portals/machine-operation/pages/reports/DowntimeReport'));
const EquipmentAssignments = lazy(() => import('../modules/portals/machine-operation/pages/equipment/EquipmentAssignments'));
const EquipmentList = lazy(() => import('../modules/portals/machine-operation/pages/equipment/EquipmentList'));
const FuelLogs = lazy(() => import('../modules/portals/machine-operation/pages/logs/FuelLogs'));
const MachineDashboard = lazy(() => import('../modules/portals/machine-operation/pages/MachineDashboard'));
const MachineTypesAdmin = lazy(() => import('../modules/portals/machine-operation/pages/admin/MachineTypesAdmin'));
const MaintenanceHistory = lazy(() => import('../modules/portals/machine-operation/pages/maintenance/MaintenanceHistory'));
const MaintenanceRequests = lazy(() => import('../modules/portals/machine-operation/pages/maintenance/MaintenanceRequests'));
const MaintenanceSchedule = lazy(() => import('../modules/portals/machine-operation/pages/maintenance/MaintenanceSchedule'));
const MaintenanceTypesAdmin = lazy(() => import('../modules/portals/machine-operation/pages/admin/MaintenanceTypesAdmin'));
const UtilizationReport = lazy(() => import('../modules/portals/machine-operation/pages/reports/UtilizationReport'));

export const machineOperationRoutes = (
  <>
    {/* MACHINE OPERATION - 100% REAL NOW */}
    <Route element={<RequireModule module="machine_operation" />}>
      <Route path="/machine-operation/dashboard" element={<MachineDashboard />} />
      <Route path="/machine-operation/equipment" element={<EquipmentList />} />
      <Route path="/machine-operation/equipment/assignments" element={<EquipmentAssignments />} />
      <Route path="/machine-operation/maintenance/schedule" element={<MaintenanceSchedule />} />
      <Route path="/machine-operation/maintenance/requests" element={<MaintenanceRequests />} />
      <Route path="/machine-operation/maintenance/history" element={<MaintenanceHistory />} />
      <Route path="/machine-operation/logs/daily" element={<DailyLogs />} />
      <Route path="/machine-operation/logs/fuel" element={<FuelLogs />} />
      <Route path="/machine-operation/reports/utilization" element={<UtilizationReport />} />
      <Route path="/machine-operation/reports/downtime" element={<DowntimeReport />} />
      <Route path="/machine-operation/admin/types" element={<MachineTypesAdmin />} />
      <Route path="/machine-operation/admin/maintenance-types" element={<MaintenanceTypesAdmin />} />
    </Route>
  </>
);
