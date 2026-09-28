/**
 * A payroll period (YYYY-MM) that will not collide with a previous run.
 *
 * hr_payroll_runs is UNIQUE (tenant_id, period), and the create dialog stays
 * open with a "A run for ... already exists" error on a duplicate. Deriving
 * the period from today's date meant every rerun against the same database
 * (without a `supabase db reset`) failed at that step. A random far-future
 * year/month keeps reruns independent (~95k combinations) and sorts to the
 * top of the period-descending run list, so the new run is always visible.
 * The period is only ever used as a marker string; nothing parses it as a date.
 */
export function uniquePayrollPeriod(): string {
  const year = 2100 + Math.floor(Math.random() * 7900);
  const month = 1 + Math.floor(Math.random() * 12);
  return `${year}-${String(month).padStart(2, '0')}`;
}
